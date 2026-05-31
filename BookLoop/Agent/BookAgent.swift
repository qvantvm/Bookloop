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
        fetchURLMaxBytes: Int,
        allowReviewEdits: Bool,
        isCancelled: @escaping () -> Bool,
        onActivityUpdate: (([AgentActivityItem]) -> Void)? = nil,
        onStatusUpdate: ((AgentRunStatus) -> Void)? = nil,
        onUsageRecorded: ((OpenAIUsage, String) -> Void)? = nil
    ) async throws -> AgentResult {
        func report(_ status: AgentRunStatus) {
            onStatusUpdate?(status)
        }

        func checkCancelled() throws {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
        }

        let sessionID = UUID()
        let sessionDir = project.sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        var context = AgentToolContext(
            project: project,
            searchIndex: searchIndex,
            sessionID: sessionID,
            sessionsDirectory: project.sessionsDirectory,
            allowReviewEdits: allowReviewEdits,
            buildTimeoutSeconds: buildTimeoutSeconds,
            fetchURLMaxBytes: fetchURLMaxBytes,
            stagedChanges: []
        )

        var messages: [OpenAIAssistantMessage] = [
            OpenAIAssistantMessage(role: "system", content: AgentPromptBuilder.systemPrompt(for: project.book), tool_calls: nil, tool_call_id: nil),
            OpenAIAssistantMessage(role: "user", content: AgentPromptBuilder.taskPrompt(task: task, project: project), tool_calls: nil, tool_call_id: nil)
        ]

        var toolLog: [AgentToolLogEntry] = []
        var activity: [AgentActivityItem] = []

        func appendAssistantReply(from response: OpenAIAssistantMessage, iteration: Int) {
            let content = response.content?.textValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let plannedToolNames = response.tool_calls?.map(\.function.name) ?? []
            guard !content.isEmpty || !plannedToolNames.isEmpty else { return }
            let entry = AgentAssistantReplyEntry(
                id: UUID(),
                content: content,
                iteration: iteration,
                timestamp: Date(),
                plannedToolNames: plannedToolNames
            )
            activity.append(.assistant(entry))
            onActivityUpdate?(activity)
        }

        var finalSummary = ""
        let model = project.config.resolvedModel(appDefault: appModel)
        let startedAt = Date()

        report(AgentRunStatus(
            phase: .preparing,
            taskTitle: task.type.displayName,
            detail: task.instruction.nilIfBlank ?? task.type.taskDescription,
            startedAt: startedAt,
            maxIterations: maxIterations
        ))

        for iteration in 1...maxIterations {
            try checkCancelled()

            report(AgentRunStatus(
                phase: .waitingForModel,
                taskTitle: task.type.displayName,
                startedAt: startedAt,
                iteration: iteration,
                maxIterations: maxIterations,
                toolsCompleted: toolLog.count
            ))

            let completion = try await client.sendChatWithTools(
                apiKey: apiKey,
                model: model,
                messages: messages,
                tools: AgentToolRegistry.definitions(for: project)
            )
            let response = completion.message
            if let usage = completion.usage {
                onUsageRecorded?(usage, model)
            }

            if let toolCalls = response.tool_calls, !toolCalls.isEmpty {
                appendAssistantReply(from: response, iteration: iteration)
                messages.append(response)
                for call in toolCalls {
                    try checkCancelled()
                    let entryStart = Date()
                    report(AgentRunStatus(
                        phase: .runningTool,
                        taskTitle: task.type.displayName,
                        startedAt: startedAt,
                        iteration: iteration,
                        maxIterations: maxIterations,
                        toolsCompleted: toolLog.count,
                        currentToolName: call.function.name
                    ))
                    do {
                        let result = try await AgentToolRegistry.execute(
                            name: call.function.name,
                            argumentsJSON: call.function.arguments,
                            context: &context
                        )
                        let entry = AgentToolLogEntry(
                            id: UUID(),
                            toolName: call.function.name,
                            arguments: call.function.arguments,
                            resultSummary: result,
                            succeeded: true,
                            timestamp: entryStart
                        )
                        toolLog.append(entry)
                        activity.append(.tool(entry))
                        onActivityUpdate?(activity)
                        messages.append(OpenAIAssistantMessage(
                            role: "tool",
                            content: result,
                            tool_calls: nil,
                            tool_call_id: call.id
                        ))
                    } catch {
                        let entry = AgentToolLogEntry(
                            id: UUID(),
                            toolName: call.function.name,
                            arguments: call.function.arguments,
                            resultSummary: error.localizedDescription,
                            succeeded: false,
                            timestamp: entryStart
                        )
                        toolLog.append(entry)
                        activity.append(.tool(entry))
                        onActivityUpdate?(activity)
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

            finalSummary = response.content?.textValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            appendAssistantReply(from: response, iteration: iteration)

            if task.type.isBookAuditTask,
               context.auditFindings.isEmpty,
               toolLog.filter({ $0.toolName == "grep" || $0.toolName == "search_text" }).count < 2,
               messages.last?.role != "user" || !(messages.last?.content?.contains("use grep and search_text") ?? false) {
                messages.append(response)
                messages.append(OpenAIAssistantMessage(
                    role: "user",
                    content: """
                    This is a large-book audit. Before finishing, use get_table_of_contents if you have not already, then run multiple grep or search_text calls across docs/**/*.md to investigate terminology and cross-chapter references.
                    Record each real issue with record_audit_finding, or state clearly in your summary that the book passed with no issues found.
                    """,
                    tool_calls: nil,
                    tool_call_id: nil
                ))
                continue
            }

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
            report(AgentRunStatus(
                phase: .exportingPatch,
                taskTitle: task.type.displayName,
                startedAt: startedAt,
                iteration: maxIterations,
                maxIterations: maxIterations,
                toolsCompleted: toolLog.count
            ))
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
        report(AgentRunStatus(
            phase: .savingSession,
            taskTitle: task.type.displayName,
            startedAt: startedAt,
            iteration: maxIterations,
            maxIterations: maxIterations,
            toolsCompleted: toolLog.count
        ))
        var auditReport: BookAuditReport?
        if let kind = task.type.auditKind {
            auditReport = try? BookAuditReportWriter.write(
                kind: kind,
                task: task,
                sessionID: sessionID,
                summary: finalSummary,
                findings: context.auditFindings,
                project: project
            )
            if let auditReport {
                finalSummary += "\n\nAudit report: \(auditReport.relativePath)"
                if !auditReport.reviewItemIDs.isEmpty {
                    finalSummary += "\nReview items created: \(auditReport.reviewItemIDs.joined(separator: ", "))"
                }
            }
        }

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
            activity: activity,
            unresolvedIssues: [],
            sessionDirectory: sessionDir,
            auditReportPath: auditReport?.relativePath,
            auditReportAbsolutePath: auditReport?.absolutePath,
            auditFindingCount: context.auditFindings.count,
            auditReviewItemIDs: auditReport?.reviewItemIDs ?? []
        )
    }

    func deleteProposal(sessionID: UUID, project: BookProject, absolutePatchPath: String?) throws {
        guard let absolutePatchPath else { return }
        try AgentPatchExporter.deleteProposal(at: absolutePatchPath, project: project, sessionID: sessionID)
    }
}
