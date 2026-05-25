import Foundation

struct StagedFileChange: Equatable {
    var path: String
    var oldContent: String
    var newContent: String
}

enum AgentPatchExporter {
    struct ExportResult: Equatable {
        var relativePatchPath: String
        var absolutePatchPath: String
        var rawPatch: String
    }

    static func export(
        changes: [StagedFileChange],
        project: BookProject,
        task: AgentTask,
        sessionID: UUID,
        summary: String
    ) throws -> ExportResult {
        guard !changes.isEmpty else {
            throw AgentPatchExportError.noStagedChanges
        }

        return try project.withSecurityScoped {
            let sessionDir = project.sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            let diffDir = sessionDir.appendingPathComponent("diff-staging", isDirectory: true)
            try FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true)

            var patchParts: [String] = [
                "# BookLoop Agent Proposal",
                "# Task: \(task.type.displayName)",
                "# Session: \(sessionID.uuidString)",
                ""
            ]
            if !summary.isEmpty {
                patchParts.append("# Summary")
                patchParts.append(summary)
                patchParts.append("")
            }

            let runner = ProcessRunner()
            for (index, change) in changes.enumerated() {
                let oldFile = diffDir.appendingPathComponent("\(index)-old")
                let newFile = diffDir.appendingPathComponent("\(index)-new")
                try change.oldContent.write(to: oldFile, atomically: true, encoding: .utf8)
                try change.newContent.write(to: newFile, atomically: true, encoding: .utf8)

                let result = try runner.runGit(
                    ["diff", "--no-index", "--", oldFile.path, newFile.path],
                    workingDirectory: project.rootURL
                )
                let diffText = normalizeDiffPaths(
                    in: result.stdout.isEmpty ? result.stderr : result.stdout,
                    relativePath: change.path
                )
                guard !diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                patchParts.append(diffText)
            }

            let rawPatch = patchParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            guard rawPatch.contains("diff --git") || rawPatch.contains("--- ") else {
                throw AgentPatchExportError.emptyPatch
            }

            let patchesDirectory = project.book.patchDirectoryPath
            try FileHelpers.ensureDirectory(patchesDirectory)
            let filename = "agent-\(DateFormatting.taskFilename.string(from: Date()))-\(task.type.rawValue.slugified()).patch"
            let patchURL = URL(fileURLWithPath: patchesDirectory, isDirectory: true).appendingPathComponent(filename)
            try rawPatch.write(to: patchURL, atomically: true, encoding: .utf8)

            let sessionProposalURL = sessionDir.appendingPathComponent("proposal.patch")
            try rawPatch.write(to: sessionProposalURL, atomically: true, encoding: .utf8)

            try writeJSON(
                ["proposal_patch": project.pathGuard.relativePath(for: patchURL)],
                to: sessionDir.appendingPathComponent("proposal.json")
            )

            return ExportResult(
                relativePatchPath: project.pathGuard.relativePath(for: patchURL),
                absolutePatchPath: patchURL.path,
                rawPatch: rawPatch
            )
        }
    }

    static func deleteProposal(at absolutePath: String, project: BookProject, sessionID: UUID) throws {
        try project.withSecurityScoped {
            if FileManager.default.fileExists(atPath: absolutePath) {
                try FileManager.default.removeItem(atPath: absolutePath)
            }
            let sessionProposal = project.sessionsDirectory
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
                .appendingPathComponent("proposal.patch")
            if FileManager.default.fileExists(atPath: sessionProposal.path) {
                try FileManager.default.removeItem(at: sessionProposal)
            }
        }
    }

    private static func normalizeDiffPaths(in diff: String, relativePath: String) -> String {
        let normalizedPath = relativePath.replacingOccurrences(of: "\\", with: "/")
        var lines = diff.components(separatedBy: .newlines).filter { line in
            !line.hasPrefix("index ")
        }
        for index in lines.indices {
            if lines[index].hasPrefix("diff --git ") {
                lines[index] = "diff --git a/\(normalizedPath) b/\(normalizedPath)"
            } else if lines[index].hasPrefix("--- ") {
                lines[index] = "--- a/\(normalizedPath)"
            } else if lines[index].hasPrefix("+++ ") {
                lines[index] = "+++ b/\(normalizedPath)"
            } else if lines[index].hasPrefix("index ") {
                continue
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func writeJSON(_ value: [String: String], to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}

enum AgentPatchExportError: LocalizedError {
    case noStagedChanges
    case emptyPatch

    var errorDescription: String? {
        switch self {
        case .noStagedChanges: return "No staged changes to export."
        case .emptyPatch: return "Could not generate a unified diff from staged changes."
        }
    }
}
