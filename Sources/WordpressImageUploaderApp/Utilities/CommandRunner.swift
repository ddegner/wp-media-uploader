import Foundation

enum CommandOutputStream {
    case stdout
    case stderr
}

struct CommandSpec {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]?
    var currentDirectoryURL: URL?
    var displayName: String
}

struct CommandResult {
    var exitCode: Int32
    var stdoutLines: [String]
    var stderrLines: [String]
}

enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderrTail: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return "Failed to launch command: \(message)"
        case let .nonZeroExit(code, stderrTail):
            if stderrTail.isEmpty {
                return "Command failed with exit code \(code)."
            }
            return "Command failed with exit code \(code): \(stderrTail)"
        }
    }
}

private actor ProcessTermination {
    private var exitCode: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func finish(_ code: Int32) {
        guard exitCode == nil else { return }
        exitCode = code
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: code)
        }
    }

    func wait() async -> Int32 {
        if let exitCode {
            return exitCode
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

actor CommandRunner {
    private var activeProcesses: [ObjectIdentifier: Process] = [:]

    func run(
        _ spec: CommandSpec,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments

        if let environment = spec.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        if let cwd = spec.currentDirectoryURL {
            process.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let termination = ProcessTermination()
        process.terminationHandler = { finished in
            Task {
                await termination.finish(finished.terminationStatus)
            }
        }

        let processID = ObjectIdentifier(process)
        activeProcesses[processID] = process
        defer { activeProcesses[processID] = nil }

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently using structured async I/O.
            // Each sequence reaches EOF after the process exits and closes
            // its write ends, so no blocking calls or readabilityHandler races.
            async let stdoutResult = Self.collectLines(
                from: stdoutPipe.fileHandleForReading, stream: .stdout, onLine: onLine
            )
            async let stderrResult = Self.collectLines(
                from: stderrPipe.fileHandleForReading, stream: .stderr, onLine: onLine
            )
            async let exitCodeResult = termination.wait()

            let stdoutLines = try await stdoutResult
            let stderrLines = try await stderrResult
            let exitCode = await exitCodeResult

            try Task.checkCancellation()
            return CommandResult(
                exitCode: exitCode,
                stdoutLines: stdoutLines,
                stderrLines: stderrLines
            )
        } onCancel: {
            process.terminate()
        }
    }

    func cancelActiveProcess() {
        for process in activeProcesses.values {
            process.terminate()
        }
    }

    /// Reads complete lines from a file handle using async byte sequences.
    /// Returns when the handle reaches EOF (i.e. the process has exited).
    private nonisolated static func collectLines(
        from handle: FileHandle,
        stream: CommandOutputStream,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)?
    ) async throws -> [String] {
        var lines: [String] = []
        for try await line in handle.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            onLine?(stream, trimmed)
        }
        return lines
    }
}
