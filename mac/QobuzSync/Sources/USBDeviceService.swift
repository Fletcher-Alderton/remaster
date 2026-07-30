import Foundation

enum USBDeviceError: LocalizedError {
    case commandFailed(String)
    case localFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .localFileMissing(let path): return "The iPod did not return \(path)."
        }
    }
}

final class USBDeviceService {
    static let musicBundleIdentifier = "com.fletcher.MusicPrototype"

    private let ideviceIDPath: String
    private let afcclientPath: String

    init() {
        ideviceIDPath = Self.locateCommand(named: "idevice_id")
        afcclientPath = Self.locateCommand(named: "afcclient")
    }

    func connectedDeviceIDs() throws -> [String] {
        let result = try ProcessRunner.run(executable: ideviceIDPath, arguments: ["-l"], timeout: 10)
        guard result.status == 0 else {
            throw USBDeviceError.commandFailed(Self.errorMessage(for: result))
        }
        return result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func download(
        deviceID: String,
        remotePath: String,
        to localURL: URL,
        required: Bool = false
    ) throws -> Bool {
        try? FileManager.default.removeItem(at: localURL)
        let parent = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let command = "get \(Self.shellQuote(remotePath)) \(Self.shellQuote(localURL.path))\n"
        let result = try runAFC(deviceID: deviceID, commands: command)
        let exists = FileManager.default.fileExists(atPath: localURL.path)
        if !exists && required {
            let message = Self.errorMessage(for: result)
            throw USBDeviceError.commandFailed(
                message.isEmpty ? USBDeviceError.localFileMissing(remotePath).localizedDescription : message
            )
        }
        return exists
    }

    func upload(deviceID: String, files: [SourceFile], remoteRoot: String) throws {
        guard !files.isEmpty else { return }
        var directories = Set<String>()
        for file in files {
            let destination = (remoteRoot as NSString).appendingPathComponent(file.relativePath)
            var parent = (destination as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                directories.insert(parent)
                guard parent != remoteRoot else { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        let mkdirCommands = directories
            .sorted {
                $0.split(separator: "/").count < $1.split(separator: "/").count
            }
            .map { "mkdir \(Self.shellQuote($0))" }
        let putCommands = files.map { file in
            let destination = (remoteRoot as NSString).appendingPathComponent(file.relativePath)
            return "put \(Self.shellQuote(file.localURL.path)) \(Self.shellQuote(destination))"
        }
        let result = try runAFC(
            deviceID: deviceID,
            commands: (mkdirCommands + putCommands).joined(separator: "\n") + "\n",
            timeout: max(120, TimeInterval(files.count * 45))
        )
        guard result.status == 0 else {
            throw USBDeviceError.commandFailed(Self.errorMessage(for: result))
        }
    }

    func remoteFileSizes(
        deviceID: String,
        files: [SourceFile],
        remoteRoot: String
    ) throws -> [String: Int64] {
        guard !files.isEmpty else { return [:] }
        let commands = files.map {
            let destination = (remoteRoot as NSString).appendingPathComponent($0.relativePath)
            return "info \(Self.shellQuote(destination))"
        }.joined(separator: "\n") + "\n"
        let result = try runAFC(
            deviceID: deviceID,
            commands: commands,
            timeout: max(120, TimeInterval(files.count * 2))
        )
        guard result.status == 0 else {
            throw USBDeviceError.commandFailed(Self.errorMessage(for: result))
        }

        return Self.parseRemoteFileSizes(
            result.standardOutput,
            relativePaths: files.map(\.relativePath)
        )
    }

    static func parseRemoteFileSizes(
        _ output: String,
        relativePaths: [String]
    ) -> [String: Int64] {
        let cleaned = Self.strippingANSI(output)
        let segments = Array(cleaned.components(separatedBy: "afc:/ >").dropFirst())
        var sizes: [String: Int64] = [:]
        for (index, relativePath) in relativePaths.enumerated() where index < segments.count {
            let segment = segments[index]
            guard let opening = segment.firstIndex(of: "{"),
                  let closing = segment.firstIndex(of: "}") else { continue }
            let jsonText = String(segment[opening...closing])
            guard let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let number = json["st_size"] as? NSNumber else { continue }
            sizes[relativePath] = number.int64Value
        }
        return sizes
    }

    func uploadData(deviceID: String, data: Data, remotePath: String) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QobuzSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let file = temporaryDirectory.appendingPathComponent("payload")
        try data.write(to: file, options: .atomic)
        let parent = (remotePath as NSString).deletingLastPathComponent
        let commands = [
            "mkdir \(Self.shellQuote(parent))",
            "put \(Self.shellQuote(file.path)) \(Self.shellQuote(remotePath))"
        ].joined(separator: "\n") + "\n"
        let result = try runAFC(deviceID: deviceID, commands: commands)
        guard result.status == 0 else {
            throw USBDeviceError.commandFailed(Self.errorMessage(for: result))
        }
    }

    private func runAFC(
        deviceID: String,
        commands: String,
        timeout: TimeInterval = 120
    ) throws -> ProcessResult {
        let script = commands
            + (commands.hasSuffix("\n") ? "" : "\n")
            + "exit\n"
        return try ProcessRunner.run(
            executable: afcclientPath,
            arguments: ["-u", deviceID, "--documents", Self.musicBundleIdentifier],
            input: Data(script.utf8),
            timeout: timeout
        )
    }

    private static func locateCommand(named name: String) -> String {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            ?? candidates[0]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func errorMessage(for result: ProcessResult) -> String {
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        return "The USB command exited with status \(result.status)."
    }

    private static func strippingANSI(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*m") else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}
