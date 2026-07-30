import Foundation

struct ProcessResult {
    var status: Int32
    var standardOutput: String
    var standardError: String
}

enum ProcessRunnerError: LocalizedError {
    case executableMissing(String)
    case timedOut(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "Required command was not found at \(path). Install libimobiledevice with Homebrew."
        case .timedOut(let command):
            return "\(command) timed out."
        case .failed(let message):
            return message
        }
    }
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval = 120
    ) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.executableMissing(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            stdout.append(chunk)
            lock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            stderr.append(chunk)
            lock.unlock()
        }

        try process.run()
        if let input {
            stdinPipe.fileHandleForWriting.write(input)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw ProcessRunnerError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        stdout.append(stdoutTail)
        stderr.append(stderrTail)
        lock.unlock()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: stdout, as: UTF8.self),
            standardError: String(decoding: stderr, as: UTF8.self)
        )
    }
}
