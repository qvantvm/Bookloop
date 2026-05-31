import Foundation

struct FigurePlacementContext {
    var project: BookProject
    var searchIndex: SearchIndex
    var submittedPlacement: FigureMarkdownPlacement?
    var finished = false
}

struct FigurePlacementResult: Equatable {
    var placement: FigureMarkdownPlacement
    var toolLog: [AgentToolLogEntry]
    var summary: String?
}

enum FigurePlacementError: LocalizedError {
    case missingAPIKey
    case missingProject
    case missingAsset
    case missingSuggestion
    case noPlacementSubmitted
    case plannerFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an OpenAI API key in App Settings to use AI placement."
        case .missingProject: return "Book project scan is not ready. Open the book preview or Agent tab first, then try again."
        case .missingAsset: return "Load or preview a figure asset before asking AI to place it."
        case .missingSuggestion: return "Enter a placement suggestion describing where the figure should go."
        case .noPlacementSubmitted: return "AI did not submit a figure placement. Try refining your suggestion."
        case .plannerFailed(let detail): return detail
        }
    }
}

enum FigureBookOutlineBuilder {
    static func build(project: BookProject, chapterNav: [ChapterNavItem] = []) -> String {
        var lines: [String] = ["## Chapter files"]
        let chapters = project.projectMap.files
            .filter { $0.kind == .chapter }
            .sorted { $0.relativePath < $1.relativePath }
        if chapters.isEmpty {
            lines.append("- (no chapter markdown files found under docs/)")
        } else {
            for file in chapters {
                let headings = file.headings.prefix(8).joined(separator: " | ")
                if headings.isEmpty {
                    lines.append("- \(file.relativePath): \(file.title)")
                } else {
                    lines.append("- \(file.relativePath): \(file.title) — \(headings)")
                }
            }
        }
        if !chapterNav.isEmpty {
            lines.append("")
            lines.append("## Navigation")
            appendNav(chapterNav, indent: 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendNav(_ items: [ChapterNavItem], indent: Int, into lines: inout [String]) {
        let prefix = String(repeating: "  ", count: indent)
        for item in items {
            if item.isNavigable {
                lines.append("\(prefix)- \(item.title) (\(item.href))")
            } else if !item.title.isEmpty {
                lines.append("\(prefix)- \(item.title)")
            }
            if !item.children.isEmpty {
                appendNav(item.children, indent: indent + 1, into: &lines)
            }
        }
    }
}

enum FigurePlacementValidator {
    static func validate(
        markdownPath: String,
        anchorText: String,
        insertMode: FigureInsertMode,
        project: BookProject
    ) throws {
        let normalizedPath = markdownPath.replacingOccurrences(of: "\\", with: "/")
        guard normalizedPath.hasSuffix(".md") else {
            throw FigurePlacementError.plannerFailed("markdown_path must be a .md file under the book project.")
        }
        let content = try project.withSecurityScoped {
            try project.pathGuard.readText(at: normalizedPath)
        }
        let occurrences = content.components(separatedBy: anchorText).count - 1
        guard occurrences == 1 else {
            throw FigurePlacementError.plannerFailed(
                "anchor_text must occur exactly once in \(normalizedPath) (found \(occurrences))."
            )
        }
        guard FigureInsertMode.allCases.contains(insertMode) else {
            throw FigurePlacementError.plannerFailed("insert_mode must be after, before, or replace.")
        }
    }
}

final class FigurePlacementPlanner {
    static let maxIterations = 10

    private let client = OpenAIClient()

    func plan(
        book: BookConfig,
        project: BookProject,
        searchIndex: SearchIndex,
        chapterNav: [ChapterNavItem],
        draft: FigureProposalDraft,
        imageData: Data,
        imageExtension: String,
        apiKey: String,
        model: String
    ) async throws -> FigurePlacementResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FigurePlacementError.missingAPIKey
        }
        guard !imageData.isEmpty else { throw FigurePlacementError.missingAsset }
        guard draft.placementSuggestion?.nilIfBlank != nil else { throw FigurePlacementError.missingSuggestion }

        var context = FigurePlacementContext(project: project, searchIndex: searchIndex)
        let outline = FigureBookOutlineBuilder.build(project: project, chapterNav: chapterNav)
        let mime = mimeType(for: imageExtension)
        let dataURL = "data:\(mime);base64,\(imageData.base64EncodedString())"
        let suggestion = draft.placementSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var messages: [OpenAIAssistantMessage] = [
            OpenAIAssistantMessage(
                role: "system",
                content: systemPrompt,
                tool_calls: nil,
                tool_call_id: nil
            ),
            OpenAIAssistantMessage(
                role: "user",
                contentParts: [
                    .text(userPrompt(draft: draft, outline: outline, suggestion: suggestion)),
                    .imageDataURL(dataURL)
                ],
                tool_calls: nil,
                tool_call_id: nil
            )
        ]

        var toolLog: [AgentToolLogEntry] = []
        var finalSummary: String?

        for iteration in 1...Self.maxIterations {
            let completion = try await client.sendChatWithTools(
                apiKey: apiKey,
                model: model,
                messages: messages,
                tools: FigurePlacementToolRegistry.definitions
            )
            let response = completion.message

            if let toolCalls = response.tool_calls, !toolCalls.isEmpty {
                messages.append(response)
                for call in toolCalls {
                    let entryStart = Date()
                    do {
                        let result = try await FigurePlacementToolRegistry.execute(
                            name: call.function.name,
                            argumentsJSON: call.function.arguments,
                            context: &context
                        )
                        toolLog.append(AgentToolLogEntry(
                            id: UUID(),
                            toolName: call.function.name,
                            arguments: call.function.arguments,
                            resultSummary: result,
                            succeeded: true,
                            timestamp: entryStart
                        ))
                        messages.append(OpenAIAssistantMessage(
                            role: "tool",
                            content: result,
                            tool_calls: nil,
                            tool_call_id: call.id
                        ))
                        if context.finished { break }
                    } catch {
                        toolLog.append(AgentToolLogEntry(
                            id: UUID(),
                            toolName: call.function.name,
                            arguments: call.function.arguments,
                            resultSummary: error.localizedDescription,
                            succeeded: false,
                            timestamp: entryStart
                        ))
                        messages.append(OpenAIAssistantMessage(
                            role: "tool",
                            content: "Error: \(error.localizedDescription)",
                            tool_calls: nil,
                            tool_call_id: call.id
                        ))
                    }
                }
                if context.finished { break }
                continue
            }

            finalSummary = response.content?.textValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if context.finished { break }

            if iteration < Self.maxIterations {
                messages.append(response)
                messages.append(OpenAIAssistantMessage(
                    role: "user",
                    content: "Call submit_figure_placement with your chosen markdown_path, anchor_text, insert_mode, caption, and alt text. Do not finish without submitting placement.",
                    tool_calls: nil,
                    tool_call_id: nil
                ))
            }
        }

        guard let placement = context.submittedPlacement else {
            throw FigurePlacementError.noPlacementSubmitted
        }

        return FigurePlacementResult(placement: placement, toolLog: toolLog, summary: finalSummary)
    }

    private var systemPrompt: String {
        """
        You are BookLoop Figure Placement Agent. Your job is to choose the best markdown location for a figure in a technical book.
        Rules:
        - Inspect the book using list_files, read_file, grep, and search_text only.
        - Do not modify files directly.
        - Pick a markdown_path under docs/ and an anchor_text that occurs exactly once in that file.
        - Prefer inserting after a relevant paragraph or section heading using insert_mode "after".
        - Use insert_mode "before" only when the figure should introduce a section.
        - Use insert_mode "replace" only to replace placeholder text such as TODO figure or [diagram here].
        - anchor_text must be copied exactly from the file (including punctuation and whitespace).
        - When done, call submit_figure_placement with markdown_path, anchor_text, insert_mode, suggested_caption, suggested_alt_text, section_heading, and rationale.
        """
    }

    private func userPrompt(draft: FigureProposalDraft, outline: String, suggestion: String) -> String {
        var lines = [
            "Figure ID: \(draft.id)",
            "Placement suggestion from author: \(suggestion)"
        ]
        if let chapterID = draft.chapterID?.nilIfBlank {
            lines.append("Preferred chapter hint: \(chapterID)")
        }
        if let path = draft.targetMarkdownPath?.nilIfBlank {
            lines.append("Preferred markdown path hint: \(path)")
        }
        lines.append("")
        lines.append(outline)
        lines.append("")
        lines.append("Use grep and read_file to inspect candidate chapters, then submit the best placement.")
        return lines.joined(separator: "\n")
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}

enum FigurePlacementToolRegistry {
    static var definitions: [OpenAIToolDefinition] {
        [
            listFilesTool,
            readFileTool,
            searchTextTool,
            grepTool,
            submitPlacementTool
        ]
    }

    static func execute(name: String, argumentsJSON: String, context: inout FigurePlacementContext) async throws -> String {
        let args = parseJSON(argumentsJSON)
        let agentContext = agentToolContext(from: context)
        var mutableAgentContext = agentContext

        switch name {
        case "list_files":
            let glob = args["glob"] as? String
            let files = try AgentTools.listFiles(glob: glob, context: mutableAgentContext)
            return encode(files)
        case "read_file":
            guard let path = args["path"] as? String else { throw AgentToolError.unknownTool(name) }
            return try AgentTools.readFile(path: path, context: mutableAgentContext)
        case "search_text":
            let query = args["query"] as? String ?? ""
            let glob = args["glob"] as? String
            let limit = args["limit"] as? Int ?? 10
            return encode(AgentTools.searchText(query: query, glob: glob, limit: limit, context: mutableAgentContext))
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
                context: mutableAgentContext
            ))
        case "submit_figure_placement":
            return try submitPlacement(arguments: args, context: &context)
        default:
            throw AgentToolError.unknownTool(name)
        }
    }

    private static func submitPlacement(arguments: [String: Any], context: inout FigurePlacementContext) throws -> String {
        guard let markdownPath = arguments["markdown_path"] as? String,
              let anchorText = arguments["anchor_text"] as? String,
              let insertModeRaw = arguments["insert_mode"] as? String,
              let insertMode = FigureInsertMode(rawValue: insertModeRaw) else {
            throw FigurePlacementError.plannerFailed("submit_figure_placement requires markdown_path, anchor_text, and insert_mode.")
        }

        let normalizedPath = markdownPath.replacingOccurrences(of: "\\", with: "/")
        try FigurePlacementValidator.validate(
            markdownPath: normalizedPath,
            anchorText: anchorText,
            insertMode: insertMode,
            project: context.project
        )

        let placement = FigureMarkdownPlacement(
            markdownPath: normalizedPath,
            anchorText: anchorText,
            insertMode: insertMode,
            sectionHeading: (arguments["section_heading"] as? String)?.nilIfBlank,
            rationale: (arguments["rationale"] as? String)?.nilIfBlank,
            suggestedCaption: (arguments["suggested_caption"] as? String)?.nilIfBlank,
            suggestedAltText: (arguments["suggested_alt_text"] as? String)?.nilIfBlank
        )
        context.submittedPlacement = placement
        context.finished = true
        return encode([
            "status": "accepted",
            "markdown_path": placement.markdownPath,
            "insert_mode": placement.insertMode.rawValue,
            "section_heading": placement.sectionHeading ?? "",
            "rationale": placement.rationale ?? ""
        ] as [String: String])
    }

    private static func agentToolContext(from context: FigurePlacementContext) -> AgentToolContext {
        AgentToolContext(
            project: context.project,
            searchIndex: context.searchIndex,
            sessionID: UUID(),
            sessionsDirectory: context.project.sessionsDirectory,
            allowReviewEdits: false,
            buildTimeoutSeconds: 45,
            fetchURLMaxBytes: AgentURLFetcher.defaultMaxBytes,
            stagedChanges: []
        )
    }

    private static var listFilesTool: OpenAIToolDefinition {
        tool(name: "list_files", description: "List project-relative file paths matching a glob.", properties: [
            "glob": prop("string", "Glob pattern such as docs/**/*.md")
        ], required: [])
    }

    private static var readFileTool: OpenAIToolDefinition {
        tool(name: "read_file", description: "Read a UTF-8 text file from the project.", properties: [
            "path": prop("string", "Project-relative file path")
        ], required: ["path"])
    }

    private static var searchTextTool: OpenAIToolDefinition {
        tool(name: "search_text", description: "Quick indexed substring search across chapters and config files.", properties: [
            "query": prop("string", "Search query"),
            "glob": prop("string", "Optional glob filter"),
            "limit": prop("integer", "Max results, default 10")
        ], required: ["query"])
    }

    private static var grepTool: OpenAIToolDefinition {
        tool(name: "grep", description: "Search file contents with a regex or fixed string.", properties: [
            "pattern": prop("string", "Regex pattern, or literal string when fixed_strings is true"),
            "glob": prop("string", "Optional glob filter such as docs/**/*.md"),
            "path": prop("string", "Optional project-relative file or directory prefix"),
            "ignore_case": prop("boolean", "Case-insensitive match, default false"),
            "fixed_strings": prop("boolean", "Treat pattern as literal text, default false"),
            "limit": prop("integer", "Max matches to return, default 50")
        ], required: ["pattern"])
    }

    private static var submitPlacementTool: OpenAIToolDefinition {
        tool(
            name: "submit_figure_placement",
            description: "Submit the final figure placement after inspecting chapters. Does not modify files.",
            properties: [
                "markdown_path": prop("string", "Project-relative markdown file path"),
                "anchor_text": prop("string", "Exact unique substring from the file to anchor insertion"),
                "insert_mode": prop("string", "after, before, or replace"),
                "suggested_caption": prop("string", "Suggested figure caption"),
                "suggested_alt_text": prop("string", "Suggested alt text for accessibility"),
                "section_heading": prop("string", "Nearest section heading for display"),
                "rationale": prop("string", "Brief explanation of why this location fits")
            ],
            required: ["markdown_path", "anchor_text", "insert_mode"]
        )
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
