import Foundation

enum AgentTaskCategory: String, CaseIterable {
    case reviewsAndContent
    case assetsAndLinks
    case explore

    var sectionTitle: String {
        switch self {
        case .reviewsAndContent: return "Reviews & content"
        case .assetsAndLinks: return "Assets & links"
        case .explore: return "Explore"
        }
    }
}

enum AgentTaskType: String, Codable, CaseIterable, Identifiable {
    case summarizeProject
    case applyReviewFeedback
    case improveCurrentChapter
    case fixBrokenLinks
    case custom

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "fixBuildErrors":
            self = .fixBrokenLinks
        default:
            guard let value = AgentTaskType(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown AgentTaskType: \(raw)"
                )
            }
            self = value
        }
    }

    var displayName: String {
        switch self {
        case .summarizeProject: return "Summarize Project"
        case .applyReviewFeedback: return "Apply Review Feedback"
        case .improveCurrentChapter: return "Improve Current Chapter"
        case .fixBrokenLinks: return "Fix Broken Links"
        case .custom: return "Custom Task"
        }
    }

    var category: AgentTaskCategory? {
        switch self {
        case .applyReviewFeedback, .improveCurrentChapter: return .reviewsAndContent
        case .fixBrokenLinks: return .assetsAndLinks
        case .summarizeProject: return .explore
        case .custom: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .summarizeProject: return "doc.text.magnifyingglass"
        case .applyReviewFeedback: return "text.bubble"
        case .improveCurrentChapter: return "text.page"
        case .fixBrokenLinks: return "link.badge.plus"
        case .custom: return "square.and.pencil"
        }
    }

    var taskDescription: String {
        switch self {
        case .summarizeProject:
            return "Scan chapters, reviews, and config to produce a project summary."
        case .applyReviewFeedback:
            return "Read open review items and propose chapter edits as a patch."
        case .improveCurrentChapter:
            return "Improve the chapter open in Reading mode using the current chapter ID."
        case .fixBrokenLinks:
            return "Find broken figure paths, missing local assets, and bad external asset URLs, then propose fixes."
        case .custom:
            return "Run with your own instruction using the agent tools."
        }
    }

    static var presetTasks: [AgentTaskType] {
        allCases.filter { $0 != .custom }
    }

    static func tasks(in category: AgentTaskCategory) -> [AgentTaskType] {
        presetTasks.filter { $0.category == category }
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

enum AgentRunPhase: Equatable {
    case idle
    case preparing
    case waitingForModel
    case runningTool
    case exportingPatch
    case savingSession
}

struct AgentRunStatus: Equatable {
    var phase: AgentRunPhase = .idle
    var taskTitle: String = ""
    var detail: String = ""
    var startedAt: Date?
    var iteration: Int = 0
    var maxIterations: Int = 0
    var toolsCompleted: Int = 0
    var currentToolName: String?

    var isActive: Bool {
        phase != .idle
    }

    var headline: String {
        switch phase {
        case .idle:
            return ""
        case .preparing:
            return "Starting agent…"
        case .waitingForModel:
            if maxIterations > 0 {
                return "Waiting for model (step \(iteration) of \(maxIterations))…"
            }
            return "Waiting for model…"
        case .runningTool:
            if let currentToolName {
                return "Running \(currentToolName.agentToolDisplayName)…"
            }
            return "Running tool…"
        case .exportingPatch:
            return "Writing patch proposal…"
        case .savingSession:
            return "Saving session log…"
        }
    }

    var subheadline: String {
        if !detail.isEmpty { return detail }
        if toolsCompleted > 0 {
            return "\(toolsCompleted) tool call\(toolsCompleted == 1 ? "" : "s") completed"
        }
        return "This can take a minute while the model reads your book."
    }
}

private extension String {
    var agentToolDisplayName: String {
        replacingOccurrences(of: "_", with: " ")
    }
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
    - Use fetch_url to read public HTTPS pages (documentation, GitHub READMEs, etc.) before citing external projects.
    - If information is missing, leave a TODO or report an unresolved issue.
    - Use grep for regex or exact substring search with line numbers across project files.
    - Use search_text for quick indexed lookup when regex is not needed.
    - Prefer precise replacements using apply_patch to stage edits.
    - apply_patch stages changes only; book files are not modified on disk until a human applies the patch in Tools → Patches.
    - Open review items often contain actionable guidance in the body or Conversation section even when suggested_fix is empty or says TODO.
    - When asked to apply review feedback, read the chapter source file and stage concrete edits that address the review.
    - BookLoop renders chapter preview in Swift (markdown-it + KaTeX). Do not assume mkdocs or another site generator is installed.
    - For validation, prefer scan_broken_links. Only use run_build when this book has a validation command configured AND the task explicitly asks to run that shell command.
    - Never call run_build for mkdocs or when no validation command is configured for this book.
    - run_build is not available for this book unless a non-mkdocs validation command is configured in Settings.
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
        if project.hasValidationCommand, let command = project.effectiveBuildCommand {
            lines.append("Validation command (optional shell): \(command)")
        } else {
            lines.append("Validation: use scan_broken_links — no external build command is configured for this book.")
        }
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
            5. When a review mentions an external URL or project, call fetch_url on that URL before writing factual claims about it.
            6. When actionable_guidance lists multiple numbered sections or headings, stage one apply_patch per section that still contains stubs, TBD, TODO, or placeholder text. Do not stop after only one or two sections if more remain.
            7. Prefer several small apply_patch calls over one huge rewrite.
            8. Use as many tool iterations as needed (up to the configured limit) to cover the review.
            9. If has_actionable_guidance is true for any review, you must stage at least one apply_patch before finishing.
            """)
            lines.append(openReviewDigest(for: project))
        case .improveCurrentChapter:
            lines.append("""
            Instructions:
            1. Use the current chapter ID to locate docs/<chapter_id>.md (or read from preview context).
            2. Read the chapter file and any open read_review_items targeting this chapter.
            3. Stage concrete improvements with apply_patch.
            """)
        case .fixBrokenLinks:
            lines.append("""
            Instructions:
            1. Call scan_broken_links to list missing figure files, broken local asset paths, stale figures, and external asset URLs that need verification.
            2. For external HTTPS asset links, call fetch_url to confirm they still work before changing paths.
            3. Read affected markdown files and use list_files or grep to locate the correct asset paths under docs/ and docs/assets/.
            4. Stage path fixes with apply_patch. Prefer correcting references to existing files over inventing new assets.
            5. If an asset is missing but a figure source exists under figures/, note it as an unresolved issue rather than guessing output paths.
            """)
        case .custom:
            if !project.hasValidationCommand {
                lines.append("""
                Instructions:
                - If this task mentions validating the book, use scan_broken_links instead of run_build.
                - Do not run mkdocs or other external build tools unless a validation command is configured in book Settings.
                """)
            }
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
    static func definitions(for project: BookProject) -> [OpenAIToolDefinition] {
        var tools = coreDefinitions
        if project.hasValidationCommand {
            tools.append(runBuildTool)
        }
        return tools
    }

    private static var coreDefinitions: [OpenAIToolDefinition] {
        [
            tool(name: "list_files", description: "List project-relative file paths matching a glob.", properties: [
                "glob": prop("string", "Glob pattern such as docs/**/*.md")
            ], required: []),
            tool(name: "read_file", description: "Read a UTF-8 text file from the project.", properties: [
                "path": prop("string", "Project-relative file path")
            ], required: ["path"]),
            tool(name: "search_text", description: "Quick indexed substring search across chapters, reviews, and config files.", properties: [
                "query": prop("string", "Search query"),
                "glob": prop("string", "Optional glob filter"),
                "limit": prop("integer", "Max results, default 10")
            ], required: ["query"]),
            tool(name: "grep", description: "Search file contents with a regex or fixed string. Returns path, line number, and matching line. Respects project path guards.", properties: [
                "pattern": prop("string", "Regex pattern, or literal string when fixed_strings is true"),
                "glob": prop("string", "Optional glob filter such as docs/**/*.md"),
                "path": prop("string", "Optional project-relative file or directory prefix to limit search"),
                "ignore_case": prop("boolean", "Case-insensitive match, default false"),
                "fixed_strings": prop("boolean", "Treat pattern as literal text instead of regex, default false"),
                "limit": prop("integer", "Max matches to return, default 50")
            ], required: ["pattern"]),
            tool(name: "read_review_items", description: "Read structured review items including body, Conversation, source_file, and whether suggested_fix is only a placeholder.", properties: [
                "status": prop("string", "Filter by status such as open"),
                "target": prop("string", "Filter by target chapter/path")
            ], required: []),
            tool(name: "fetch_url", description: "Fetch a public HTTPS URL and return readable text. HTML is simplified to plain text. GitHub repo and blob URLs are rewritten to raw content when possible. Response size is capped by app settings.", properties: [
                "url": prop("string", "Full HTTPS URL to fetch")
            ], required: ["url"]),
            tool(name: "apply_patch", description: "Stage an exact old_text to new_text replacement once in a file. Does not modify disk until the patch is applied in Patches.", properties: [
                "path": prop("string", "Project-relative file path"),
                "old_text": prop("string", "Exact text to replace"),
                "new_text": prop("string", "Replacement text")
            ], required: ["path", "old_text", "new_text"]),
            tool(name: "scan_broken_links", description: "Scan chapter markdown for missing figure files, broken local asset links, stale figures, and external asset URLs.", properties: [:], required: []),
            tool(name: "get_git_status", description: "Return git status --porcelain.", properties: [:], required: []),
            tool(name: "get_git_diff", description: "Return a summary and patch for uncommitted changes (excludes .bookloop/ logs; capped output, ~45s timeout).", properties: [:], required: [])
        ]
    }

    private static var runBuildTool: OpenAIToolDefinition {
        tool(
            name: "run_build",
            description: "Run this book's optional validation shell command from Settings. Not used for Swift preview rendering.",
            properties: [:],
            required: []
        )
    }

    static func execute(name: String, argumentsJSON: String, context: inout AgentToolContext) async throws -> String {
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
        case "grep":
            let pattern = args["pattern"] as? String ?? ""
            let glob = args["glob"] as? String
            let path = args["path"] as? String
            let ignoreCase = args["ignore_case"] as? Bool ?? false
            let fixedStrings = args["fixed_strings"] as? Bool ?? false
            let limit = args["limit"] as? Int ?? 50
            return encode(try AgentTools.grep(
                pattern: pattern,
                glob: glob,
                path: path,
                ignoreCase: ignoreCase,
                fixedStrings: fixedStrings,
                limit: limit,
                context: context
            ))
        case "read_review_items":
            return encode(try AgentTools.readReviewItems(
                status: args["status"] as? String,
                target: args["target"] as? String,
                context: context
            ))
        case "fetch_url":
            guard let url = args["url"] as? String else { throw AgentToolError.unknownTool(name) }
            return encode(try await AgentTools.fetchURL(url: url, context: context))
        case "apply_patch":
            guard let path = args["path"] as? String,
                  let oldText = args["old_text"] as? String,
                  let newText = args["new_text"] as? String else { throw AgentToolError.unknownTool(name) }
            return encode(try AgentTools.applyPatch(path: path, oldText: oldText, newText: newText, context: &context))
        case "scan_broken_links":
            return encode(try AgentTools.scanBrokenLinks(context: context))
        case "run_build":
            guard context.project.hasValidationCommand else {
                throw AgentToolError.validationCommandNotConfigured
            }
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
