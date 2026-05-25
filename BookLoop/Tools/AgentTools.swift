import Foundation

struct AgentToolContext {
    var project: BookProject
    var searchIndex: SearchIndex
    var sessionID: UUID
    var sessionsDirectory: URL
    var allowReviewEdits: Bool
    var buildTimeoutSeconds: TimeInterval
    var stagedChanges: [StagedFileChange]

    var changedFiles: [String] {
        stagedChanges.map(\.path)
    }
}

enum AgentTools {
    static func listFiles(glob: String?, context: AgentToolContext) throws -> [String] {
        let pattern = glob?.nilIfBlank ?? "**/*"
        return context.project.projectMap.relativePaths(matchingGlob: pattern)
    }

    static func readFile(path: String, context: AgentToolContext) throws -> String {
        try context.project.withSecurityScoped {
            try context.project.pathGuard.readText(at: path)
        }
    }

    static func searchText(query: String, glob: String?, limit: Int, context: AgentToolContext) -> [SearchResult] {
        context.searchIndex.searchText(
            query,
            glob: glob,
            limit: limit,
            book: context.project.book,
            config: context.project.config
        )
    }

    static func readReviewItems(status: String?, target: String?, context: AgentToolContext) throws -> [[String: String]] {
        let parser = ReviewItemParser()
        let items = try context.project.withSecurityScoped {
            try parser.parseReviewItems(book: context.project.book)
        }

        let deduped = dedupeReviewItemsByChapter(items)

        return deduped.compactMap { item -> [String: String]? in
            if let status, !status.isEmpty, item.status.rawValue.lowercased() != status.lowercased() {
                return nil
            }
            if let target, !target.isEmpty {
                let chapter = item.chapter ?? ""
                let normalizedTarget = target.replacingOccurrences(of: "docs/", with: "")
                if chapter != target && chapter != normalizedTarget && !target.hasSuffix(chapter) {
                    return nil
                }
            }
            let suggestedFix = item.suggestedFix ?? ""
            let rawContent = try? String(contentsOf: URL(fileURLWithPath: item.filePath), encoding: .utf8)
            let conversation = rawContent.flatMap { ReviewItemParser().conversationSection(from: $0) } ?? ""
            let actionable = ([item.body].compactMap { $0 } + [conversation])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let suggestedFixIsPlaceholder = suggestedFix.isEmpty
                || suggestedFix.localizedCaseInsensitiveContains("TODO: add suggested fix")
            let hasActionableGuidance = actionable.count >= 200
                || actionable.localizedCaseInsensitiveContains("### Assistant")
                || actionable.localizedCaseInsensitiveContains("should contain")
            return [
                "id": item.id,
                "title": item.title,
                "chapter": item.chapter ?? "",
                "type": item.type ?? "",
                "severity": item.severity ?? "",
                "status": item.status.rawValue,
                "source_file": item.sourceFile ?? inferredSourceFile(for: item),
                "body": item.body ?? "",
                "conversation": conversation,
                "actionable_guidance": actionable,
                "has_actionable_guidance": hasActionableGuidance ? "true" : "false",
                "suggested_fix": suggestedFix,
                "suggested_fix_is_placeholder": suggestedFixIsPlaceholder ? "true" : "false",
                "guidance_note": suggestedFixIsPlaceholder
                    ? "suggested_fix is a placeholder; use actionable_guidance and conversation instead."
                    : "suggested_fix may supplement actionable_guidance."
            ]
        }
    }

    static func inferredSourceFile(for item: ReviewItem) -> String {
        guard let chapter = item.chapter?.nilIfBlank else { return "" }
        if chapter.contains("/") || chapter.hasSuffix(".md") {
            return chapter.hasPrefix("docs/") ? chapter : "docs/\(chapter)"
        }
        return "docs/\(chapter).md"
    }

    static func hasActionableOpenReviews(for project: BookProject) -> Bool {
        guard let items = try? ReviewItemParser().parseReviewItems(book: project.book) else { return false }
        return items.contains { item in
            guard item.status == .open else { return false }
            let body = item.body ?? ""
            return body.count >= 200
                || body.localizedCaseInsensitiveContains("### Assistant")
                || body.localizedCaseInsensitiveContains("should contain")
        }
    }

    static func expectedPatchCount(for project: BookProject) -> Int {
        guard let items = try? ReviewItemParser().parseReviewItems(book: project.book) else { return 1 }
        let openItems = items.filter { $0.status == .open }
        let counts = openItems.map { estimatedSectionCount(from: $0.body ?? "") }
        let total = counts.reduce(0, +)
        return min(max(total, 1), 12)
    }

    private static func estimatedSectionCount(from text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        let numbered = lines.filter { line in
            line.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil
        }.count
        let headings = lines.filter { line in
            line.hasPrefix("### ") || line.hasPrefix("## ")
        }.count
        if numbered >= 2 { return numbered }
        if headings >= 2 { return headings }
        return text.count >= 400 ? 3 : 1
    }

    private static func dedupeReviewItemsByChapter(_ items: [ReviewItem]) -> [ReviewItem] {
        var byChapter: [String: ReviewItem] = [:]
        for item in items {
            let key = item.chapter ?? item.id
            if let existing = byChapter[key] {
                let existingDate = existing.createdAt ?? .distantPast
                let itemDate = item.createdAt ?? .distantPast
                if itemDate >= existingDate {
                    byChapter[key] = item
                }
            } else {
                byChapter[key] = item
            }
        }
        return byChapter.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    static func applyPatch(path: String, oldText: String, newText: String, context: inout AgentToolContext) throws -> [String: String] {
        try context.project.withSecurityScoped {
            if !context.allowReviewEdits, isReviewPath(path, reviewRoot: context.project.config.reviewRoot) {
                throw AgentToolError.reviewEditsDisabled
            }
            _ = try context.project.pathGuard.validateWrite(path)

            if let index = context.stagedChanges.firstIndex(where: { $0.path == path }) {
                let working = context.stagedChanges[index].newContent
                let occurrences = working.components(separatedBy: oldText).count - 1
                guard occurrences == 1 else {
                    throw AgentToolError.patchNotUnique(occurrences: occurrences)
                }
                context.stagedChanges[index].newContent = working.replacingOccurrences(of: oldText, with: newText)
            } else {
                let url = try context.project.pathGuard.validateRead(path)
                let content = try String(contentsOf: url, encoding: .utf8)
                let occurrences = content.components(separatedBy: oldText).count - 1
                guard occurrences == 1 else {
                    throw AgentToolError.patchNotUnique(occurrences: occurrences)
                }
                let updated = content.replacingOccurrences(of: oldText, with: newText)
                context.stagedChanges.append(StagedFileChange(path: path, oldContent: content, newContent: updated))
            }

            return [
                "path": path,
                "status": "staged"
            ]
        }
    }

    static func runBuild(context: AgentToolContext) throws -> BuildResult {
        let command = context.project.config.buildCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command == context.project.config.buildCommand else {
            throw ProcessRunnerError.commandNotAllowed(command)
        }
        return try context.project.withSecurityScoped {
            try ProcessRunner().run(
                command: command,
                workingDirectory: context.project.rootURL,
                timeoutSeconds: context.buildTimeoutSeconds
            )
        }
    }

    static func gitStatus(context: AgentToolContext) throws -> String {
        guard context.project.hasGit else { return "" }
        return try context.project.withSecurityScoped {
            try ProcessRunner().runGit(["status", "--porcelain"], workingDirectory: context.project.rootURL).combinedOutput
        }
    }

    static func gitDiff(context: AgentToolContext) throws -> String {
        guard context.project.hasGit else { return "" }
        return try context.project.withSecurityScoped {
            try ProcessRunner().runGit(["diff", "--", "."], workingDirectory: context.project.rootURL).combinedOutput
        }
    }

    private static func isReviewPath(_ path: String, reviewRoot: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let root = reviewRoot.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !root.isEmpty else { return normalized.hasPrefix("reviews/") }
        return normalized == root || normalized.hasPrefix(root + "/")
    }
}

enum AgentToolError: LocalizedError {
    case patchNotUnique(occurrences: Int)
    case reviewEditsDisabled
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .patchNotUnique(let count):
            return "old_text must match exactly once; found \(count) occurrences."
        case .reviewEditsDisabled:
            return "Editing review items is disabled in app settings."
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        }
    }
}
