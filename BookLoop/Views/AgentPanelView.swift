import Foundation
import SwiftUI

@MainActor
final class AgentPanelModel: ObservableObject {
    @Published var customInstruction = ""
    @Published var isRunning = false
    @Published var isStopping = false
    @Published var runStatus = AgentRunStatus()
    @Published var liveActivity: [AgentActivityItem] = []
    @Published var result: AgentResult?
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var queuedTaskCount = 0
    @Published private(set) var currentTaskTitle = ""
    @Published private(set) var currentTaskDetail = ""
    @Published private(set) var currentTaskType: AgentTaskType?
    @Published var proposeFixesAfterAudit = false

    private let agent = BookAgent()
    private var shouldCancel = false
    private var taskInstructionQueue: [String] = []
    private var activeRunTask: Task<Void, Never>?

    func stop(clearQueue: Bool = true) {
        guard isRunning || isStopping else { return }
        shouldCancel = true
        isStopping = true
        if clearQueue, !taskInstructionQueue.isEmpty {
            taskInstructionQueue.removeAll()
            queuedTaskCount = 0
            infoMessage = "Queued tasks cleared."
        }
        activeRunTask?.cancel()
    }

    func cancel() {
        stop(clearQueue: false)
    }

    func startRun(
        type: AgentTaskType,
        projectStore: BookProjectStore,
        patchStore: PatchStore,
        settingsStore: AppSettingsStore,
        usageStore: AIUsageCostStore
    ) {
        activeRunTask?.cancel()
        activeRunTask = Task { [weak self] in
            await self?.run(
                type: type,
                projectStore: projectStore,
                patchStore: patchStore,
                settingsStore: settingsStore,
                usageStore: usageStore
            )
        }
    }

    func run(
        type: AgentTaskType,
        projectStore: BookProjectStore,
        patchStore: PatchStore,
        settingsStore: AppSettingsStore,
        usageStore: AIUsageCostStore
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
        isStopping = false
        errorMessage = nil
        infoMessage = nil
        liveActivity = []
        result = nil

        let task = AgentTask(
            type: type,
            instruction: instruction,
            proposeFixesAfterAudit: type.isBookAuditTask && proposeFixesAfterAudit
        )
        let taskTitle = type == .custom ? "Custom task" : type.displayName
        currentTaskType = type
        currentTaskTitle = taskTitle
        currentTaskDetail = instruction.nilIfBlank ?? type.taskDescription
        runStatus = AgentRunStatus(
            phase: .preparing,
            taskTitle: taskTitle,
            detail: instruction.nilIfBlank ?? type.taskDescription,
            startedAt: Date(),
            maxIterations: settingsStore.maxAgentIterations
        )

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
                onActivityUpdate: { [weak self] activity in
                    Task { @MainActor in
                        self?.liveActivity = activity
                    }
                },
                onStatusUpdate: { [weak self] status in
                    Task { @MainActor in
                        self?.runStatus = status
                    }
                },
                onUsageRecorded: { usage, model in
                    usageStore.record(usage: usage, model: model, source: "Agent")
                }
            )
            result = agentResult
            liveActivity = agentResult.activity
            projectStore.refresh(book: project.book, currentChapterID: project.currentChapterID)
            patchStore.refresh(book: project.book)
            SystemBadgeNotifier.updatePendingPatchBadge(count: patchStore.pendingAttentionCount)
            if (try? projectStore.ensureGitignore(for: project.book)) == true {
                infoMessage = "Added BookLoop ignores to .gitignore (session logs will not appear in git)."
            }
            SystemBadgeNotifier.notifyAgentTaskCompleted(
                bookName: project.book.displayName,
                summary: agentResult.summary,
                createdPatch: agentResult.patchProposalPath != nil
            )
        } catch is CancellationError {
            errorMessage = isStopping || shouldCancel
                ? "Agent run stopped."
                : "Agent run cancelled."
        } catch let error as OpenAIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isRunning = false
        isStopping = false
        runStatus = AgentRunStatus()
        await drainTaskQueue(
            projectStore: projectStore,
            patchStore: patchStore,
            settingsStore: settingsStore,
            usageStore: usageStore
        )
    }

    func enqueueCustomTask(
        instruction: String,
        projectStore: BookProjectStore,
        patchStore: PatchStore,
        settingsStore: AppSettingsStore,
        usageStore: AIUsageCostStore
    ) async {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if isRunning {
            taskInstructionQueue.append(text)
            queuedTaskCount = taskInstructionQueue.count
            infoMessage = "Task queued (\(queuedTaskCount) waiting)."
            return
        }

        customInstruction = text
        startRun(
            type: .custom,
            projectStore: projectStore,
            patchStore: patchStore,
            settingsStore: settingsStore,
            usageStore: usageStore
        )
    }

    private func drainTaskQueue(
        projectStore: BookProjectStore,
        patchStore: PatchStore,
        settingsStore: AppSettingsStore,
        usageStore: AIUsageCostStore
    ) async {
        guard !shouldCancel else { return }
        while !taskInstructionQueue.isEmpty {
            let next = taskInstructionQueue.removeFirst()
            queuedTaskCount = taskInstructionQueue.count
            customInstruction = next
            await run(
                type: .custom,
                projectStore: projectStore,
                patchStore: patchStore,
                settingsStore: settingsStore,
                usageStore: usageStore
            )
            if shouldCancel { break }
        }
        queuedTaskCount = taskInstructionQueue.count
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
    @EnvironmentObject private var usageStore: AIUsageCostStore
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
        if model.isRunning {
            return model.isStopping
                ? "Stopping the agent after the current network request or tool finishes…"
                : nil
        }
        if projectStore.project == nil { return "Select a book in the sidebar first." }
        if !settingsStore.hasAPIKey { return "Add your OpenAI API key in App Settings (gear icon in the sidebar)." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            if model.isRunning || model.isStopping {
                runningBanner
            }
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        workflowHint
                        bookAuditOptionsSection
                        taskCatalogSection
                        customTaskSection
                        agentSetupSection

                        if let error = model.errorMessage ?? projectStore.lastError {
                            agentMessageCard(error, style: .error)
                        }
                        if let info = model.infoMessage {
                            agentMessageCard(info, style: .info)
                        }

                        if let result = model.result {
                            resultCards(result)
                        } else if !model.isRunning && !model.isStopping && model.liveActivity.isEmpty {
                            emptyStateCard
                        }
                    }
                    .padding()
                }
                .frame(minWidth: 360)

                activityColumn
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
            }
        }
        .onAppear {
            settingsStore.load()
            projectStore.refresh(book: library.selectedBook, currentChapterID: projectStore.project?.currentChapterID)
        }
    }

    private var activityColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Activity")
                        .font(.headline)
                    Spacer()
                    if model.isRunning && !model.isStopping {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !model.currentTaskTitle.isEmpty {
                    activityTaskHeader
                }
            }
            .padding(12)

            Divider()

            if model.isRunning || model.isStopping || !model.liveActivity.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        activitySection
                            .padding(12)
                            .id("agent-activity")
                    }
                    .onChange(of: model.liveActivity.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("agent-activity-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: model.isRunning) { _, isRunning in
                        guard isRunning else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("agent-activity-bottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assistant replies and tool calls will appear here when a task runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Start a preset task or custom instruction on the left.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                Spacer()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var activityTaskHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if let taskType = model.currentTaskType {
                    Image(systemName: taskType.systemImage)
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.isRunning || model.isStopping ? "Executing" : "Last task")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(model.isRunning || model.isStopping ? Color.accentColor : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (model.isRunning || model.isStopping ? Color.accentColor : Color.secondary)
                                    .opacity(0.12),
                                in: Capsule()
                            )

                        Text(model.currentTaskTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }

                    if !model.currentTaskDetail.isEmpty {
                        Text(model.currentTaskDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    if model.isRunning || model.isStopping {
                        Text(model.isStopping ? "Stopping after the current step…" : model.runStatus.headline)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    if model.queuedTaskCount > 0 {
                        Text("\(model.queuedTaskCount) more task\(model.queuedTaskCount == 1 ? "" : "s") queued")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

                if model.queuedTaskCount > 0 {
                    Text("\(model.queuedTaskCount) queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                if model.isRunning || model.isStopping {
                    Button {
                        model.stop()
                    } label: {
                        Label(model.isStopping ? "Stopping…" : "Stop Agent", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.isStopping)
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

    private var runningBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.runStatus.headline.isEmpty ? "Agent running…" : model.runStatus.headline)
                    .font(.subheadline.weight(.semibold))

                if !model.runStatus.taskTitle.isEmpty {
                    Text(model.runStatus.taskTitle)
                        .font(.caption.weight(.medium))
                }

                Text(model.isStopping ? "Finishing the current step, then stopping…" : model.runStatus.subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let startedAt = model.runStatus.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("Elapsed \(AgentPanelView.elapsedString(since: startedAt, now: context.date))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private static func elapsedString(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remainder)
        }
        return "\(seconds)s"
    }

    private var workflowHint: some View {
        Text("Agent stages edits only → review in Patches → apply → commit.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var bookAuditOptionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Propose fixes after consistency / flow audit", isOn: $model.proposeFixesAfterAudit)
                .font(.caption)
            Text("Audits use the table of contents plus multiturn grep and search across the whole book. Reports save under bookloop/audit-reports/; major findings also appear in Reviews.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                                    model.startRun(
                                        type: taskType,
                                        projectStore: projectStore,
                                        patchStore: patchStore,
                                        settingsStore: settingsStore,
                                        usageStore: usageStore
                                    )
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
                    model.startRun(
                        type: .custom,
                        projectStore: projectStore,
                        patchStore: patchStore,
                        settingsStore: settingsStore,
                        usageStore: usageStore
                    )
                }
                .disabled(!canRunCustomTask)

                if model.isRunning || model.isStopping {
                    Text(model.isStopping ? "Stopping…" : "Running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if canRunPresetTasks && !canRunCustomTask {
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
            if model.runStatus.toolsCompleted > 0 {
                HStack {
                    Spacer()
                    Text("\(model.runStatus.toolsCompleted) step\(model.runStatus.toolsCompleted == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if model.liveActivity.isEmpty && (model.isRunning || model.isStopping) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.runStatus.headline.isEmpty ? "Starting…" : model.runStatus.headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            ForEach(model.liveActivity) { item in
                switch item {
                case .assistant(let entry):
                    AgentAssistantReplyCardView(entry: entry)
                case .tool(let entry):
                    AgentToolLogCardView(entry: entry)
                }
            }

            if model.runStatus.phase == .runningTool,
               let toolName = model.runStatus.currentToolName,
               model.isRunning {
                AgentInProgressToolRow(toolName: toolName)
            }

            Color.clear
                .frame(height: 1)
                .id("agent-activity-bottom")
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

            if let auditPath = result.auditReportPath {
                agentCard(title: "Audit report", systemImage: "checklist") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(auditPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("\(result.auditFindingCount) structured finding\(result.auditFindingCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !result.auditReviewItemIDs.isEmpty {
                            Text("Reviews created: \(result.auditReviewItemIDs.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            if let absolute = result.auditReportAbsolutePath {
                                Button("Reveal in Finder") {
                                    FileHelpers.openInFinder(path: absolute)
                                }
                            }
                            Button("Open Reviews Tab") {
                                workspaceMode = .tools
                            }
                        }
                        .font(.caption)
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

// MARK: - Assistant reply card

struct AgentAssistantReplyCardView: View {
    let entry: AgentAssistantReplyEntry
    @State private var isExpanded = false

    private var toolPlanLine: String? {
        guard !entry.plannedToolNames.isEmpty else { return nil }
        let names = entry.plannedToolNames.map { $0.replacingOccurrences(of: "_", with: " ") }
        return "Calling: " + names.joined(separator: ", ")
    }

    private var collapsedPreview: String {
        if !entry.content.isEmpty {
            let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
            if firstLine.count > 160 {
                return String(firstLine.prefix(157)) + "…"
            }
            return firstLine
        }
        return toolPlanLine ?? "Assistant reply"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !entry.content.isEmpty {
                    detailBlock(title: "Reply", text: entry.content)
                }
                if let toolPlanLine {
                    Text(toolPlanLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .font(.body)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Assistant")
                            .font(.caption.weight(.semibold))
                        Text("step \(entry.iteration)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(DateFormatting.display.string(from: entry.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(collapsedPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 3)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Tool log card

struct AgentToolLogCardView: View {
    let entry: AgentToolLogEntry
    @State private var isExpanded = false

    private var toolDisplayName: String {
        entry.toolName.replacingOccurrences(of: "_", with: " ")
    }

    private var collapsedPreview: String {
        let trimmed = entry.resultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No output" }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        if firstLine.count > 140 {
            return String(firstLine.prefix(137)) + "…"
        }
        return firstLine
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !entry.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    detailBlock(title: "Arguments", text: AgentToolLogFormatting.prettyJSON(entry.arguments))
                }
                detailBlock(title: entry.succeeded ? "Result" : "Error", text: entry.resultSummary)
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.succeeded ? .green : .red)
                    .font(.body)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(toolDisplayName)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(DateFormatting.display.string(from: entry.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(collapsedPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private enum AgentToolLogFormatting {
    static func prettyJSON(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return raw
        }
        return pretty
    }
}

struct AgentInProgressToolRow: View {
    let toolName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Running \(toolName.replacingOccurrences(of: "_", with: " "))…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
