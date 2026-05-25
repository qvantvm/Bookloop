import Foundation

final class AgentSessionLogger {
    func writeSession(
        sessionID: UUID,
        project: BookProject,
        task: AgentTask,
        toolLog: [AgentToolLogEntry],
        changedFiles: [String],
        proposalPatch: String,
        patchProposalPath: String?,
        summary: String,
        unresolvedIssues: [String]
    ) throws {
        try project.withSecurityScoped {
            let sessionDir = project.sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            try writeJSON(["task": task.type.rawValue, "instruction": task.instruction], to: sessionDir.appendingPathComponent("request.json"))
            try writeJSON(project.projectMap, to: sessionDir.appendingPathComponent("project_snapshot.json"))
            try writeJSON(toolLog, to: sessionDir.appendingPathComponent("tool_log.json"))
            try writeJSON(changedFiles, to: sessionDir.appendingPathComponent("changed_files.json"))
            if let patchProposalPath {
                try writeJSON(["proposal_patch": patchProposalPath], to: sessionDir.appendingPathComponent("proposal.json"))
            }
            try proposalPatch.write(to: sessionDir.appendingPathComponent("proposal.patch"), atomically: true, encoding: .utf8)
            try proposalPatch.write(to: sessionDir.appendingPathComponent("diff.patch"), atomically: true, encoding: .utf8)
            var summaryText = summary
            if !unresolvedIssues.isEmpty {
                summaryText += "\n\nUnresolved issues:\n" + unresolvedIssues.map { "- \($0)" }.joined(separator: "\n")
            }
            if let patchProposalPath {
                summaryText += "\n\nPatch proposal: \(patchProposalPath)"
            }
            try summaryText.write(to: sessionDir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}

final class BookAgent {
    private let client = OpenAIClient()
    private let logger = AgentSessionLogger()

    func run(
        task: AgentTask,
        project: BookProject,
        searchIndex: SearchIndex,
        apiKey: String,
        appModel: String,
        maxIterations: Int,
        buildTimeoutSeconds: TimeInterval,
        allowReviewEdits: Bool,
        isCancelled: @escaping () -> Bool,
        onToolLogUpdate: (([AgentToolLogEntry]) -> Void)? = nil
    ) async throws -> AgentResult {
        let sessionID = UUID()
        let sessionDir = project.sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        var context = AgentToolContext(
            project: project,
            searchIndex: searchIndex,
            sessionID: sessionID,
            sessionsDirectory: project.sessionsDirectory,
            allowReviewEdits: allowReviewEdits,
            buildTimeoutSeconds: buildTimeoutSeconds,
            stagedChanges: []
        )

        var messages: [OpenAIAssistantMessage] = [
            OpenAIAssistantMessage(role: "system", content: AgentPromptBuilder.systemPrompt, tool_calls: nil, tool_call_id: nil),
            OpenAIAssistantMessage(role: "user", content: AgentPromptBuilder.taskPrompt(task: task, project: project), tool_calls: nil, tool_call_id: nil)
        ]

        var toolLog: [AgentToolLogEntry] = []
        var finalSummary = ""
        let model = project.config.resolvedModel(appDefault: appModel)

        for _ in 0..<maxIterations {
            if isCancelled() { throw CancellationError() }

            let response = try await client.sendChatWithTools(
                apiKey: apiKey,
                model: model,
                messages: messages,
                tools: AgentToolRegistry.definitions
            )

            if let toolCalls = response.tool_calls, !toolCalls.isEmpty {
                messages.append(response)
                for call in toolCalls {
                    if isCancelled() { throw CancellationError() }
                    let entryStart = Date()
                    do {
                        let result = try AgentToolRegistry.execute(
                            name: call.function.name,
                            argumentsJSON: call.function.arguments,
                            context: &context
                        )
                        toolLog.append(AgentToolLogEntry(
                            id: UUID(),
                            toolName: call.function.name,
                            arguments: call.function.arguments,
                            resultSummary: String(result.prefix(300)),
                            succeeded: true,
                            timestamp: entryStart
                        ))
                        onToolLogUpdate?(toolLog)
                        messages.append(OpenAIAssistantMessage(
                            role: "tool",
                            content: result,
                            tool_calls: nil,
                            tool_call_id: call.id
                        ))
                    } catch {
                        toolLog.append(AgentToolLogEntry(
                            id: UUID(),
                            toolName: call.function.name,
                            arguments: call.function.arguments,
                            resultSummary: error.localizedDescription,
                            succeeded: false,
                            timestamp: entryStart
                        ))
                        onToolLogUpdate?(toolLog)
                        messages.append(OpenAIAssistantMessage(
                            role: "tool",
                            content: "Error: \(error.localizedDescription)",
                            tool_calls: nil,
                            tool_call_id: call.id
                        ))
                    }
                }
                continue
            }

            finalSummary = response.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.type == .applyReviewFeedback,
               context.stagedChanges.isEmpty,
               AgentTools.hasActionableOpenReviews(for: project),
               messages.last?.role != "user" || !(messages.last?.content?.contains("must stage at least one apply_patch") ?? false) {
                messages.append(response)
                messages.append(OpenAIAssistantMessage(
                    role: "user",
                    content: """
                    You reported no actionable feedback, but open reviews include Conversation guidance and has_actionable_guidance=true.
                    Re-read read_review_items, read each source_file chapter, and stage at least one apply_patch that expands stub sections or addresses the review.
                    Do not finish until you have staged changes.
                    """,
                    tool_calls: nil,
                    tool_call_id: nil
                ))
                continue
            }

            let expectedPatches = AgentTools.expectedPatchCount(for: project)
            if task.type == .applyReviewFeedback,
               AgentTools.hasActionableOpenReviews(for: project),
               context.stagedChanges.count < expectedPatches,
               messages.last?.role != "user" || !(messages.last?.content?.contains("stage more apply_patch") ?? false) {
                messages.append(response)
                messages.append(OpenAIAssistantMessage(
                    role: "user",
                    content: """
                    You staged \(context.stagedChanges.count) apply_patch change(s), but the open review likely covers about \(expectedPatches) section(s).
                    Re-read actionable_guidance and stage more apply_patch calls for remaining stub sections before finishing.
                    """,
                    tool_calls: nil,
                    tool_call_id: nil
                ))
                continue
            }

            break
        }

        if finalSummary.isEmpty {
            finalSummary = "Agent stopped after reaching the iteration limit."
        }

        var exportResult: AgentPatchExporter.ExportResult?
        if !context.stagedChanges.isEmpty {
            exportResult = try AgentPatchExporter.export(
                changes: context.stagedChanges,
                project: project,
                task: task,
                sessionID: sessionID,
                summary: finalSummary
            )
            if finalSummary.contains("Patch proposal:") == false, let path = exportResult?.relativePatchPath {
                finalSummary += "\n\nPatch proposal written to \(path). Review and apply it from Tools → Patches."
            }
        }

        let proposalPatch = exportResult?.rawPatch ?? ""
        try logger.writeSession(
            sessionID: sessionID,
            project: project,
            task: task,
            toolLog: toolLog,
            changedFiles: context.changedFiles,
            proposalPatch: proposalPatch,
            patchProposalPath: exportResult?.relativePatchPath,
            summary: finalSummary,
            unresolvedIssues: []
        )

        return AgentResult(
            sessionID: sessionID,
            summary: finalSummary,
            changedFiles: context.changedFiles,
            patchProposalPath: exportResult?.relativePatchPath,
            patchProposalAbsolutePath: exportResult?.absolutePatchPath,
            proposalPatch: proposalPatch.nilIfBlank,
            buildResult: nil,
            toolLog: toolLog,
            unresolvedIssues: [],
            sessionDirectory: sessionDir
        )
    }

    func deleteProposal(sessionID: UUID, project: BookProject, absolutePatchPath: String?) throws {
        guard let absolutePatchPath else { return }
        try AgentPatchExporter.deleteProposal(at: absolutePatchPath, project: project, sessionID: sessionID)
    }
}
