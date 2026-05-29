import Foundation

struct BuildResult: Codable, Equatable {
    var command: String
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

enum ProcessRunnerError: LocalizedError {
    case emptyCommand
    case commandNotAllowed(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand: return "Command is empty."
        case .commandNotAllowed(let command): return "Command not allowed: \(command)"
        case .launchFailed(let message): return message
        }
    }
}

final class ProcessRunner {
    private static let gitEnvironment: [String: String] = [
        "GIT_PAGER": "cat",
        "PAGER": "cat"
    ]

    func run(command: String, workingDirectory: URL, timeoutSeconds: TimeInterval) throws -> BuildResult {
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = parts.first, !executable.isEmpty else { throw ProcessRunnerError.emptyCommand }
        let arguments = Array(parts.dropFirst())

        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = workingDirectory

        return try runProcess(process, commandLabel: command, timeoutSeconds: timeoutSeconds)
    }

    func runGit(_ arguments: [String], workingDirectory: URL, timeoutSeconds: TimeInterval = 45) throws -> BuildResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in Self.gitEnvironment {
            environment[key] = value
        }
        process.environment = environment

        return try runProcess(process, commandLabel: "git " + arguments.joined(separator: " "), timeoutSeconds: timeoutSeconds)
    }

    private func runProcess(_ process: Process, commandLabel: String, timeoutSeconds: TimeInterval) throws -> BuildResult {
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let group = DispatchGroup()
        group.enter()
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return BuildResult(
            command: commandLabel,
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}

enum GitToolOutput {
    static let maxDiffCharacters = 120_000

    static func formatDiff(_ result: BuildResult, timeoutSeconds: TimeInterval) -> String {
        if result.timedOut {
            return "git diff timed out after \(Int(timeoutSeconds))s. Try again after closing other git tools, or reduce uncommitted changes.\n\(truncate(result.combinedOutput))"
        }
        if result.exitCode != 0, result.combinedOutput.isEmpty {
            return "git diff failed with exit code \(result.exitCode)."
        }
        return truncate(result.combinedOutput)
    }

    static func formatStatus(_ result: BuildResult, timeoutSeconds: TimeInterval) -> String {
        if result.timedOut {
            return "git status timed out after \(Int(timeoutSeconds))s.\n\(truncate(result.combinedOutput))"
        }
        return truncate(result.combinedOutput)
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxDiffCharacters else { return text }
        return String(text.prefix(maxDiffCharacters)) + "\n\n… output truncated (\(text.count) characters total)"
    }
}
