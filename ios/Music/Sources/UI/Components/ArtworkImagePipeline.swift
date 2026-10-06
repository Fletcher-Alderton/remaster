import UIKit
import ImageIO

final class ArtworkImagePipeline {
    static let shared = ArtworkImagePipeline()

    private let cache = NSCache<NSString, UIImage>()
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
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        cache.countLimit = 100
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

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data = data, data.count <= 12 * 1_024 * 1_024 else {
                self.completeRemoteRequest(key: key, image: nil)
                return
            }
            self.queue.addOperation { [weak self] in
                guard let self = self else { return }
                let image = autoreleasepool { Self.downsample(data: data, maximumPixelSize: pixelSize) }
                if let image = image {
                    self.cache.setObject(image, forKey: key, cost: Self.decodedCost(of: image))
                }
                self.completeRemoteRequest(key: key, image: image)
            }
        }.resume()
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
        return cache.object(forKey: identifier as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
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
