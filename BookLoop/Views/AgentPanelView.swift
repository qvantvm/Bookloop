import Foundation
import SwiftUI

@MainActor
final class AgentPanelModel: ObservableObject {
    @Published var customInstruction = ""
    @Published var isRunning = false
    @Published var liveToolLog: [AgentToolLogEntry] = []
    @Published var result: AgentResult?
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let agent = BookAgent()
    private var shouldCancel = false

    func cancel() {
        shouldCancel = true
    }

    func run(
        type: AgentTaskType,
        projectStore: BookProjectStore,
        patchStore: PatchStore,
        settingsStore: AppSettingsStore
    ) async {
        guard let project = projectStore.project else {
            errorMessage = "Select a book first."
            return
        }
        guard settingsStore.hasAPIKey else {
            errorMessage = OpenAIError.missingAPIKey.errorDescription
            return
        }

        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .custom && instruction.isEmpty {
            errorMessage = "Enter a custom task instruction first."
            return
        }

        shouldCancel = false
        isRunning = true
        errorMessage = nil
        liveToolLog = []
        result = nil

        let task = AgentTask(type: type, instruction: instruction)

        do {
            let agentResult = try await agent.run(
                task: task,
                project: project,
                searchIndex: projectStore.searchIndex,
                apiKey: settingsStore.apiKey,
                appModel: settingsStore.openAIModel,
                maxIterations: settingsStore.maxAgentIterations,
                buildTimeoutSeconds: TimeInterval(settingsStore.buildTimeoutSeconds),
                fetchURLMaxBytes: settingsStore.fetchURLMaxBytes,
                allowReviewEdits: settingsStore.allowAgentReviewEdits,
                isCancelled: { self.shouldCancel },
                onToolLogUpdate: { [weak self] log in
                    self?.liveToolLog = log
                }
            )
            result = agentResult
            liveToolLog = agentResult.toolLog
            projectStore.refresh(book: project.book, currentChapterID: project.currentChapterID)
            patchStore.refresh(book: project.book)
            if (try? projectStore.ensureGitignore(for: project.book)) == true {
                infoMessage = "Added BookLoop ignores to .gitignore (session logs will not appear in git)."
            }
        } catch is CancellationError {
            errorMessage = "Agent run cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }

        isRunning = false
    }

    func deleteProposal(projectStore: BookProjectStore, patchStore: PatchStore) {
        guard let project = projectStore.project, let result else { return }
        do {
            try agent.deleteProposal(
                sessionID: result.sessionID,
                project: project,
                absolutePatchPath: result.patchProposalAbsolutePath
            )
            errorMessage = nil
            self.result = nil
            patchStore.refresh(book: project.book)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func initializeConfig(projectStore: BookProjectStore) {
        guard let book = projectStore.project?.book else { return }
        do {
            try projectStore.initializeConfig(for: book)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func repairWriteGlobs(projectStore: BookProjectStore) {
        guard let book = projectStore.project?.book else { return }
        do {
            try projectStore.repairWriteGlobs(for: book)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ensureGitignore(projectStore: BookProjectStore) {
        guard let book = projectStore.project?.book else { return }
        do {
            let added = try projectStore.ensureGitignore(for: book)
            errorMessage = nil
            infoMessage = added
                ? "Updated .gitignore with BookLoop ignores (.bookloop/sessions/, patch archive, etc.)."
                : ".gitignore already includes BookLoop ignores."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AgentPanelView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var patchStore: PatchStore
    @ObservedObject var projectStore: BookProjectStore
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var model: AgentPanelModel
    @Binding var workspaceMode: WorkspaceMode
    @Binding var showingAppSettings: Bool

    @State private var agentSetupExpanded = false
    @State private var proposalPreviewExpanded = false

    private var canRunPresetTasks: Bool {
        !model.isRunning && projectStore.project != nil && settingsStore.hasAPIKey
    }

    private var canRunCustomTask: Bool {
        canRunPresetTasks && !model.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var agentDisabledReason: String? {
        if model.isRunning { return "Agent is running. Click Cancel to stop the current run." }
        if projectStore.project == nil { return "Select a book in the sidebar first." }
        if !settingsStore.hasAPIKey { return "Add your OpenAI API key in App Settings (gear icon in the sidebar)." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    workflowHint
                    taskCatalogSection
                    customTaskSection
                    agentSetupSection

                    if let error = model.errorMessage ?? projectStore.lastError {
                        agentMessageCard(error, style: .error)
                    }
                    if let info = model.infoMessage {
                        agentMessageCard(info, style: .info)
                    }

                    if !model.liveToolLog.isEmpty {
                        activitySection
                    }
                    if let result = model.result {
                        resultCards(result)
                    } else if !model.isRunning && model.liveToolLog.isEmpty {
                        emptyStateCard
                    }
                }
                .padding()
            }
        }
        .onAppear {
            settingsStore.load()
            projectStore.refresh(book: library.selectedBook, currentChapterID: projectStore.project?.currentChapterID)
        }
    }

    // MARK: - Status header

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let project = projectStore.project {
                        Text(project.book.displayName)
                            .font(.headline)
                        Text(project.projectMap.compactSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No book selected")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Model: \(settingsStore.openAIModel) · Max iterations: \(settingsStore.maxAgentIterations)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if model.isRunning {
                    Button("Cancel", role: .destructive) { model.cancel() }
                }
            }

            if let reason = agentDisabledReason {
                HStack(spacing: 8) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !settingsStore.hasAPIKey {
                        Button("Open App Settings") { showingAppSettings = true }
                            .font(.caption)
                    }
                }
            }
        }
        .padding(10)
    }

    private var workflowHint: some View {
        Text("Agent stages edits only → review in Patches → apply → commit.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Task catalog

    private var taskCatalogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AgentTaskCategory.allCases, id: \.self) { category in
                let tasks = AgentTaskType.tasks(in: category)
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.sectionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(tasks) { taskType in
                            AgentTaskCardView(
                                taskType: taskType,
                                isRunning: model.isRunning,
                                canRun: canRunPresetTasks,
                                onRun: {
                                    Task {
                                        await model.run(
                                            type: taskType,
                                            projectStore: projectStore,
                                            patchStore: patchStore,
                                            settingsStore: settingsStore
                                        )
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Custom task

    private var customTaskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom task")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(
                "Describe what the agent should do, e.g. “Fix typos in chapter 3” or “Add a glossary entry for LLM”",
                text: $model.customInstruction,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)

            HStack {
                Button("Run Custom Task") {
                    Task {
                        await model.run(
                            type: .custom,
                            projectStore: projectStore,
                            patchStore: patchStore,
                            settingsStore: settingsStore
                        )
                    }
                }
                .disabled(!canRunCustomTask)

                if canRunPresetTasks && !canRunCustomTask {
                    Text("Enter an instruction above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Agent setup

    private var agentSetupSection: some View {
        DisclosureGroup("Agent setup", isExpanded: $agentSetupExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if projectStore.configMissing {
                    missingConfigBanner
                } else if let config = projectStore.project?.config {
                    writePermissionsBanner(config)
                } else {
                    Text("Select a book to view agent configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
        .font(.subheadline.weight(.semibold))
    }

    // MARK: - Empty state

    private var emptyStateCard: some View {
        agentCard(title: "Get started", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 8) {
                stepRow(number: 1, text: "Pick a preset task or enter a custom instruction.")
                stepRow(number: 2, text: "The agent inspects your book and writes a patch proposal.")
                stepRow(number: 3, text: "Open Tools → Patches to review, apply, and commit changes.")
            }
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Banners

    private var missingConfigBanner: some View {
        HStack {
            Text("Agent config missing (.bookloop/config.json)")
                .font(.caption)
            Spacer()
            Button("Initialize Config") { model.initializeConfig(projectStore: projectStore) }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func writePermissionsBanner(_ config: BookProjectConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent can stage edits for paths matching:")
                .font(.caption)
            Text(config.allowedWriteGlobs.joined(separator: ", "))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Repair Write Permissions") { model.repairWriteGlobs(projectStore: projectStore) }
                .font(.caption)
            Button("Ensure Gitignore") { model.ensureGitignore(projectStore: projectStore) }
                .font(.caption)
            Text("Do not commit `.bookloop/sessions/` — agent debug logs. Commit only `docs/` after Patches → Commit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ForEach(model.liveToolLog) { entry in
                AgentToolLogCardView(entry: entry)
            }
        }
    }

    // MARK: - Results

    private func resultCards(_ result: AgentResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            agentCard(title: "Summary", systemImage: "text.alignleft") {
                HTMLStringView(html: MarkdownHTMLRenderer().renderDocument(markdown: result.summary, title: "Agent Summary"))
                    .frame(minHeight: 60, maxHeight: 200)
            }

            if !result.changedFiles.isEmpty {
                agentCard(title: "Staged files", systemImage: "doc.on.doc") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.changedFiles, id: \.self) { path in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            if let buildResult = result.buildResult {
                agentCard(
                    title: "Build result",
                    systemImage: buildResult.succeeded ? "checkmark.circle" : "xmark.circle",
                    iconColor: buildResult.succeeded ? .green : .red
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(buildResult.command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(buildResult.succeeded ? "Succeeded" : "Failed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(buildResult.succeeded ? .green : .red)
                        }
                        if buildResult.timedOut {
                            Text("Build timed out.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Exit code: \(buildResult.exitCode)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !buildResult.combinedOutput.isEmpty {
                            ScrollView {
                                Text(buildResult.combinedOutput)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                }
            }

            if let patchPath = result.patchProposalPath {
                agentCard(title: "Patch proposal", systemImage: "doc.badge.plus") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(patchPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        HStack {
                            Button("Open Patches Tab") {
                                workspaceMode = .tool(.patches)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Reveal in Finder") {
                                if let absolute = result.patchProposalAbsolutePath {
                                    FileHelpers.openInFinder(path: absolute)
                                }
                            }
                            Button("Copy Path") {
                                FileHelpers.copyToPasteboard(patchPath)
                            }
                        }
                    }
                }
            }

            if let proposalPatch = result.proposalPatch {
                DisclosureGroup("Proposal preview", isExpanded: $proposalPreviewExpanded) {
                    ScrollView {
                        Text(proposalPatch)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(.top, 6)
                }
                .font(.subheadline.weight(.semibold))
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                Button("Copy Summary") {
                    FileHelpers.copyToPasteboard(result.summary)
                }
                Button("Open Session Folder") {
                    FileHelpers.openInFinder(path: result.sessionDirectory.path)
                }
                if result.patchProposalPath != nil {
                    Button("Delete Proposal Patch", role: .destructive) {
                        model.deleteProposal(projectStore: projectStore, patchStore: patchStore)
                    }
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Shared card chrome

    private enum AgentMessageStyle {
        case error, info
    }

    private func agentMessageCard(_ message: String, style: AgentMessageStyle) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(style == .error ? .red : .secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (style == .error ? Color.red : Color.secondary).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    private func agentCard<Content: View>(
        title: String,
        systemImage: String,
        iconColor: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Task card

struct AgentTaskCardView: View {
    let taskType: AgentTaskType
    let isRunning: Bool
    let canRun: Bool
    let onRun: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: taskType.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(taskType.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(taskType.taskDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Button("Run") {
                onRun()
            }
            .disabled(!canRun || isRunning)
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Tool log card

struct AgentToolLogCardView: View {
    let entry: AgentToolLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.succeeded ? .green : .red)
                .font(.body)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.toolName)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(DateFormatting.display.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.resultSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
