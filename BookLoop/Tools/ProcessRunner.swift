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
            command: command,
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    func runGit(_ arguments: [String], workingDirectory: URL, timeoutSeconds: TimeInterval = 30) throws -> BuildResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return BuildResult(
            command: "git " + arguments.joined(separator: " "),
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: false
        )
    }
}
