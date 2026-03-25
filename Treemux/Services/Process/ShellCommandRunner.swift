import Foundation

/// Result of running a shell command, containing stdout, stderr, and exit code.
struct CommandResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

/// A utility for running shell commands as subprocesses.
enum ShellCommandRunner {

    /// Run an executable at the given path with optional arguments, working directory, and environment.
    static func run(
        _ command: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        if let environment {
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, new in new }
            process.environment = env
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                continuation.resume(returning: CommandResult(
                    output: stdout,
                    errorOutput: stderr,
                    exitCode: proc.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a shell command string via /bin/sh -c.
    static func shell(
        _ command: String,
        workingDirectory: URL? = nil
    ) async throws -> CommandResult {
        try await run("/bin/sh", arguments: ["-c", command], workingDirectory: workingDirectory)
    }
}
