import UIKit
import ImageIO
import CommonCrypto

/// Downloaded artwork bytes kept in Caches, so artwork survives memory warnings and
/// relaunches and isn't fetched again when a screen is revisited. iOS may purge Caches
/// under storage pressure, which is fine: images are simply downloaded again.
final class ArtworkDiskCache {
    static let shared = ArtworkDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
    )

    private let directory: URL
    private let byteLimit: Int
    private let ioQueue = DispatchQueue(label: "Music.ArtworkDiskCache", qos: .utility)
    private var writesSincePrune = 0

    init(directory: URL, byteLimit: Int = 150 * 1_024 * 1_024) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // Mark as recently used so pruning removes artwork that hasn't been seen lately.
        ioQueue.async { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
        return data
    }

    func store(_ data: Data, for url: URL) {
        let file = fileURL(for: url)
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            self.writesSincePrune += 1
            if self.writesSincePrune >= 40 {
                self.writesSincePrune = 0
                self.prune()
            }
        }
    }

    func removeAll() {
        ioQueue.sync { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for pending disk writes (used by tests).
    func flush() {
        ioQueue.sync {}
    }

    private func fileURL(for url: URL) -> URL {
        let bytes = Array(url.absoluteString.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Least-recently-used eviction down to 75% of the limit.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(URL, Date, Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.totalFileAllocatedSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > byteLimit else { return }
        entries.sort { $0.1 < $1.1 }
        for (url, _, size) in entries {
            try? FileManager.default.removeItem(at: url)
            total -= size
            if total <= byteLimit * 3 / 4 { break }
        }
    }
}

final class ArtworkImagePipeline {
    static let shared = ArtworkImagePipeline(diskCache: .shared)

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let diskCache: ArtworkDiskCache?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Music.ArtworkImagePipeline"
        queue.qualityOfService = .userInitiated
        // Two decodes keep scrolling responsive without letting a fast grid
        // allocate dozens of temporary image buffers on the 1 GB iPod.
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let requestLock = NSLock()
    private var pending: [NSString: [(UIImage?) -> Void]] = [:]
    /// Some screens look artwork up by its plain URL; map that to the decoded entry's key.
    private var aliases: [String: NSString] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    /// Tests pass no disk cache so fixtures never persist between cases.
    init(session: URLSession = .shared, diskCache: ArtworkDiskCache? = nil) {
        self.session = session
        self.diskCache = diskCache
        cache.countLimit = 200
        // Keep decoded artwork bounded on the 1 GB iPod touch 6. NSCache may
        // evict earlier under memory pressure.
        cache.totalCostLimit = 32 * 1_024 * 1_024
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func image(forFileURL url: URL, maximumPixelSize: Int = 320, completion: @escaping (UIImage?) -> Void) {
        let pixelSize = max(1, maximumPixelSize)
        let key = "\(url.standardizedFileURL.path)|\(pixelSize)" as NSString
        if let image = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(image) }
            return
        }

        requestLock.lock()
        if pending[key] != nil {
            pending[key]?.append(completion)
            requestLock.unlock()
            return
        }
        pending[key] = [completion]
        requestLock.unlock()

        queue.addOperation { [weak self] in
            guard let self = self else { return }
            let image = self.cache.object(forKey: key) ?? autoreleasepool {
                Self.downsample(url: url, maximumPixelSize: pixelSize)
            }
            if let image = image {
                self.cache.setObject(image, forKey: key, cost: Self.decodedCost(of: image))
            }
            self.requestLock.lock()
            let completions = self.pending.removeValue(forKey: key) ?? []
            self.requestLock.unlock()
            DispatchQueue.main.async {
                completions.forEach { $0(image) }
            }
        }
    }

    func image(forRemoteURL url: URL, maximumPixelSize: Int = 320, completion: @escaping (UIImage?) -> Void) {
        guard url.scheme?.lowercased() == "https" else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let pixelSize = max(1, maximumPixelSize)
        let key = "remote|\(url.absoluteString)|\(pixelSize)" as NSString
        if let image = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(image) }
            return
        }

        requestLock.lock()
        if pending[key] != nil {
            pending[key]?.append(completion)
            requestLock.unlock()
            return
        }
        pending[key] = [completion]
        requestLock.unlock()

        let selectedURL = Self.preferredRemoteURL(for: url, maximumPixelSize: pixelSize)
        fetchRemoteImage(url: selectedURL, pixelSize: pixelSize) { [weak self] image in
            guard let self = self else { return }
            if let image = image {
                self.finishRemoteImage(image, key: key, sourceURL: url)
            } else if selectedURL != url {
                // CDN variants are undocumented; retain the API URL as a fallback.
                self.fetchRemoteImage(url: url, pixelSize: pixelSize) { [weak self] image in
                    self?.finishRemoteImage(image, key: key, sourceURL: url)
                }
            } else {
                self.completeRemoteRequest(key: key, image: nil)
            }
        }
    }

    /// Only rewrite known Qobuz JPEG layouts; signed/query URLs and other hosts
    /// must keep their original semantics. iOS 12 has no native WebP/AVIF decoder.
    static func preferredRemoteURL(for url: URL, maximumPixelSize: Int) -> URL {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "static.qobuz.com",
              url.query == nil, url.fragment == nil,
              ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let pixels = max(1, maximumPixelSize)
        if url.path.hasPrefix("/images/covers/"),
           let suffix = url.path.range(of: #"_(50|100|230|300|600|max|org)\.(jpg|jpeg)$"#, options: .regularExpression) {
            let size = [50, 100, 230, 300, 600].first(where: { $0 >= pixels }).map(String.init) ?? "max"
            components.path = String(url.path[..<suffix.lowerBound]) + "_\(size).jpg"
        } else if url.path.hasPrefix("/images/artists/covers/") {
            let parts = url.path.components(separatedBy: "/")
            guard parts.count == 6, ["small", "medium", "large"].contains(parts[4]) else { return url }
            // Qobuz portrait presets: 380, 1140, and 1900 px on the tested CDN.
            let size = pixels <= 380 ? "small" : (pixels <= 1140 ? "medium" : "large")
            components.path = "/images/artists/covers/\(size)/\(parts[5])"
        } else {
            return url
        }
        return components.url ?? url
    }

    private func fetchRemoteImage(url: URL, pixelSize: Int, completion: @escaping (UIImage?) -> Void) {
        guard let diskCache = diskCache else {
            downloadRemoteImage(url: url, pixelSize: pixelSize, completion: completion)
            return
        }
        queue.addOperation { [weak self] in
            guard let self = self else { return }
            if let data = diskCache.data(for: url),
               let image = autoreleasepool(invoking: { Self.downsample(data: data, maximumPixelSize: pixelSize) }) {
                completion(image)
                return
            }
            self.downloadRemoteImage(url: url, pixelSize: pixelSize, completion: completion)
        }
    }

    private func downloadRemoteImage(url: URL, pixelSize: Int, completion: @escaping (UIImage?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("image/jpeg, image/png;q=0.9", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data = data, data.count <= 12 * 1_024 * 1_024 else {
                completion(nil)
                return
            }
            self.queue.addOperation {
                let image = autoreleasepool { Self.downsample(data: data, maximumPixelSize: pixelSize) }
                if image != nil { self.diskCache?.store(data, for: url) }
                completion(image)
            }
        }.resume()
    }

    private func finishRemoteImage(_ image: UIImage?, key: NSString, sourceURL: URL) {
        if let image = image {
            cache.setObject(image, forKey: key, cost: Self.decodedCost(of: image))
            requestLock.lock()
            aliases[sourceURL.absoluteString] = key
            requestLock.unlock()
        }
        completeRemoteRequest(key: key, image: image)
    }

    private func completeRemoteRequest(key: NSString, image: UIImage?) {
        requestLock.lock()
        let completions = pending.removeValue(forKey: key) ?? []
        requestLock.unlock()
        DispatchQueue.main.async { completions.forEach { $0(image) } }
    }

    func cache(_ image: UIImage, for identifier: String) {
        cache.setObject(image, forKey: identifier as NSString, cost: Self.decodedCost(of: image))
    }

    func cachedImage(for identifier: String) -> UIImage? {
        if let image = cache.object(forKey: identifier as NSString) { return image }
        requestLock.lock()
        let alias = aliases[identifier]
        requestLock.unlock()
        return alias.flatMap { cache.object(forKey: $0) }
    }

    /// Memory only: on-disk artwork stays so it can be re-decoded without a download.
    func removeAll() {
        cache.removeAllObjects()
        requestLock.lock()
        aliases.removeAll()
        requestLock.unlock()
    }

    private static func downsample(data: Data, maximumPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func downsample(url: URL, maximumPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func decodedCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
