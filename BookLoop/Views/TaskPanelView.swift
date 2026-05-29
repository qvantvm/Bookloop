import SwiftUI

struct TaskPanelView: View {
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var previewModel: BookPreviewModel
    @EnvironmentObject private var agentPanelModel: AgentPanelModel
    @EnvironmentObject private var bookProjectStore: BookProjectStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var patchStore: PatchStore

    let book: BookConfig
    @Binding var workspaceMode: WorkspaceMode
    @Binding var showingAppSettings: Bool

    @State private var selectedURL: URL?
    @State private var validationOutput: String?
    @State private var confirmingValidation = false
    @State private var isRunningValidation = false
    @State private var showingNewTaskSheet = false
    @State private var validationExpanded = false
    @State private var showsRawMarkdown = false

    private var taskSummaries: [TaskFileSummary] {
        taskStore.taskFiles.map { TaskFileSummary.parse($0) }
    }

    private var selectedSummary: TaskFileSummary? {
        guard let selectedURL else { return nil }
        return taskSummaries.first { $0.url == selectedURL }
    }

    private var selectedTaskText: String? {
        guard let selectedURL else { return nil }
        return try? String(contentsOf: selectedURL, encoding: .utf8)
    }

    private var canReRunInAgent: Bool {
        selectedTaskText?.nilIfBlank != nil
            && bookProjectStore.project != nil
            && settingsStore.hasAPIKey
    }

    private var reRunInAgentDisabledReason: String? {
        if bookProjectStore.project == nil { return "Select a book first." }
        if !settingsStore.hasAPIKey { return "Add your OpenAI API key in App Settings." }
        if selectedTaskText?.nilIfBlank == nil { return "Select a task with content to re-run." }
        return nil
    }

    var body: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

            rightPane
                .frame(minWidth: 420)
        }
        .onAppear {
            taskStore.refresh(book: book)
            selectedURL = taskStore.taskFiles.first
        }
        .onChange(of: taskStore.lastGeneratedURL) { _, url in
            guard let url else { return }
            selectedURL = url
        }
        .onChange(of: taskStore.taskFiles) { _, files in
            if let selectedURL, files.contains(selectedURL) { return }
            selectedURL = files.first
        }
        .onChange(of: selectedURL) { _, _ in
            showsRawMarkdown = false
        }
        .sheet(isPresented: $showingNewTaskSheet) {
            NewTaskSheet(book: book) { url in
                selectedURL = url
            }
            .environmentObject(taskStore)
            .environmentObject(reviewStore)
            .environmentObject(previewModel)
        }
        .alert("Run validation command?", isPresented: $confirmingValidation) {
            Button("Cancel", role: .cancel) {}
            Button("Run") { Task { await runValidationCommand() } }
        } message: {
            Text("BookLoop will run this command in the book root: \(book.effectiveValidationCommand ?? "")")
        }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            if let message = taskStore.message {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.caption)
                    Spacer()
                    Button {
                        taskStore.message = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.08))
                Divider()
            }

            if taskSummaries.isEmpty {
                emptyHistoryState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(taskSummaries) { summary in
                            TaskHistoryRowView(summary: summary, isSelected: selectedURL == summary.url)
                                .onTapGesture {
                                    selectedURL = summary.url
                                }
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            validationFooter
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(book.displayName)
                .font(.headline)

            Text("New tasks run automatically in Agent. Copy a brief for Cursor if needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if agentPanelModel.queuedTaskCount > 0 {
                Text("\(agentPanelModel.queuedTaskCount) task(s) queued in Agent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    showingNewTaskSheet = true
                } label: {
                    Label("New Task", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    taskStore.refresh(book: book)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
    }

    private var emptyHistoryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No tasks yet")
                .font(.headline)
            Text("Click New Task — Agent runs automatically after each brief is created.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var validationFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(isRunningValidation ? "Running Validation…" : "Run Validation Command") {
                confirmingValidation = true
            }
            .disabled(isRunningValidation || !book.allowShellCommands || book.effectiveValidationCommand == nil)
            .buttonStyle(.bordered)

            if book.effectiveValidationCommand == nil {
                Text("Configure a validation command in book Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if !book.allowShellCommands {
                Text("Enable shell commands in book Settings to run validation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: - Right pane

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = selectedSummary, let selectedURL {
                detailHeader(summary: summary)
                Divider()

                if let markdown = selectedTaskText?.trimmingCharacters(in: .whitespacesAndNewlines), !markdown.isEmpty {
                    HTMLStringView(html: TaskBriefMarkdownRenderer().renderDocument(
                        markdown: markdown,
                        title: summary.displayTitle
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(
                        title: "Empty Task Brief",
                        message: "This task file has no content to preview.",
                        systemImage: "doc.text"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()

                DisclosureGroup("Show raw markdown", isExpanded: $showsRawMarkdown) {
                    ScrollView {
                        Text(selectedTaskText ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            Task { await reRunSelectedTaskInAgent() }
                        } label: {
                            Label("Re-run in Agent", systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canReRunInAgent)

                        Button {
                            FileHelpers.copyToPasteboard(selectedTaskText ?? "")
                        } label: {
                            Label("Copy Task Text", systemImage: "doc.on.doc")
                        }

                        Button {
                            FileHelpers.openInFinder(path: selectedURL.path)
                        } label: {
                            Label("Open in Finder", systemImage: "folder")
                        }
                    }

                    if let reason = reRunInAgentDisabledReason, !canReRunInAgent {
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
                .padding(12)

                if validationOutput != nil {
                    Divider()
                    validationOutputSection
                }
            } else {
                EmptyStateView(
                    title: "No Task Selected",
                    message: "Generate a new task or select one from the list to preview its brief.",
                    systemImage: "checklist"
                )
            }
        }
    }

    private func detailHeader(summary: TaskFileSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: summary.mode?.systemImage ?? "doc.text")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayTitle)
                    .font(.headline)
                HStack(spacing: 8) {
                    if let mode = summary.mode {
                        Text(mode.displayName)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    if let chapter = summary.chapterLabel {
                        Text(chapter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = summary.createdAt {
                        Text(DateFormatting.display.string(from: date))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(summary.url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(12)
    }

    private var validationOutputSection: some View {
        DisclosureGroup("Validation Output", isExpanded: $validationExpanded) {
            ScrollView {
                Text(validationOutput ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
    }

    private func reRunSelectedTaskInAgent() async {
        guard let taskText = selectedTaskText?.nilIfBlank else { return }
        workspaceMode = .tool(.agent)
        await agentPanelModel.enqueueCustomTask(
            instruction: taskText,
            projectStore: bookProjectStore,
            patchStore: patchStore,
            settingsStore: settingsStore
        )
    }

    private func runValidationCommand() async {
        guard book.allowShellCommands, let command = book.effectiveValidationCommand else {
            validationOutput = "Shell commands are disabled or no validation command is configured."
            validationExpanded = true
            return
        }
        isRunningValidation = true
        validationOutput = "Running: \(command)"
        validationExpanded = true
        defer { isRunningValidation = false }
        do {
            let result = try await ShellCommandRunner().runAsync(command: command, book: book)
            validationOutput = "Command: \(command)\nExit code: \(result.exitCode)\n\(result.combinedOutput)"
        } catch {
            validationOutput = error.localizedDescription
        }
    }
}

// MARK: - History row

struct TaskHistoryRowView: View {
    let summary: TaskFileSummary
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: summary.mode?.systemImage ?? "doc.text")
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let chapter = summary.chapterLabel {
                        Text(chapter)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let date = summary.createdAt {
                        Text(DateFormatting.display.string(from: date))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - New task sheet

struct NewTaskSheet: View {
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var previewModel: BookPreviewModel
    @Environment(\.dismiss) private var dismiss

    let book: BookConfig
    let onGenerated: (URL) -> Void

    @State private var selectedMode: RevisionTaskMode = .proposePatchOnly
    @State private var chapterOverride = ""

    private var selectedReviews: [ReviewItem] {
        reviewStore.items.filter { reviewStore.selectedIDs.contains($0.id) }
    }

    private var resolvedChapterID: String? {
        let override = chapterOverride.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        if let override { return override }
        if let reviewChapter = selectedReviews.compactMap(\.chapter).first { return reviewChapter }
        return previewModel.detectedChapterID
    }

    private var selectedPassage: String? {
        previewModel.selectedText?.nilIfBlank
    }

    private var contextWarning: String? {
        if selectedMode.requiresSelectedReviews && selectedReviews.isEmpty {
            return "Select review items on the Reviews tab first."
        }
        if selectedMode == .proposeFigure && resolvedChapterID == nil {
            return "Enter a chapter ID or open a chapter in Reading mode."
        }
        return nil
    }

    private var canGenerate: Bool {
        contextWarning == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Task")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    taskTypeSection
                    contextSection

                    if let warning = contextWarning {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Generate Task") {
                    generateTask()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGenerate)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    private var taskTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Task type")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(TaskCategory.allCases, id: \.self) { category in
                let modes = RevisionTaskMode.modes(in: category)
                if !modes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.sectionTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)

                        ForEach(modes) { mode in
                            TaskModeCardView(
                                mode: mode,
                                isSelected: selectedMode == mode,
                                onSelect: { selectedMode = mode }
                            )
                        }
                    }
                }
            }
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                contextRow(label: "Chapter", value: resolvedChapterID ?? "Not specified")

                if selectedMode == .proposeFigure || selectedMode == .proposePatchOnly {
                    TextField("Chapter override (optional)", text: $chapterOverride)
                        .textFieldStyle(.roundedBorder)
                }

                contextRow(
                    label: "Selected reviews",
                    value: selectedReviews.isEmpty ? "None" : "\(selectedReviews.count) selected"
                )

                if !selectedReviews.isEmpty {
                    ForEach(selectedReviews.prefix(3)) { item in
                        Text("• \(item.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if selectedReviews.count > 3 {
                        Text("…and \(selectedReviews.count - 3) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let passage = selectedPassage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected passage")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(passage.prefix(200) + (passage.count > 200 ? "…" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    private func generateTask() {
        let reviews = selectedMode.requiresSelectedReviews ? selectedReviews : []
        taskStore.generate(
            book: book,
            mode: selectedMode,
            chapterID: resolvedChapterID,
            reviewItems: reviews,
            selectedText: selectedPassage
        )
        if let url = taskStore.lastGeneratedURL {
            onGenerated(url)
        }
        dismiss()
    }
}

struct TaskModeCardView: View {
    let mode: RevisionTaskMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(mode.taskDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
