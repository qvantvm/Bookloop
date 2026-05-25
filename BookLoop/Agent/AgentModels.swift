import Foundation

enum AgentTaskType: String, Codable, CaseIterable, Identifiable {
    case summarizeProject
    case applyReviewFeedback
    case improveCurrentChapter
    case fixBuildErrors
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .summarizeProject: return "Summarize Project"
        case .applyReviewFeedback: return "Apply Review Feedback"
        case .improveCurrentChapter: return "Improve Current Chapter"
        case .fixBuildErrors: return "Fix Build Errors"
        case .custom: return "Custom Task"
        }
    }
}

struct AgentTask: Equatable {
    var type: AgentTaskType
    var instruction: String
}

struct AgentToolLogEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var toolName: String
    var arguments: String
    var resultSummary: String
    var succeeded: Bool
    var timestamp: Date
}

struct AgentResult: Equatable {
    var sessionID: UUID
    var summary: String
    var changedFiles: [String]
    var patchProposalPath: String?
    var patchProposalAbsolutePath: String?
    var proposalPatch: String?
    var buildResult: BuildResult?
    var toolLog: [AgentToolLogEntry]
    var unresolvedIssues: [String]
    var sessionDirectory: URL
}

enum AgentPromptBuilder {
    private static let baseSystemPrompt = """
    You are BookLoop Agent, a careful local editing agent for a technical book project.
    You are not inside an IDE. You can only inspect and modify the project through the tools provided by BookLoop.
    Rules:
    - Read before editing.
    - Prefer small, reviewable changes.
    - Preserve the author's voice.
    - Never modify files outside allowed write globs.
    - Never read protected paths.
    - Never invent citations, references, or facts.
    - If information is missing, leave a TODO or report an unresolved issue.
    - Prefer precise replacements using apply_patch to stage edits.
    - apply_patch stages changes only; book files are not modified on disk until a human applies the patch in Tools → Patches.
    - Open review items often contain actionable guidance in the body or Conversation section even when suggested_fix is empty or says TODO.
    - When asked to apply review feedback, read the chapter source file and stage concrete edits that address the review.
    - Do not run run_build unless explicitly asked to validate the current committed/working tree.
    - Always return a concise summary, staged files, and unresolved issues.
    """

    static func systemPrompt(for book: BookConfig) -> String {
        var lines = [baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let relative = BookLLMsContext.relativePath(for: book) {
            lines.append("Book context file: \(relative). A summary is included below; use read_file on chapter markdown for full source text.")
        }
        if let excerpt = BookLLMsContext.promptExcerpt(for: book) {
            lines.append("")
            lines.append("--- llms.txt ---")
            lines.append(excerpt)
        }
        return lines.joined(separator: "\n")
    }

    static func taskPrompt(task: AgentTask, project: BookProject) -> String {
        var lines = ["Task type: \(task.type.displayName)"]
        if !task.instruction.isEmpty {
            lines.append("User instruction: \(task.instruction)")
        }
        lines.append("Project summary: \(project.projectMap.compactSummary)")
        if let chapter = project.currentChapterID?.nilIfBlank {
            lines.append("Current chapter ID: \(chapter)")
        }
        if let relative = BookLLMsContext.relativePath(for: project.book) {
            lines.append("llms.txt: \(relative)")
        }
        lines.append("Build command: \(project.config.buildCommand)")
        lines.append("Patch output directory: \(project.book.patchDirectoryPath)")
        lines.append("Allowed write globs: \(project.config.allowedWriteGlobs.joined(separator: ", "))")

        switch task.type {
        case .applyReviewFeedback:
            lines.append("""
            Instructions:
            1. Call read_review_items with status "open".
            2. For each open review where has_actionable_guidance is true, use source_file and actionable_guidance as the primary instructions.
            3. Ignore placeholder suggested_fix values such as "TODO: add suggested fix".
            4. Read the target chapter markdown, then stage improvements with apply_patch that address the review (expand stubs, fill missing sections, clarify confusing parts).
            5. When actionable_guidance lists multiple numbered sections or headings, stage one apply_patch per section that still contains stubs, TBD, TODO, or placeholder text. Do not stop after only one or two sections if more remain.
            6. Prefer several small apply_patch calls over one huge rewrite.
            7. Use as many tool iterations as needed (up to the configured limit) to cover the review.
            8. If has_actionable_guidance is true for any review, you must stage at least one apply_patch before finishing.
            """)
            lines.append(openReviewDigest(for: project))
        case .improveCurrentChapter:
            lines.append("""
            Instructions:
            1. Use the current chapter ID to locate docs/<chapter_id>.md (or read from preview context).
            2. Read the chapter file and any open read_review_items targeting this chapter.
            3. Stage concrete improvements with apply_patch.
            """)
        case .fixBuildErrors:
            lines.append("""
            Instructions:
            1. Run run_build and inspect failures.
            2. Read affected files and stage fixes with apply_patch.
            """)
        default:
            break
        }

        return lines.joined(separator: "\n")
    }

    private static func openReviewDigest(for project: BookProject) -> String {
        let parser = ReviewItemParser()
        guard let items = try? parser.parseReviewItems(book: project.book) else {
            return "Open reviews: unable to load."
        }
        let openItems = items.filter { $0.status == .open }
        guard !openItems.isEmpty else { return "Open reviews: none." }

        var lines = ["Open reviews (\(openItems.count)):"]
        for item in openItems.prefix(8) {
            let source = item.sourceFile?.nilIfBlank ?? AgentTools.inferredSourceFile(for: item)
            let preview = (item.body ?? "").prefix(240).replacingOccurrences(of: "\n", with: " ")
            let actionable = (item.body ?? "").count >= 200
            lines.append("- \(item.id) chapter=\(item.chapter ?? "?") source=\(source) actionable=\(actionable ? "yes" : "no") title=\(item.title)")
            if !preview.isEmpty {
                lines.append("  body_preview: \(preview)...")
            }
        }
        if openItems.count > 8 {
            lines.append("- ... and \(openItems.count - 8) more")
        }
        return lines.joined(separator: "\n")
    }
}

enum AgentToolRegistry {
    static var definitions: [OpenAIToolDefinition] {
        [
            tool(name: "list_files", description: "List project-relative file paths matching a glob.", properties: [
                "glob": prop("string", "Glob pattern such as docs/**/*.md")
            ], required: []),
            tool(name: "read_file", description: "Read a UTF-8 text file from the project.", properties: [
                "path": prop("string", "Project-relative file path")
            ], required: ["path"]),
            tool(name: "search_text", description: "Search indexed project text.", properties: [
                "query": prop("string", "Search query"),
                "glob": prop("string", "Optional glob filter"),
                "limit": prop("integer", "Max results, default 10")
            ], required: ["query"]),
            tool(name: "read_review_items", description: "Read structured review items including body, Conversation, source_file, and whether suggested_fix is only a placeholder.", properties: [
                "status": prop("string", "Filter by status such as open"),
                "target": prop("string", "Filter by target chapter/path")
            ], required: []),
            tool(name: "apply_patch", description: "Stage an exact old_text to new_text replacement once in a file. Does not modify disk until the patch is applied in Patches.", properties: [
                "path": prop("string", "Project-relative file path"),
                "old_text": prop("string", "Exact text to replace"),
                "new_text": prop("string", "Replacement text")
            ], required: ["path", "old_text", "new_text"]),
            tool(name: "run_build", description: "Run the configured validation/build command.", properties: [:], required: []),
            tool(name: "get_git_status", description: "Return git status --porcelain.", properties: [:], required: []),
            tool(name: "get_git_diff", description: "Return git diff for the project.", properties: [:], required: [])
        ]
    }

    static func execute(name: String, argumentsJSON: String, context: inout AgentToolContext) throws -> String {
        let args = parseJSON(argumentsJSON)
        switch name {
        case "list_files":
            let glob = args["glob"] as? String
            let files = try AgentTools.listFiles(glob: glob, context: context)
            return encode(files)
        case "read_file":
            guard let path = args["path"] as? String else { throw AgentToolError.unknownTool(name) }
            return try AgentTools.readFile(path: path, context: context)
        case "search_text":
            let query = args["query"] as? String ?? ""
            let glob = args["glob"] as? String
            let limit = args["limit"] as? Int ?? 10
            return encode(AgentTools.searchText(query: query, glob: glob, limit: limit, context: context))
        case "read_review_items":
            return encode(try AgentTools.readReviewItems(
                status: args["status"] as? String,
                target: args["target"] as? String,
                context: context
            ))
        case "apply_patch":
            guard let path = args["path"] as? String,
                  let oldText = args["old_text"] as? String,
                  let newText = args["new_text"] as? String else { throw AgentToolError.unknownTool(name) }
            return encode(try AgentTools.applyPatch(path: path, oldText: oldText, newText: newText, context: &context))
        case "run_build":
            return encode(try AgentTools.runBuild(context: context))
        case "get_git_status":
            return try AgentTools.gitStatus(context: context)
        case "get_git_diff":
            return try AgentTools.gitDiff(context: context)
        default:
            throw AgentToolError.unknownTool(name)
        }
    }

    private static func tool(name: String, description: String, properties: [String: OpenAIJSONSchemaProperty], required: [String]) -> OpenAIToolDefinition {
        OpenAIToolDefinition.function(
            name: name,
            description: description,
            parameters: .object(properties: properties, required: required)
        )
    }

    private static func prop(_ type: String, _ description: String) -> OpenAIJSONSchemaProperty {
        OpenAIJSONSchemaProperty(type: type, description: description)
    }

    private static func parseJSON(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder.pretty.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
