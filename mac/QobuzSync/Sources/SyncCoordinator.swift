import AppKit
import Foundation
import ServiceManagement

enum SyncError: LocalizedError {
    case noDevice
    case sourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "Connect and unlock the iPod, then try again."
        case .sourceMissing(let path): return "The Qobuz folder does not exist at \(path)."
        }
    }
}

private struct SyncOutcome {
    var deviceID: String
    var transferredFiles: Int
    var events: [PlaybackEvent]
}

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var sourceFolderPath: String
    @Published var autoSyncEnabled: Bool
    @Published var deviceDescription = "Looking for an iPod…"
    @Published var statusMessage = "Ready"
    @Published var isSyncing = false
    @Published var playbackHistory: [ImportedPlaybackEvent] = []
    @Published var apiKey: String
    @Published var sharedSecret: String
    @Published var authorizedUsername: String?
    @Published var lastFMStatusMessage = "Enter your Last.fm API credentials to connect."
    @Published var isLastFMWorking = false
    @Published var isWaitingForLastFMApproval = false
    @Published var launchAtLoginEnabled = false

    private let defaults = UserDefaults.standard
    private let lastFM = LastFMClient()
    private var pollTimer: Timer?
    private var previousDeviceIDs = Set<String>()
    private var pollInProgress = false

    private let apiKeyDefaultsKey = "lastFMAPIKey"
    private let usernameDefaultsKey = "lastFMUsername"
    private let pendingTokenDefaultsKey = "lastFMPendingToken"
    private let sourceFolderDefaultsKey = "sourceFolderPath"
    private let autoSyncDefaultsKey = "autoSyncEnabled"
    private let sharedSecretAccount = "lastfm-shared-secret"
    private let sessionKeyAccount = "lastfm-session-key"

    init() {
        let defaultSource = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Qobuz", isDirectory: true).path
        sourceFolderPath = defaults.string(forKey: sourceFolderDefaultsKey) ?? defaultSource
        autoSyncEnabled = defaults.object(forKey: autoSyncDefaultsKey) as? Bool ?? true
        apiKey = defaults.string(forKey: apiKeyDefaultsKey) ?? ""
        sharedSecret = KeychainStore.string(for: sharedSecretAccount) ?? ""
        authorizedUsername = defaults.string(forKey: usernameDefaultsKey)
        if authorizedUsername != nil, KeychainStore.string(for: sessionKeyAccount) != nil {
            lastFMStatusMessage = "Last.fm is connected."
        } else if defaults.string(forKey: pendingTokenDefaultsKey) != nil {
            lastFMStatusMessage = "Browser approval is pending."
        } else {
            lastFMStatusMessage = "Enter your Last.fm API credentials to connect."
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        playbackHistory = Self.loadHistory()
    }

    var hasLastFMSession: Bool {
        KeychainStore.string(for: sessionKeyAccount) != nil
    }

    var pendingScrobbleCount: Int {
        playbackHistory.filter { $0.state == .pending || $0.state == .failed }.count
    }

    func start() {
        guard pollTimer == nil else { return }
        resumePendingLastFMAuthorization()
        pollForDevice()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForDevice() }
        }
    }

    func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: sourceFolderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceFolderPath = url.path
        defaults.set(sourceFolderPath, forKey: sourceFolderDefaultsKey)
    }

    func setAutoSync(_ enabled: Bool) {
        autoSyncEnabled = enabled
        defaults.set(enabled, forKey: autoSyncDefaultsKey)
    }

    func saveSourceFolderPath() {
        sourceFolderPath = (sourceFolderPath as NSString).expandingTildeInPath
        defaults.set(sourceFolderPath, forKey: sourceFolderDefaultsKey)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            statusMessage = "Launch at login: \(error.localizedDescription)"
        }
    }

    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        statusMessage = "Checking the iPod and Qobuz folder…"
        let sourceURL = URL(fileURLWithPath: sourceFolderPath, isDirectory: true)

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try SyncWorker.run(sourceURL: sourceURL)
                }.value
                deviceDescription = "iPod connected · \(outcome.deviceID.prefix(8))…"
                merge(outcome.events)
                statusMessage = outcome.transferredFiles == 1
                    ? "Copied 1 changed file and imported play history."
                    : "Copied \(outcome.transferredFiles) changed files and imported play history."
                isSyncing = false
                if hasLastFMSession {
                    await scrobblePending()
                }
            } catch {
                isSyncing = false
                statusMessage = error.localizedDescription
            }
        }
    }

    func beginLastFMAuthorization() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedSecret.isEmpty else {
            statusMessage = LastFMError.missingCredentials.localizedDescription
            lastFMStatusMessage = LastFMError.missingCredentials.localizedDescription
            return
        }
        isLastFMWorking = true
        defaults.set(trimmedKey, forKey: apiKeyDefaultsKey)
        do {
            try KeychainStore.set(trimmedSecret, for: sharedSecretAccount)
        } catch {
            isLastFMWorking = false
            statusMessage = "Could not save the shared secret: \(error.localizedDescription)"
            lastFMStatusMessage = statusMessage
            return
        }

        Task {
            do {
                let token = try await lastFM.requestToken(apiKey: trimmedKey, sharedSecret: trimmedSecret)
                defaults.set(token, forKey: pendingTokenDefaultsKey)
                if let url = lastFM.authorizationURL(apiKey: trimmedKey, token: token) {
                    _ = NSWorkspace.shared.open(url)
                }
                apiKey = trimmedKey
                sharedSecret = trimmedSecret
                statusMessage = "Approve iPod Qobuz Sync on Last.fm, then return here and click Finish."
                lastFMStatusMessage = statusMessage
                isWaitingForLastFMApproval = true
                isLastFMWorking = false
            } catch {
                statusMessage = error.localizedDescription
                lastFMStatusMessage = statusMessage
                isLastFMWorking = false
            }
        }
    }

    func completeLastFMAuthorization() {
        guard let token = defaults.string(forKey: pendingTokenDefaultsKey) else {
            statusMessage = "Start Last.fm authorization first."
            lastFMStatusMessage = statusMessage
            return
        }
        isLastFMWorking = true
        Task {
            do {
                let session = try await lastFM.requestSession(
                    token: token,
                    apiKey: apiKey,
                    sharedSecret: sharedSecret
                )
                try finishLastFMAuthorization(session)
                isLastFMWorking = false
                await scrobblePending()
            } catch let error as LastFMError where error.requiresManualApproval {
                isLastFMWorking = false
                isWaitingForLastFMApproval = true
                statusMessage = "Last.fm has not accepted this token yet. Approve the existing page, then click Finish once."
                lastFMStatusMessage = statusMessage
            } catch {
                statusMessage = error.localizedDescription
                lastFMStatusMessage = statusMessage
                isLastFMWorking = false
            }
        }
    }

    func openPendingLastFMApprovalPage() {
        guard let token = defaults.string(forKey: pendingTokenDefaultsKey),
              let url = lastFM.authorizationURL(apiKey: apiKey, token: token) else {
            beginLastFMAuthorization()
            return
        }
        _ = NSWorkspace.shared.open(url)
        statusMessage = "Approve iPod Qobuz Sync on the Last.fm page that just opened."
        lastFMStatusMessage = statusMessage
    }

    func startOverLastFMAuthorization() {
        defaults.removeObject(forKey: pendingTokenDefaultsKey)
        isWaitingForLastFMApproval = false
        beginLastFMAuthorization()
    }

    func disconnectLastFM() {
        KeychainStore.remove(sessionKeyAccount)
        defaults.removeObject(forKey: usernameDefaultsKey)
        defaults.removeObject(forKey: pendingTokenDefaultsKey)
        authorizedUsername = nil
        isWaitingForLastFMApproval = false
        statusMessage = "Last.fm disconnected. Your local play history was kept."
        lastFMStatusMessage = statusMessage
    }

    func scrobbleNow() {
        Task { await scrobblePending() }
    }

    private func resumePendingLastFMAuthorization() {
        guard !hasLastFMSession,
              defaults.string(forKey: pendingTokenDefaultsKey) != nil,
              !apiKey.isEmpty,
              !sharedSecret.isEmpty else { return }
        isWaitingForLastFMApproval = true
        statusMessage = "Browser approval is pending. Approve the existing page, then click Finish."
        lastFMStatusMessage = statusMessage
    }

    private func finishLastFMAuthorization(_ session: LastFMSession) throws {
        try KeychainStore.set(session.key, for: sessionKeyAccount)
        defaults.set(session.name, forKey: usernameDefaultsKey)
        defaults.removeObject(forKey: pendingTokenDefaultsKey)
        authorizedUsername = session.name
        isWaitingForLastFMApproval = false
        statusMessage = "Last.fm connected as \(session.name)."
        lastFMStatusMessage = statusMessage
    }

    private func pollForDevice() {
        guard !pollInProgress else { return }
        pollInProgress = true
        Task {
            let ids = (try? await Task.detached {
                try USBDeviceService().connectedDeviceIDs()
            }.value) ?? []
            pollInProgress = false
            let current = Set(ids)
            deviceDescription = current.isEmpty
                ? "No iPod connected"
                : "iPod connected · \(ids[0].prefix(8))…"
            let newlyConnected = !current.subtracting(previousDeviceIDs).isEmpty
            previousDeviceIDs = current
            if newlyConnected && autoSyncEnabled {
                syncNow()
            }
        }
    }

    private func merge(_ events: [PlaybackEvent]) {
        var existing = Dictionary(uniqueKeysWithValues: playbackHistory.map { ($0.id, $0) })
        let now = Date()
        for event in events where existing[event.id] == nil {
            existing[event.id] = ImportedPlaybackEvent(
                event: event,
                state: event.isLastFMEligible ? .pending : .ineligible,
                stateMessage: event.isLastFMEligible
                    ? nil
                    : "Played less than half the track (or under 30 seconds).",
                importedAt: now,
                scrobbledAt: nil
            )
        }
        playbackHistory = existing.values.sorted { $0.event.startedAt > $1.event.startedAt }
        persistHistory()
    }

    private func scrobblePending() async {
        guard !isLastFMWorking else { return }
        guard let sessionKey = KeychainStore.string(for: sessionKeyAccount) else {
            statusMessage = "Connect Last.fm before uploading plays."
            return
        }
        let candidates = playbackHistory
            .filter { ($0.state == .pending || $0.state == .failed) && $0.event.isLastFMEligible }
            .map(\.event)
        guard !candidates.isEmpty else {
            if !playbackHistory.isEmpty {
                statusMessage = "Play history is up to date with Last.fm."
            }
            return
        }

        isLastFMWorking = true
        statusMessage = "Uploading \(candidates.count) play\(candidates.count == 1 ? "" : "s") to Last.fm…"
        do {
            let results = try await lastFM.scrobble(
                events: candidates,
                apiKey: apiKey,
                sharedSecret: sharedSecret,
                sessionKey: sessionKey
            )
            let now = Date()
            for index in playbackHistory.indices {
                guard let result = results[playbackHistory[index].id] else { continue }
                switch result {
                case .accepted:
                    playbackHistory[index].state = .scrobbled
                    playbackHistory[index].stateMessage = nil
                    playbackHistory[index].scrobbledAt = now
                case .ignored(let message):
                    playbackHistory[index].state = .failed
                    playbackHistory[index].stateMessage = message
                }
            }
            persistHistory()
            let accepted = results.values.filter {
                if case .accepted = $0 { return true }
                return false
            }.count
            statusMessage = "Uploaded \(accepted) play\(accepted == 1 ? "" : "s") to Last.fm."
        } catch {
            for index in playbackHistory.indices where candidates.contains(where: { $0.id == playbackHistory[index].id }) {
                playbackHistory[index].state = .failed
                playbackHistory[index].stateMessage = error.localizedDescription
            }
            persistHistory()
            statusMessage = error.localizedDescription
        }
        isLastFMWorking = false
    }

    private func persistHistory() {
        guard let data = try? Self.encoder.encode(playbackHistory) else { return }
        try? FileManager.default.createDirectory(
            at: Self.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.historyURL, options: .atomic)
    }

    private static func loadHistory() -> [ImportedPlaybackEvent] {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? decoder.decode([ImportedPlaybackEvent].self, from: data) else {
            return []
        }
        return history.sorted { $0.event.startedAt > $1.event.startedAt }
    }

    private static let applicationSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("iPod Qobuz Sync", isDirectory: true)
    private static let historyURL = applicationSupportDirectory.appendingPathComponent("playback-history.json")
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum SyncWorker {
    // afcclient's --documents service exposes the app-container root, whose
    // Finder-visible document directory is the "Documents" child.
    private static let manifestPath = "/Documents/.qobuz-sync-manifest.json"
    private static let historyPath = "/Documents/PlaybackHistory/events.jsonl"
    private static let remoteMusicRoot = "/Documents"
    private static let supportedExtensions: Set<String> = [
        "flac", "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "jpg", "jpeg", "png"
    ]

    static func run(sourceURL: URL) throws -> SyncOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SyncError.sourceMissing(sourceURL.path)
        }

        let usb = USBDeviceService()
        guard let deviceID = try usb.connectedDeviceIDs().first else {
            throw SyncError.noDevice
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QobuzSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let manifestURL = temporaryDirectory.appendingPathComponent("manifest.json")
        let priorManifest: SyncManifest?
        if try usb.download(deviceID: deviceID, remotePath: manifestPath, to: manifestURL),
           let data = try? Data(contentsOf: manifestURL),
           let decoded = try? decoder.decode(SyncManifest.self, from: data) {
            priorManifest = decoded
        } else {
            priorManifest = nil
        }

        let sourceFiles = try scan(sourceURL)
        let changedFiles: [SourceFile]
        if let priorManifest {
            changedFiles = sourceFiles.filter {
                priorManifest.files[$0.relativePath] != $0.fingerprint
            }
        } else {
            // Bootstrap safely when the iPod already contains a manually
            // copied Qobuz library: compare byte sizes before writing the
            // first manifest instead of retransferring the whole collection.
            let remoteSizes = try usb.remoteFileSizes(
                deviceID: deviceID,
                files: sourceFiles,
                remoteRoot: remoteMusicRoot
            )
            changedFiles = sourceFiles.filter {
                remoteSizes[$0.relativePath] != $0.fingerprint.byteSize
            }
        }
        try usb.upload(deviceID: deviceID, files: changedFiles, remoteRoot: remoteMusicRoot)

        var updatedManifest = SyncManifest()
        updatedManifest.files = Dictionary(uniqueKeysWithValues: sourceFiles.map {
            ($0.relativePath, $0.fingerprint)
        })
        updatedManifest.updatedAt = Date()
        try usb.uploadData(
            deviceID: deviceID,
            data: try encoder.encode(updatedManifest),
            remotePath: manifestPath
        )

        let historyURL = temporaryDirectory.appendingPathComponent("events.jsonl")
        let events: [PlaybackEvent]
        if try usb.download(deviceID: deviceID, remotePath: historyPath, to: historyURL),
           let contents = try? String(contentsOf: historyURL, encoding: .utf8) {
            events = contents.split(whereSeparator: \.isNewline).compactMap {
                try? decoder.decode(PlaybackEvent.self, from: Data($0.utf8))
            }
        } else {
            events = []
        }
        return SyncOutcome(
            deviceID: deviceID,
            transferredFiles: changedFiles.count,
            events: events
        )
    }

    private static func scan(_ sourceURL: URL) throws -> [SourceFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [SourceFile] = []
        for case let fileURL as URL in enumerator {
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let prefixCount = sourceURL.standardizedFileURL.path.count
            var relative = String(fileURL.standardizedFileURL.path.dropFirst(prefixCount))
            relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else { continue }
            files.append(SourceFile(
                localURL: fileURL,
                relativePath: relative,
                fingerprint: FileFingerprint(
                    byteSize: Int64(values.fileSize ?? 0),
                    modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                )
            ))
        }
        return files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
