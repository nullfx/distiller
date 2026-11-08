import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
}

/// Collects output from a background reader thread.
final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ProcessRunner {
    /// Runs a short-lived command to completion.
    ///
    /// With `logFile`, output goes straight to that file. Without it, output is captured
    /// and returned. Wine commands should always use a log file: `wineserver` inherits
    /// the output handles and can keep a pipe open long after `wine` itself exits.
    @discardableResult
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        logFile: URL? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let buffer = OutputBuffer()
        var pipe: Pipe?
        var logHandle: FileHandle?

        if let logFile {
            logHandle = try openLog(logFile)
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            let outputPipe = Pipe()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { buffer.append(chunk) }
            }
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            pipe = outputPipe
        }

        let handleToClose = logHandle
        let pipeToStop = pipe
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                pipeToStop?.fileHandleForReading.readabilityHandler = nil
                try? handleToClose?.close()
                continuation.resume(returning: ProcessResult(status: finished.terminationStatus, output: buffer.string))
            }
            do {
                try process.run()
            } catch {
                pipeToStop?.fileHandleForReading.readabilityHandler = nil
                try? handleToClose?.close()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Starts a long-running process (a game) with output going to `logFile`, and returns at once.
    public static func launch(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        logFile: URL,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let handle = try openLog(logFile)
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { finished in
            try? handle.close()
            onExit?(finished.terminationStatus)
        }
        try process.run()
        return process
    }

    static func openLog(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
