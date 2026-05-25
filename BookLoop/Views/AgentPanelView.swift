import Foundation
import SwiftUI

@MainActor
final class AgentPanelModel: ObservableObject {
    @Published var customInstruction = ""
    @Published var isRunning = false
    @Published var liveToolLog: [AgentToolLogEntry] = []
    @Published var result: AgentResult?
    @Published var errorMessage: String?

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

        shouldCancel = false
        isRunning = true
        errorMessage = nil
        liveToolLog = []
        result = nil

        let task = AgentTask(type: type, instruction: customInstruction.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let agentResult = try await agent.run(
                task: task,
                project: project,
                searchIndex: projectStore.searchIndex,
                apiKey: settingsStore.apiKey,
                appModel: settingsStore.openAIModel,
                maxIterations: settingsStore.maxAgentIterations,
                buildTimeoutSeconds: TimeInterval(settingsStore.buildTimeoutSeconds),
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
}

struct AgentPanelView: View {
    @EnvironmentObject private var projectStore: BookProjectStore
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @ObservedObject var model: AgentPanelModel
    @Binding var workspaceMode: WorkspaceMode

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if projectStore.configMissing {
                        missingConfigBanner
                    } else if let config = projectStore.project?.config {
                        writePermissionsBanner(config)
                    }
                    if let error = model.errorMessage ?? projectStore.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if !model.liveToolLog.isEmpty {
                        toolLogSection
                    }
                    if let result = model.result {
                        resultSection(result)
                    } else if !model.isRunning {
                        Text("Run an agent task to stage edits and write a patch proposal to bookloop/patches/. Book files stay unchanged until you apply the patch in Tools → Patches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Model: \(settingsStore.openAIModel) via OpenAI (no web search). One agent run writes one patch file with multiple diff blocks; long reviews may need higher max iterations in app settings or several agent runs.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("Limitations: lexical search only, exact-text apply_patch (single match), simple build command parsing.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ForEach(AgentTaskType.allCases.filter { $0 != .custom }) { taskType in
                    Button(taskType.displayName) {
                        Task {
                            await model.run(
                                type: taskType,
                                projectStore: projectStore,
                                patchStore: patchStore,
                                settingsStore: settingsStore
                            )
                        }
                    }
                    .disabled(model.isRunning || projectStore.project == nil || !settingsStore.hasAPIKey)
                }
                if model.isRunning {
                    Button("Cancel", role: .destructive) { model.cancel() }
                }
            }

            TextField("Optional instruction for custom tasks", text: $model.customInstruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

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
                .disabled(model.isRunning || projectStore.project == nil || !settingsStore.hasAPIKey)

                if model.result?.patchProposalPath != nil {
                    Button("Delete Proposal Patch", role: .destructive) {
                        model.deleteProposal(projectStore: projectStore, patchStore: patchStore)
                    }
                }

                Spacer()

                if let project = projectStore.project {
                    Text(project.projectMap.compactSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
    }

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
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var toolLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tool Log").font(.headline)
            ForEach(model.liveToolLog) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(entry.succeeded ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.toolName).font(.caption.weight(.semibold))
                        Text(entry.resultSummary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
        }
    }

    private func resultSection(_ result: AgentResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary").font(.headline)
            Text(result.summary).textSelection(.enabled)

            if !result.changedFiles.isEmpty {
                Text("Staged Files").font(.headline)
                ForEach(result.changedFiles, id: \.self) { path in
                    Text(path).font(.caption.monospaced())
                }
            }

            if let patchPath = result.patchProposalPath {
                Text("Patch Proposal").font(.headline)
                Text(patchPath).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Open Patches Tab") {
                        workspaceMode = .tool(.patches)
                    }
                    Button("Reveal in Finder") {
                        if let absolute = result.patchProposalAbsolutePath {
                            FileHelpers.openInFinder(path: absolute)
                        }
                    }
                }
            }

            if let proposalPatch = result.proposalPatch {
                Text("Proposal Preview").font(.headline)
                ScrollView {
                    Text(proposalPatch)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            Button("Copy Summary") {
                FileHelpers.copyToPasteboard(result.summary)
            }

            Button("Open Session Folder") {
                FileHelpers.openInFinder(path: result.sessionDirectory.path)
            }
        }
    }
}
