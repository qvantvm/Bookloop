import AppKit
import SwiftUI
import WebKit

struct FeedbackPanelView: View {
    @EnvironmentObject private var webModel: WebViewModel
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var projectStore: ProjectContentStore

    let book: BookConfig

    @State private var chapter = ""
    @State private var type: FeedbackType = .confusion
    @State private var severity: FeedbackSeverity = .medium
    @State private var section = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var suggestedFix = ""
    @State private var message: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Feedback")
                .font(.headline)

            TextField("Chapter ID", text: $chapter)
            Text("Use the chapter id from frontmatter (for example home), not a docs/ path. Reviews save locally under reviews/review_items/.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Type", selection: $type) {
                ForEach(FeedbackType.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            Picker("Severity", selection: $severity) {
                ForEach(FeedbackSeverity.allCases) { item in
                    Text(item.rawValue.capitalized).tag(item)
                }
            }
            TextField("Section", text: $section)
            TextField("Title", text: $title)
            Text("Observation / Body")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $bodyText)
                .frame(minHeight: 110)
                .border(Color.secondary.opacity(0.25))
            TextField("Suggested Fix", text: $suggestedFix, axis: .vertical)

            HStack {
                Button("Use Selected Text") {
                    Task { await appendSelectedText() }
                }
            }

            HStack {
                Button("Save Review") {
                    Task { await submitReview() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isSubmitting)
                Button("Clear Form") {
                    clearAll()
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.localizedCaseInsensitiveContains("created") ? .green : .red)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            syncChapterFromPreview()
        }
        .onChange(of: webModel.detectedChapterID) { _, _ in
            syncChapterFromPreview()
        }
        .onChange(of: webModel.currentURL) { _, _ in
            syncChapterFromPreview()
        }
    }

    private func syncChapterFromPreview() {
        let resolved = resolvedChapterID(from: webModel.detectedChapterID)
        if !resolved.isEmpty {
            chapter = resolved
        }
    }

    private func appendSelectedText() async {
        await webModel.captureSelectedText()
        guard let selected = webModel.selectedText?.nilIfBlank else { return }
        let block = "\n\nSelected passage:\n\n" + selected.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
        bodyText += block
    }

    private func resolvedChapterID(from raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return ChapterResolver.feedbackAPIChapterID(raw, book: book, chapters: projectStore.chapters, currentURL: webModel.currentURL)
    }

    private func submitReview() async {
        let validation = validate()
        guard validation == nil else {
            message = validation
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let resolvedChapter = ChapterResolver.feedbackAPIChapterID(
            chapter.trimmingCharacters(in: .whitespacesAndNewlines),
            book: book,
            chapters: projectStore.chapters,
            currentURL: webModel.currentURL
        )
        do {
            let request = ReviewRequest(
                chapter: resolvedChapter,
                type: type.rawValue,
                severity: severity.rawValue,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                section: section.nilIfBlank,
                suggested_fix: suggestedFix.nilIfBlank
            )
            let response = try ReviewItemWriter().write(request: request, book: book)
            message = response.ok ? "Review saved: \(response.file)" : "Could not save review."
            title = ""
            bodyText = ""
            suggestedFix = ""
            reviewStore.refresh(book: book)
        } catch {
            message = error.localizedDescription
        }
    }

    private func validate() -> String? {
        if chapter.nilIfBlank == nil { return "Chapter ID is required." }
        if title.nilIfBlank == nil { return "Title is required." }
        if bodyText.nilIfBlank == nil { return "Body is required." }
        let resolvedChapter = ChapterResolver.feedbackAPIChapterID(
            chapter.trimmingCharacters(in: .whitespacesAndNewlines),
            book: book,
            chapters: projectStore.chapters,
            currentURL: webModel.currentURL
        )
        if !ChapterResolver.feedbackAPIChapterExists(resolvedChapter, book: book) {
            return "Chapter not found: docs/\(resolvedChapter).md. Use the chapter id from frontmatter, or open the page in Preview to auto-detect it."
        }
        return nil
    }

    private func clearAll() {
        chapter = resolvedChapterID(from: webModel.detectedChapterID)
        type = .confusion
        severity = .medium
        section = ""
        title = ""
        bodyText = ""
        suggestedFix = ""
        message = nil
    }
}

enum ReviewGrouping: String, CaseIterable, Identifiable {
    case none = "None"
    case chapter = "Chapter"
    case severity = "Severity"
    case type = "Type"

    var id: String { rawValue }
}

private struct ReviewItemSection: Identifiable {
    var id: String
    var items: [ReviewItem]
}

struct ReviewBrowserView: View {
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var webModel: WebViewModel
    @EnvironmentObject private var projectStore: ProjectContentStore

    let book: BookConfig
    @State private var selectedDetailID: String?
    @State private var grouping: ReviewGrouping = .chapter
    @State private var showsFeedbackForm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search reviews", text: $reviewStore.searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Chapter", selection: $reviewStore.chapterFilter) {
                    Text("All").tag("All")
                    ForEach(reviewStore.chapters, id: \.self) { Text($0).tag($0) }
                }
                Picker("Severity", selection: $reviewStore.severityFilter) {
                    Text("All").tag("All")
                    ForEach(reviewStore.severities, id: \.self) { Text($0).tag($0) }
                }
                Picker("Type", selection: $reviewStore.typeFilter) {
                    Text("All").tag("All")
                    ForEach(reviewStore.types, id: \.self) { Text($0).tag($0) }
                }
                Picker("Group", selection: $grouping) {
                    ForEach(ReviewGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Sort", selection: $reviewStore.sortMode) {
                    ForEach(ReviewStore.SortMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Button(showsFeedbackForm ? "Hide Submit Review" : "Submit Review") {
                    showsFeedbackForm.toggle()
                }
            }
            .padding(8)

            if showsFeedbackForm {
                Divider()
                ScrollView {
                    FeedbackPanelView(book: book)
                        .environmentObject(webModel)
                    .environmentObject(reviewStore)
                    .environmentObject(projectStore)
                    .padding()
                }
                .frame(maxHeight: 340)
                Divider()
            }

            TabView {
                reviewItemsPane
                    .tabItem { Text("Review Items") }
                SupplementalMarkdownView(title: "Cumulative Review", content: reviewStore.cumulativeReview, emptyMessage: "reviews/cumulative_review.md was not found.")
                    .tabItem { Text("Cumulative") }
                SupplementalMarkdownView(title: "Review Index", content: reviewStore.reviewIndex, emptyMessage: "reviews/review_index.json was not found.")
                    .tabItem { Text("Index") }
            }

            Divider()

            HStack {
                Button("Refresh Reviews") {
                    reviewStore.refresh(book: book)
                }
                Button("Generate Task for Selected Reviews") {
                    let selected = reviewStore.items.filter { reviewStore.selectedIDs.contains($0.id) }
                    taskStore.generate(book: book, mode: .fixReviews, chapterID: selected.compactMap(\.chapter).first, reviewItems: selected, selectedText: webModel.selectedText)
                }
                .disabled(reviewStore.selectedIDs.isEmpty)
                Button("Generate Task for Current Chapter") {
                    taskStore.generate(book: book, mode: .proposePatchOnly, chapterID: webModel.detectedChapterID, reviewItems: [], selectedText: webModel.selectedText)
                }
                Button("Generate Figure Task") {
                    let selected = reviewStore.items.filter { reviewStore.selectedIDs.contains($0.id) }
                    taskStore.generate(book: book, mode: .proposeFigure, chapterID: selected.compactMap(\.chapter).first ?? webModel.detectedChapterID, reviewItems: selected, selectedText: webModel.selectedText)
                }
                .disabled(reviewStore.selectedIDs.isEmpty && webModel.detectedChapterID == nil)
                Spacer()
                Text("\(reviewStore.filteredItems.count) shown")
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var reviewItemsPane: some View {
        Group {
            if reviewStore.items.isEmpty {
                EmptyStateView(title: "No Review Items", message: "BookLoop could not find Markdown reviews in reviews/review_items.", systemImage: "quote.bubble")
            } else {
                HSplitView {
                    List(selection: $reviewStore.selectedIDs) {
                        ForEach(groupedSections) { section in
                            if grouping == .none {
                                ForEach(section.items) { item in
                                    ReviewRow(item: item)
                                        .tag(item.id)
                                        .onTapGesture { selectedDetailID = item.id }
                                }
                            } else {
                                Section(section.id) {
                                    ForEach(section.items) { item in
                                        ReviewRow(item: item)
                                            .tag(item.id)
                                            .onTapGesture { selectedDetailID = item.id }
                                    }
                                }
                            }
                        }
                    }
                    .frame(minWidth: 320)

                    ReviewDetailView(item: selectedReview)
                        .frame(minWidth: 320)
                }
            }
        }
    }

    private var groupedSections: [ReviewItemSection] {
        let items = reviewStore.filteredItems
        guard grouping != .none else {
            return [ReviewItemSection(id: "All Reviews", items: items)]
        }

        let grouped = Dictionary(grouping: items) { item -> String in
            switch grouping {
            case .none: return "All Reviews"
            case .chapter: return item.chapter ?? "Unknown Chapter"
            case .severity: return item.severity ?? "Unknown Severity"
            case .type: return item.type ?? "Unknown Type"
            }
        }

        return grouped.keys.sorted().map { key in
            ReviewItemSection(id: key, items: grouped[key] ?? [])
        }
    }

    private var selectedReview: ReviewItem? {
        if let selectedDetailID {
            return reviewStore.items.first { $0.id == selectedDetailID }
        }
        if let first = reviewStore.selectedIDs.first {
            return reviewStore.items.first { $0.id == first }
        }
        return reviewStore.filteredItems.first
    }
}

struct SupplementalMarkdownView: View {
    let title: String
    let content: String?
    let emptyMessage: String

    var body: some View {
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
        } else {
            EmptyStateView(title: title, message: emptyMessage, systemImage: "doc.text")
        }
    }
}

struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .fontWeight(.medium)
                .lineLimit(2)
            HStack {
                if let severity = item.severity {
                    Text(severity.uppercased())
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if let type = item.type {
                    Text(type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.chapter ?? "Unknown chapter")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

struct ReviewDetailView: View {
    let item: ReviewItem?

    var body: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    LabeledContent("ID", value: item.id)
                    LabeledContent("Chapter", value: item.chapter ?? "Unknown")
                    LabeledContent("Type", value: item.type ?? "Unknown")
                    LabeledContent("Severity", value: item.severity ?? "Unknown")
                    LabeledContent("Status", value: item.status.rawValue)
                    if let body = item.body {
                        Text("Body").font(.headline)
                        Text(body).textSelection(.enabled)
                    }
                    if let fix = item.suggestedFix {
                        Text("Suggested Fix").font(.headline)
                        Text(fix).textSelection(.enabled)
                    }
                    HStack {
                        Button("Open in Finder") {
                            FileHelpers.openInFinder(path: item.filePath)
                        }
                        Button("Copy ID") {
                            FileHelpers.copyToPasteboard(item.id)
                        }
                    }
                }
                .padding()
            }
        } else {
            EmptyStateView(title: "Select a Review", message: "Choose a review item to inspect details.", systemImage: "doc.text")
        }
    }
}

private struct FigureRow: View {
    let item: FigureItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Text(item.id)
                .fontWeight(.medium)
            Text("\(item.status.rawValue) • \(item.type.rawValue)")
                .font(.caption)
                .foregroundStyle(item.status == .ok ? Color.secondary : Color.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

struct FigureBrowserView: View {
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var taskStore: TaskStore
    let book: BookConfig
    @State private var selectedID: String?

    var body: some View {
        HSplitView {
            figureListPane
                .frame(minWidth: 300)

            FigureDetailView(book: book, figure: selectedFigure)
                .frame(minWidth: 440)
        }
        .onAppear {
            if selectedID == nil {
                selectedID = figureStore.figures.first?.id
            }
        }
        .onChange(of: figureStore.figures) {
            if selectedID == nil || !figureStore.figures.contains(where: { $0.id == selectedID }) {
                selectedID = figureStore.figures.first?.id
            }
        }
    }

    @ViewBuilder
    private var figureListPane: some View {
        VStack {
            HStack {
                Button("Refresh Figures") {
                    figureStore.refresh(book: book)
                }
                Button("Generate Figure Task") {
                    taskStore.generate(book: book, mode: .proposeFigure, chapterID: selectedFigure?.chapterID, reviewItems: [], selectedText: nil)
                }
                .disabled(selectedFigure == nil)
            }
            .padding(8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(figureStore.figures, id: \.id) { item in
                        Button {
                            selectedID = item.id
                        } label: {
                            FigureRow(item: item, isSelected: selectedID == item.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var selectedFigure: FigureItem? {
        figureStore.figures.first { $0.id == selectedID } ?? figureStore.figures.first
    }
}

struct FigureDetailView: View {
    let book: BookConfig
    let figure: FigureItem?
    @State private var confirmingRegeneration = false
    @State private var regenerationOutput: String?
    @State private var isRegenerating = false

    var body: some View {
        if let figure {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(figure.title ?? figure.id)
                        .font(.title3)
                        .fontWeight(.semibold)
                    FigurePreview(path: figure.outputPath, type: figure.type)
                        .frame(maxWidth: .infinity, minHeight: 220)
                    LabeledContent("Status", value: figure.status.rawValue)
                    LabeledContent("Output", value: figure.outputPath)
                    LabeledContent("Source", value: figure.sourcePath ?? "Not found")
                    LabeledContent("Chapter", value: figure.chapterID ?? "Unknown")
                    LabeledContent("Referenced From", value: figure.referencedFrom.isEmpty ? "None" : "\(figure.referencedFrom.count) file(s)")
                    ForEach(figure.referencedFrom, id: \.self) { path in
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open Output") { FileHelpers.openInFinder(path: figure.outputPath) }
                        if let sourcePath = figure.sourcePath {
                            Button("Open Source") { FileHelpers.openInFinder(path: sourcePath) }
                        }
                        Button("Copy Markdown Reference") {
                            FileHelpers.copyToPasteboard("![\(figure.caption ?? figure.id)](\(figure.outputPath))")
                        }
                        Button(isRegenerating ? "Regenerating..." : "Regenerate") {
                            confirmingRegeneration = true
                        }
                        .disabled(isRegenerating || !book.allowShellCommands || !book.allowFigureRegeneration || regenerationCommand(for: figure) == nil)
                    }
                    if let regenerationOutput {
                        Text("Regeneration Output")
                            .font(.headline)
                        Text(regenerationOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .alert("Regenerate figure?", isPresented: $confirmingRegeneration) {
                Button("Cancel", role: .cancel) {}
                Button("Run") { Task { await runRegeneration(for: figure) } }
            } message: {
                Text("BookLoop will run the configured figure command in the book root. No command runs unless shell commands and figure regeneration are enabled for this book.")
            }
        } else {
            EmptyStateView(title: "No Figures", message: "BookLoop scans Markdown image references and docs/assets/figures.", systemImage: "photo")
        }
    }

    private func regenerationCommand(for figure: FigureItem) -> String? {
        if let command = figure.generationCommand?.nilIfBlank {
            return command
        }
        if let command = book.figureGenerationCommand?.nilIfBlank {
            return command.replacingOccurrences(of: "<figure-id>", with: figure.id)
        }
        return nil
    }

    private func runRegeneration(for figure: FigureItem) async {
        guard book.allowShellCommands, book.allowFigureRegeneration, let command = regenerationCommand(for: figure) else {
            regenerationOutput = "Figure regeneration is disabled or no command is configured."
            return
        }
        isRegenerating = true
        regenerationOutput = "Running: \(command)"
        defer { isRegenerating = false }
        do {
            let result = try await ShellCommandRunner().runAsync(command: command, book: book)
            regenerationOutput = "Command: \(command)\nExit code: \(result.exitCode)\n\(result.combinedOutput)"
        } catch {
            regenerationOutput = error.localizedDescription
        }
    }
}

struct FigurePreview: View {
    let path: String
    let type: FigureType

    var body: some View {
        if [.png, .jpg].contains(type), let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .background(Color.secondary.opacity(0.08))
        } else {
            VStack(spacing: 8) {
                Image(systemName: type == .svg ? "safari" : "doc")
                    .font(.largeTitle)
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open") {
                    FileHelpers.openInFinder(path: path)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.08))
        }
    }
}

struct TaskBrowserView: View {
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var webModel: WebViewModel

    let book: BookConfig
    @State private var selectedURL: URL?
    @State private var validationOutput: String?
    @State private var confirmingValidation = false
    @State private var isRunningValidation = false

    var body: some View {
        HSplitView {
            VStack {
                HStack {
                    Button("Current Chapter Task") {
                        taskStore.generate(book: book, mode: .proposePatchOnly, chapterID: webModel.detectedChapterID, reviewItems: [], selectedText: webModel.selectedText)
                    }
                    Button("Validation Task") {
                        taskStore.generate(book: book, mode: .validateBook, chapterID: nil, reviewItems: [], selectedText: nil)
                    }
                    Button(isRunningValidation ? "Running Validation..." : "Run Validation Command") {
                        confirmingValidation = true
                    }
                    .disabled(isRunningValidation || !book.allowShellCommands || book.validationCommand?.nilIfBlank == nil)
                    Button("Refresh") {
                        taskStore.refresh(book: book)
                    }
                }
                .padding(8)
                List(selection: $selectedURL) {
                    ForEach(taskStore.taskFiles, id: \.self) { url in
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent)
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(url)
                    }
                }
            }
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 10) {
                if let selectedURL {
                    Text(selectedURL.lastPathComponent)
                        .font(.headline)
                    ScrollView {
                        Text((try? String(contentsOf: selectedURL, encoding: .utf8)) ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    HStack {
                        Button("Open Task in Finder") { FileHelpers.openInFinder(path: selectedURL.path) }
                        Button("Copy Task Text") {
                            FileHelpers.copyToPasteboard((try? String(contentsOf: selectedURL, encoding: .utf8)) ?? "")
                        }
                    }
                    .padding([.horizontal, .bottom])
                    if let validationOutput {
                        Divider()
                        Text("Validation Output")
                            .font(.headline)
                            .padding(.horizontal)
                        ScrollView {
                            Text(validationOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(maxHeight: 180)
                    }
                } else {
                    EmptyStateView(title: "No Task Selected", message: "Generate or select a Cursor-ready task file.", systemImage: "checklist")
                }
            }
            .frame(minWidth: 420)
        }
        .onAppear {
            taskStore.refresh(book: book)
            selectedURL = taskStore.taskFiles.first
        }
        .alert("Run validation command?", isPresented: $confirmingValidation) {
            Button("Cancel", role: .cancel) {}
            Button("Run") { Task { await runValidationCommand() } }
        } message: {
            Text("BookLoop will run this command in the book root: \(book.validationCommand ?? "")")
        }
    }

    private func runValidationCommand() async {
        guard book.allowShellCommands, let command = book.validationCommand?.nilIfBlank else {
            validationOutput = "Shell commands are disabled or no validation command is configured."
            return
        }
        isRunningValidation = true
        validationOutput = "Running: \(command)"
        defer { isRunningValidation = false }
        do {
            let result = try await ShellCommandRunner().runAsync(command: command, book: book)
            validationOutput = "Command: \(command)\nExit code: \(result.exitCode)\n\(result.combinedOutput)"
        } catch {
            validationOutput = error.localizedDescription
        }
    }
}

enum PatchApplicabilityStatus: Equatable {
    case unknown
    case checking
    case applicable
    case alreadyApplied(String)
    case checkFailed(String)
}

enum PatchReviewError: LocalizedError {
    case noSelectedPatch
    case noAcceptedBlocks
    case emptyReviewedPatch
    case shellCommandsDisabled
    case emptyCommitMessage
    case archiveSourceMissing(path: String)

    var errorDescription: String? {
        switch self {
        case .noSelectedPatch: return "No patch proposal is selected."
        case .noAcceptedBlocks: return "Accept at least one rendered block before applying."
        case .emptyReviewedPatch: return "The reviewed patch is empty."
        case .shellCommandsDisabled: return "Git commands are disabled for this book. Enable Allow patch apply or Allow shell commands in book Settings, or copy the git commit command and run it in Terminal."
        case .emptyCommitMessage: return "Enter a commit message before committing."
        case .archiveSourceMissing(let path): return "Could not archive \(path) because the patch file no longer exists."
        }
    }
}

struct PatchReviewView: View {
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var library: BookLibraryStore
    let book: BookConfig

    private var activeBook: BookConfig {
        library.selectedBook ?? book
    }
    @State private var isRunningPatchCommand = false
    @State private var confirmingApply = false
    @State private var confirmingCommit = false
    @State private var confirmingArchive = false
    @State private var commitMessage = ""
    @State private var workflowPhase: PatchWorkflowPhase = .reviewing
    @State private var pendingCommitContext: PendingPatchCommitContext?
    @State private var patchApplicabilityStatus: PatchApplicabilityStatus = .unknown
    @State private var gitWorkingTree = "Loading git status…"
    @State private var latestCommit = ""
    @State private var activityLog: [PatchActivityEntry] = []
    @State private var statusMessage: String?
    @State private var showAdvanced = false
    @State private var isPatchListVisible = true
    @State private var isActionPanelVisible = true
    @State private var blockDecisions: [String: PatchBlockDecision] = [:]
    @State private var gitRefreshGeneration = 0

    private var renderedBlocks: [RenderedPatchBlock] {
        guard let proposal = patchStore.selectedProposal else { return [] }
        return PatchParser().renderedBlocks(from: proposal)
    }

    private var acceptedBlockIDs: Set<String> {
        Set(blockDecisions.filter { $0.value == .accepted }.map { $0.key })
    }

    var body: some View {
        VStack(spacing: 0) {
            patchLayoutToolbar
            Divider()
            HSplitView {
                if isPatchListVisible {
                    patchListPane
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                }

                RenderedPatchReviewView(blocks: renderedBlocks, decisions: $blockDecisions)
                    .frame(minWidth: 420)

                if isActionPanelVisible {
                    PatchActionPanel(
                        book: activeBook,
                        proposal: patchStore.selectedProposal,
                        pendingCommitContext: pendingCommitContext,
                        blocks: renderedBlocks,
                        decisions: $blockDecisions,
                        workflowPhase: workflowPhase,
                        gitWorkingTree: gitWorkingTree,
                        latestCommit: latestCommit,
                        activityLog: activityLog,
                        patchApplicabilityStatus: patchApplicabilityStatus,
                        isRunningPatchCommand: isRunningPatchCommand,
                        showAdvanced: $showAdvanced,
                        commitMessage: $commitMessage,
                        statusMessage: statusMessage,
                        onApplyAccepted: { confirmingApply = true },
                        onCommit: { confirmingCommit = true },
                        onCopyCommitCommand: copyCommitCommand,
                        onOpenPatchFile: openSelectedPatchFile,
                        onArchiveWithoutApplying: { confirmingArchive = true },
                        onCopyAcceptedPatch: copyAcceptedPatch,
                        onSaveAcceptedPatch: saveAcceptedPatch,
                        onCheckAcceptedPatch: checkAcceptedBlocksPatch,
                        onApplyFullPatch: applyFullPatchFromAdvanced,
                        onCheckFullPatch: checkOriginalPatch
                    )
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: patchStore.selectedProposalID) {
            resetForSelectedPatch()
        }
        .onChange(of: blockDecisions) {
            scheduleGitPanelRefresh()
        }
        .onAppear {
            activityLog = PatchActivityLogger.load(book: activeBook)
            resetForSelectedPatch()
        }
        .alert("Apply accepted changes to book files?", isPresented: $confirmingApply) {
            Button("Cancel", role: .cancel) {}
            Button("Apply to Book", role: .destructive) {
                Task { await applyAcceptedBlocks() }
            }
        } message: {
            Text("BookLoop will run git apply --check, then git apply for the accepted blocks only. Book files are updated on disk; nothing is committed yet.")
        }
        .alert("Commit changes to git?", isPresented: $confirmingCommit) {
            Button("Cancel", role: .cancel) {}
            Button("Commit", role: .destructive) {
                Task { await commitAppliedChanges() }
            }
        } message: {
            Text("BookLoop will run git add on the changed files, then git commit with your message.")
        }
        .alert("Archive patch without applying?", isPresented: $confirmingArchive) {
            Button("Cancel", role: .cancel) {}
            Button("Archive") {
                Task { await archiveSelectedPatchWithoutApplying() }
            }
        } message: {
            Text("The patch moves to bookloop/patches/archive/. Book content is not changed.")
        }
    }

    private func resetForSelectedPatch() {
        blockDecisions.removeAll()
        statusMessage = nil
        if workflowPhase != .appliedToDisk {
            pendingCommitContext = nil
            workflowPhase = .reviewing
            commitMessage = defaultCommitMessage(for: patchStore.selectedProposal)
        } else if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessage = defaultCommitMessage(for: patchStore.selectedProposal)
        }
        patchApplicabilityStatus = .unknown
        Task {
            await checkSelectedPatchApplicability()
            await refreshGitPanel()
        }
    }

    private func defaultCommitMessage(for proposal: PatchProposal?) -> String {
        if let pendingCommitContext {
            return "Apply BookLoop patch: \(pendingCommitContext.rootStem)"
        }
        guard let proposal else { return "Apply BookLoop patch" }
        return "Apply BookLoop patch: \(proposal.rootStem)"
    }

    private func appendActivity(_ message: String) {
        let entry = PatchActivityEntry(id: UUID(), timestamp: Date(), message: message)
        activityLog.insert(entry, at: 0)
        if activityLog.count > 20 {
            activityLog = Array(activityLog.prefix(20))
        }
        PatchActivityLogger.append(entry, book: activeBook)
    }

    private func scheduleGitPanelRefresh() {
        gitRefreshGeneration += 1
        let generation = gitRefreshGeneration
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard generation == gitRefreshGeneration else { return }
            await refreshGitPanel()
        }
    }

    private func refreshGitPanel() async {
        do {
            let status = try await PatchApplier().gitStatus(book: activeBook)
            gitWorkingTree = status.combinedOutput.nilIfBlank ?? "Working tree clean."
            let log = try await PatchApplier().gitLog(book: activeBook, limit: 1)
            latestCommit = log.combinedOutput.nilIfBlank ?? ""
        } catch {
            gitWorkingTree = error.localizedDescription
        }

        if workflowPhase == .reviewing, case .alreadyApplied = patchApplicabilityStatus {
            workflowPhase = .alreadyApplied
        }
    }

    private var patchLayoutToolbar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { isPatchListVisible.toggle() }
            } label: {
                Text(isPatchListVisible ? "Hide Patch List" : "Show Patch List")
            }
            .help(isPatchListVisible ? "Hide the patch file list" : "Show the patch file list")

            Button {
                withAnimation { isActionPanelVisible.toggle() }
            } label: {
                Text(isActionPanelVisible ? "Hide Actions" : "Show Actions")
            }
            .help(isActionPanelVisible ? "Hide apply/commit controls" : "Show apply/commit controls")

            Spacer()

            Text("Tip: use Hide Panel / Hide Chat in the bar above to give the diff more horizontal space.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var patchListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Refresh Patches") {
                    patchStore.refresh(book: activeBook)
                }
                Button("Open Patch Folder") {
                    FileHelpers.openInFinder(path: activeBook.patchDirectoryPath)
                }
            }
            .padding(8)

            if patchStore.proposals.isEmpty {
                EmptyStateView(
                    title: "No Pending Patches",
                    message: pendingCommitContext == nil
                        ? "Run Agent → Apply Review Feedback to create patch proposals."
                        : "Patch archived after apply. Finish Step 3: Commit to git on the right.",
                    systemImage: "tray"
                )
                .padding(8)
            } else {
                List(patchStore.proposals, selection: $patchStore.selectedProposalID) { proposal in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposal.displayTitle)
                            .fontWeight(.medium)
                            .lineLimit(2)
                        Text("\(proposal.kindLabel) • \(proposal.changedFiles.count) changed file(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(proposal.id)
                }
            }

            if !renderedBlocks.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rendered Blocks")
                        .font(.headline)
                    ForEach(renderedBlocks) { block in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: blockDecisions[block.id] ?? .pending))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(block.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text((blockDecisions[block.id] ?? .pending).displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private func color(for decision: PatchBlockDecision) -> Color {
        switch decision {
        case .pending: return .orange
        case .accepted: return .green
        case .rejected: return .red
        }
    }

    private func reviewedPatchText() throws -> String {
        guard let proposal = patchStore.selectedProposal else { throw PatchReviewError.noSelectedPatch }
        guard !acceptedBlockIDs.isEmpty else { throw PatchReviewError.noAcceptedBlocks }
        let text = PatchParser().buildReviewedPatch(proposal: proposal, acceptedBlockIDs: acceptedBlockIDs)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PatchReviewError.emptyReviewedPatch }
        return text
    }

    @discardableResult
    private func writeAcceptedPatchToDisk() throws -> String {
        guard let proposal = patchStore.selectedProposal else { throw PatchReviewError.noSelectedPatch }
        let text = try reviewedPatchText()
        return try activeBook.withSecurityScopedProjectRoot {
            try FileHelpers.ensureDirectory(activeBook.patchDirectoryPath)
            let url = URL(fileURLWithPath: activeBook.patchDirectoryPath, isDirectory: true)
                .appendingPathComponent(PatchParser().reviewedPatchFilename(for: proposal))
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
    }

    private func openSelectedPatchFile() {
        guard let proposal = patchStore.selectedProposal else { return }
        FileHelpers.openInFinder(path: proposal.filePath)
    }

    private func copyAcceptedPatch() {
        do {
            FileHelpers.copyToPasteboard(try reviewedPatchText())
            statusMessage = "Copied patch text for \(acceptedBlockIDs.count) accepted block(s)."
            appendActivity("Copied accepted-block patch text")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func saveAcceptedPatch() {
        do {
            _ = try writeAcceptedPatchToDisk()
            patchStore.refresh(book: activeBook)
            statusMessage = "Saved accepted-block patch to bookloop/patches/."
            appendActivity("Saved accepted-block patch")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func checkOriginalPatch() {
        guard let proposal = patchStore.selectedProposal else {
            statusMessage = PatchReviewError.noSelectedPatch.localizedDescription
            return
        }
        Task { await runPatchPreflight(label: "Original patch", path: proposal.filePath) }
    }

    private func checkAcceptedBlocksPatch() {
        Task {
            do {
                let path = try writeAcceptedPatchToDisk()
                await runPatchPreflight(label: "Accepted-block patch", path: path)
                patchStore.refresh(book: activeBook)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func applyFullPatchFromAdvanced() {
        Task { await applyFullPatch() }
    }

    private func runPatchPreflight(label: String, path: String) async {
        isRunningPatchCommand = true
        defer { isRunningPatchCommand = false }
        do {
            let check = try await PatchApplier().checkPatchFileAsync(path: path, book: activeBook)
            statusMessage = "\(label): git apply --check exit \(check.exitCode)\n\(check.combinedOutput)"
            appendActivity("\(label) preflight exit \(check.exitCode)")
            await refreshGitPanel()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func applyFullPatch() async {
        guard let proposal = patchStore.selectedProposal else { return }
        guard activeBook.allowPatchApply else {
            statusMessage = "Enable Allow patch apply in book Settings."
            return
        }
        isRunningPatchCommand = true
        defer { isRunningPatchCommand = false }
        do {
            let result = try await PatchApplier().applyAsync(patch: proposal, book: activeBook)
            if result.exitCode == 0 {
                pendingCommitContext = PendingPatchCommitContext(
                    changedFiles: proposal.changedFiles,
                    rootStem: proposal.rootStem
                )
                workflowPhase = .appliedToDisk
                commitMessage = defaultCommitMessage(for: proposal)
                let archived = try archiveAppliedPatches(sourcePath: proposal.filePath, appliedReviewedPath: nil)
                statusMessage = "Full patch applied to book files."
                appendActivity("Applied full patch \(proposal.rootStem) (\(proposal.changedFiles.count) files)")
                if !archived.isEmpty {
                    appendActivity("Archived: \(archived.joined(separator: ", "))")
                }
            } else {
                statusMessage = "Apply failed (exit \(result.exitCode)).\n\(result.combinedOutput)"
                appendActivity("Apply failed for \(proposal.rootStem)")
            }
            await refreshGitPanel()
            await checkSelectedPatchApplicability()
        } catch {
            statusMessage = error.localizedDescription
            appendActivity("Apply error: \(error.localizedDescription)")
        }
    }

    private func applyAcceptedBlocks() async {
        guard activeBook.allowPatchApply else {
            statusMessage = "Enable Allow patch apply in book Settings."
            return
        }
        isRunningPatchCommand = true
        defer { isRunningPatchCommand = false }
        do {
            guard let sourceProposal = patchStore.selectedProposal else { throw PatchReviewError.noSelectedPatch }
            let sourcePath = sourceProposal.filePath
            let reviewedPatchPath = try writeAcceptedPatchToDisk()
            let result = try await PatchApplier().applyPatchFileAsync(path: reviewedPatchPath, book: activeBook)
            if result.exitCode == 0 {
                pendingCommitContext = PendingPatchCommitContext(
                    changedFiles: sourceProposal.changedFiles,
                    rootStem: sourceProposal.rootStem
                )
                workflowPhase = .appliedToDisk
                commitMessage = defaultCommitMessage(for: sourceProposal)
                let archived = try archiveAppliedPatches(sourcePath: sourcePath, appliedReviewedPath: reviewedPatchPath)
                statusMessage = "Accepted changes applied to book files. Ready to commit."
                appendActivity("Applied \(sourceProposal.rootStem) (\(sourceProposal.changedFiles.count) files)")
                if !archived.isEmpty {
                    appendActivity("Archived: \(archived.joined(separator: ", "))")
                }
            } else {
                statusMessage = "Apply failed (exit \(result.exitCode)).\n\(result.combinedOutput)"
                appendActivity("Apply failed for \(sourceProposal.rootStem)")
            }
            await refreshGitPanel()
            await checkSelectedPatchApplicability()
        } catch {
            statusMessage = error.localizedDescription
            appendActivity("Apply error: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func archiveAppliedPatches(sourcePath: String, appliedReviewedPath: String?) throws -> [String] {
        var archivedNames: [String] = []
        var errors: [String] = []

        if let appliedReviewedPath {
            do {
                let destination = try PatchFileHelpers.archivePatch(at: appliedReviewedPath, book: activeBook)
                archivedNames.append(URL(fileURLWithPath: destination).lastPathComponent)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if sourcePath != appliedReviewedPath {
            do {
                let destination = try PatchFileHelpers.archivePatch(at: sourcePath, book: activeBook)
                archivedNames.append(URL(fileURLWithPath: destination).lastPathComponent)
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        patchStore.refresh(book: activeBook)
        if !errors.isEmpty {
            throw NSError(
                domain: "BookLoopPatchArchive",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")]
            )
        }
        return archivedNames
    }

    private func archiveSelectedPatchWithoutApplying() async {
        guard let proposal = patchStore.selectedProposal else { return }
        do {
            let destination = try PatchFileHelpers.archivePatch(at: proposal.filePath, book: activeBook)
            patchStore.refresh(book: activeBook)
            statusMessage = "Archived to \(URL(fileURLWithPath: destination).lastPathComponent)."
            appendActivity("Archived without applying: \(proposal.rootStem)")
            await refreshGitPanel()
        } catch {
            statusMessage = error.localizedDescription
            appendActivity("Archive failed: \(error.localizedDescription)")
        }
    }

    private func checkSelectedPatchApplicability() async {
        guard let proposal = patchStore.selectedProposal else {
            patchApplicabilityStatus = .unknown
            return
        }
        patchApplicabilityStatus = .checking
        do {
            let check = try await PatchApplier().checkPatchFileAsync(path: proposal.filePath, book: activeBook)
            if check.exitCode == 0 {
                patchApplicabilityStatus = .applicable
            } else {
                let message = check.combinedOutput.nilIfBlank ?? "Patch check failed."
                if message.localizedCaseInsensitiveContains("already exists")
                    || message.localizedCaseInsensitiveContains("patch does not apply")
                    || message.localizedCaseInsensitiveContains("conflict") {
                    patchApplicabilityStatus = .alreadyApplied(message)
                    workflowPhase = .alreadyApplied
                } else {
                    patchApplicabilityStatus = .checkFailed(message)
                }
            }
        } catch {
            patchApplicabilityStatus = .checkFailed(error.localizedDescription)
        }
    }

    private func copyCommitCommand() {
        let paths = pendingCommitContext?.changedFiles ?? patchStore.selectedProposal?.changedFiles ?? []
        let command = PatchApplier.suggestedCommitCommand(
            message: commitMessage.nilIfBlank ?? defaultCommitMessage(for: patchStore.selectedProposal),
            changedPaths: paths,
            book: activeBook
        )
        FileHelpers.copyToPasteboard(command)
        statusMessage = "Copied git commit command to the clipboard."
        appendActivity("Copied git commit command")
    }

    private func commitAppliedChanges() async {
        guard activeBook.allowsPatchGitCommands else {
            statusMessage = PatchReviewError.shellCommandsDisabled.localizedDescription
            return
        }
        guard workflowPhase == .appliedToDisk, let context = pendingCommitContext else {
            statusMessage = "Apply to book first (Step 2), then commit."
            return
        }
        isRunningPatchCommand = true
        defer { isRunningPatchCommand = false }
        do {
            let message = commitMessage.nilIfBlank ?? "Apply BookLoop patch: \(context.rootStem)"
            let result = try await PatchApplier().gitCommit(message: message, changedPaths: context.changedFiles, book: activeBook)
            if result.exitCode == 0 {
                workflowPhase = .committed
                statusMessage = "Committed successfully."
                appendActivity("Committed: \(message)")
                appendActivity("git status: \(gitWorkingTree == "Working tree clean." ? "clean" : "updated")")
                pendingCommitContext = nil
            } else {
                statusMessage = "Commit failed (exit \(result.exitCode)).\n\(result.combinedOutput)"
                appendActivity("Commit failed for \(context.rootStem)")
            }
            await refreshGitPanel()
        } catch {
            statusMessage = error.localizedDescription
            appendActivity("Commit error: \(error.localizedDescription)")
        }
    }
}

struct RenderedPatchReviewView: View {
    let blocks: [RenderedPatchBlock]
    @Binding var decisions: [String: PatchBlockDecision]

    var body: some View {
        if blocks.isEmpty {
            EmptyStateView(title: "No Rendered Patch Blocks", message: "Place .patch or .diff files under bookloop/patches. BookLoop renders each diff hunk as a before/after HTML block for review.", systemImage: "doc.richtext")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(blocks) { block in
                        RenderedPatchBlockCard(block: block, decision: decisions[block.id] ?? .pending) { decision in
                            decisions[block.id] = decision
                        }
                    }
                }
                .padding()
            }
        }
    }
}

struct RenderedPatchBlockCard: View {
    let block: RenderedPatchBlock
    let decision: PatchBlockDecision
    let setDecision: (PatchBlockDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.title)
                        .font(.headline)
                    Text(block.hunkHeader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(decision.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.16))
                    .clipShape(Capsule())
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Before", systemImage: "minus.circle")
                        .foregroundStyle(.red)
                    HTMLStringView(html: block.beforeHTML)
                        .frame(minHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.22)))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("After", systemImage: "plus.circle")
                        .foregroundStyle(.green)
                    HTMLStringView(html: block.afterHTML)
                        .frame(minHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.22)))
                }
            }

            HStack {
                Button("Accept Block") { setDecision(.accepted) }
                    .buttonStyle(.borderedProminent)
                Button("Reject Block") { setDecision(.rejected) }
                Button("Reset") { setDecision(.pending) }
                Spacer()
                Text("Review decisions apply to this rendered block as a unit, not to individual diff lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(statusColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(statusColor.opacity(0.2)))
    }

    private var statusColor: Color {
        switch decision {
        case .pending: return .orange
        case .accepted: return .green
        case .rejected: return .red
        }
    }
}

struct HTMLStringView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        nsView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastHTML = ""
    }
}

struct BookSettingsTab: View {
    @EnvironmentObject private var library: BookLibraryStore
    let book: BookConfig
    @State private var draft: BookConfig

    init(book: BookConfig) {
        self.book = book
        _draft = State(initialValue: book)
    }

    var body: some View {
        BookSettingsForm(draft: $draft)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Infer Existing Paths") {
                        draft.inferExistingPaths()
                    }
                    Button("Fill Suggested Paths") {
                        draft.fillSuggestedPaths()
                    }
                    Spacer()
                    Button("Save Settings") {
                        draft.refreshProjectRootBookmark()
                        library.updateBook(draft)
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                }
                .padding()
                .background(.bar)
            }
            .onChange(of: book.id) {
                draft = book
            }
    }
}

struct BookSettingsView: View {
    @State private var draft: BookConfig
    let onSave: (BookConfig) -> Void
    let onCancel: () -> Void

    init(book: BookConfig, onSave: @escaping (BookConfig) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: book)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            BookSettingsForm(draft: $draft)
            Divider()
            HStack {
                Button("Infer Existing Paths") {
                    draft.inferExistingPaths()
                }
                Button("Fill Suggested Paths") {
                    draft.fillSuggestedPaths()
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    draft.refreshProjectRootBookmark()
                    onSave(draft)
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding()
        }
    }
}

struct BookSettingsForm: View {
    @Binding var draft: BookConfig
    @State private var migrationMessage: String?

    var body: some View {
        Form {
            Section("Book") {
                TextField("Display Name", text: $draft.displayName)
                PathField(title: "Project Root", path: $draft.projectRootPath, isDirectory: true)
                LabeledContent("Folder Access", value: draft.projectRootBookmark == nil ? "Bookmark will be captured on save" : "Security-scoped bookmark saved")
            }

            Section("Paths") {
                PathField(title: "nav.yaml", path: $draft.navConfigPath, isDirectory: false)
                if showsNavMigrationButton {
                    Button("Create nav.yaml from mkdocs.yml") {
                        migrateNavYAML()
                    }
                    if let migrationMessage {
                        Text(migrationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                PathField(title: "docs", path: $draft.docsPath, isDirectory: true)
                PathField(title: "reviews", path: $draft.reviewsPath, isDirectory: true)
                PathField(title: "review_items", path: $draft.reviewItemsPath, isDirectory: true)
                PathField(title: "cumulative_review.md", path: $draft.cumulativeReviewPath, isDirectory: false)
                PathField(title: "figures source", path: $draft.figuresSourcePath, isDirectory: true)
                PathField(title: "figures output", path: $draft.figuresOutputPath, isDirectory: true)
                PathField(title: "bookloop", path: $draft.bookloopPath, isDirectory: true)
                PathField(title: "style_guide.md", path: $draft.styleGuidePath, isDirectory: false)
                PathField(title: "figures.json", path: $draft.figuresRegistryPath, isDirectory: false)
            }

            Section("Commands") {
                OptionalTextField("Figure generation command", text: $draft.figureGenerationCommand)
                OptionalTextField("Validation command", text: $draft.validationCommand)
            }

            Section("Safety") {
                Toggle("Allow shell commands", isOn: $draft.allowShellCommands)
                Toggle("Allow figure regeneration", isOn: $draft.allowFigureRegeneration)
                Toggle("Allow patch apply", isOn: $draft.allowPatchApply)
            }

            Section("Notes") {
                TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.nilIfBlank }), axis: .vertical)
                    .lineLimit(4...8)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var showsNavMigrationButton: Bool {
        guard !draft.projectRootPath.isEmpty else { return false }
        let navPath = draft.navConfigPath ?? draft.suggestedPath("nav.yaml")
        let mkdocsPath = draft.suggestedPath("mkdocs.yml")
        return FileManager.default.fileExists(atPath: mkdocsPath)
            && !FileManager.default.fileExists(atPath: navPath)
    }

    private func migrateNavYAML() {
        let mkdocsPath = draft.suggestedPath("mkdocs.yml")
        let navPath = draft.navConfigPath ?? draft.suggestedPath("nav.yaml")
        do {
            let content = try NavConfigLoader.createNavYAML(fromLegacyMkDocsAt: mkdocsPath)
            try content.write(toFile: navPath, atomically: true, encoding: .utf8)
            draft.navConfigPath = navPath
            migrationMessage = "Created nav.yaml from mkdocs.yml."
        } catch {
            migrationMessage = error.localizedDescription
        }
    }
}

struct PathField: View {
    let title: String
    @Binding var path: String
    let isDirectory: Bool

    init(title: String, path: Binding<String>, isDirectory: Bool) {
        self.title = title
        _path = path
        self.isDirectory = isDirectory
    }

    init(title: String, path: Binding<String?>, isDirectory: Bool) {
        self.title = title
        _path = Binding(get: { path.wrappedValue ?? "" }, set: { path.wrappedValue = $0.nilIfBlank })
        self.isDirectory = isDirectory
    }

    var body: some View {
        HStack {
            TextField(title, text: $path)
            Button("Choose") {
                if isDirectory {
                    path = PathPicker.pickDirectory(title: title, initialPath: path) ?? path
                } else {
                    path = PathPicker.pickFile(title: title, initialPath: path) ?? path
                }
            }
        }
    }
}

struct OptionalTextField: View {
    let title: String
    @Binding var text: String?

    init(_ title: String, text: Binding<String?>) {
        self.title = title
        _text = text
    }

    var body: some View {
        TextField(title, text: Binding(get: { text ?? "" }, set: { text = $0.nilIfBlank }))
    }
}

private extension URL {
    var validFileURL: URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}
