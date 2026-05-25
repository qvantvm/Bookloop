import AppKit
import SwiftUI
import WebKit

struct FeedbackPanelView: View {
    @EnvironmentObject private var webModel: WebViewModel
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var projectStore: ProjectContentStore

    let book: BookConfig
    @Binding var feedbackStatus: LocalAPIStatus
    let checkFeedbackAPI: () async -> Void

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
            HStack {
                Text("Feedback")
                    .font(.headline)
                Spacer()
                StatusBadge(title: "API", status: feedbackStatus)
            }

            TextField("Chapter ID", text: $chapter)
            Text("Use the chapter id from frontmatter (for example home), not a docs/ path. The API saves to docs/{id}.md.")
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
                Button("Check API") {
                    Task { await checkFeedbackAPI() }
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
            let response = try await FeedbackAPIClient().submitReview(baseURL: book.feedbackAPIBaseURL, request: request)
            message = response.ok ? "Review created: \(response.file)" : "The feedback API did not confirm success."
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
        if feedbackStatus != .online { return "Feedback API must be online. Use Check API first." }
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
    @Binding var feedbackStatus: LocalAPIStatus
    let checkFeedbackAPI: () async -> Void
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
                    FeedbackPanelView(
                        book: book,
                        feedbackStatus: $feedbackStatus,
                        checkFeedbackAPI: checkFeedbackAPI
                    )
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

    var errorDescription: String? {
        switch self {
        case .noSelectedPatch: return "No patch proposal is selected."
        case .noAcceptedBlocks: return "Accept at least one rendered block before generating a reviewed patch."
        case .emptyReviewedPatch: return "The reviewed patch is empty."
        case .shellCommandsDisabled: return "Shell commands are disabled for this book. Enable Allow shell commands in Settings, or copy the git commit command and run it in Terminal."
        case .emptyCommitMessage: return "Enter a commit message before committing."
        }
    }
}

struct PatchReviewView: View {
    @EnvironmentObject private var patchStore: PatchStore
    let book: BookConfig
    @State private var applyOutput: String?
    @State private var saveOutput: String?
    @State private var preflightOutput: String?
    @State private var gitStatusOutput: String?
    @State private var isRunningPatchCommand = false
    @State private var confirmingApplyFullPatch = false
    @State private var confirmingApplyAcceptedBlocks = false
    @State private var confirmingCommit = false
    @State private var commitMessage = ""
    @State private var commitOutput: String?
    @State private var patchApplicabilityStatus: PatchApplicabilityStatus = .unknown
    @State private var isPatchListVisible = true
    @State private var isActionPanelVisible = true
    @State private var blockDecisions: [String: PatchBlockDecision] = [:]

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
                        book: book,
                        proposal: patchStore.selectedProposal,
                        blocks: renderedBlocks,
                        decisions: $blockDecisions,
                        applyOutput: $applyOutput,
                        saveOutput: $saveOutput,
                        preflightOutput: $preflightOutput,
                        gitStatusOutput: $gitStatusOutput,
                        patchApplicabilityStatus: patchApplicabilityStatus,
                        isRunningPatchCommand: isRunningPatchCommand,
                        confirmingApplyFullPatch: $confirmingApplyFullPatch,
                        confirmingApplyAcceptedBlocks: $confirmingApplyAcceptedBlocks,
                        confirmingCommit: $confirmingCommit,
                        commitMessage: $commitMessage,
                        commitOutput: $commitOutput,
                        copyAcceptedPatch: copyAcceptedPatch,
                        saveAcceptedPatch: saveAcceptedPatch,
                        checkOriginalPatch: checkOriginalPatch,
                        checkAcceptedBlocksPatch: checkAcceptedBlocksPatch,
                        refreshGitStatus: refreshGitStatus,
                        copyCommitCommand: copyCommitCommand,
                        commitAppliedChanges: { confirmingCommit = true }
                    )
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: patchStore.selectedProposalID) {
            blockDecisions.removeAll()
            applyOutput = nil
            saveOutput = nil
            preflightOutput = nil
            gitStatusOutput = nil
            commitOutput = nil
            commitMessage = defaultCommitMessage(for: patchStore.selectedProposal)
            patchApplicabilityStatus = .unknown
            Task { await checkSelectedPatchApplicability() }
        }
        .onAppear {
            if commitMessage.isEmpty {
                commitMessage = defaultCommitMessage(for: patchStore.selectedProposal)
            }
            Task { await checkSelectedPatchApplicability() }
        }
        .alert("Apply full patch?", isPresented: $confirmingApplyFullPatch) {
            Button("Cancel", role: .cancel) {}
            Button("Apply Full Patch", role: .destructive) {
                Task { await applyFullPatch() }
            }
        } message: {
            Text(fullPatchApplyConfirmationText)
        }
        .alert("Apply accepted rendered blocks?", isPresented: $confirmingApplyAcceptedBlocks) {
            Button("Cancel", role: .cancel) {}
            Button("Apply Accepted Blocks", role: .destructive) {
                Task { await applyAcceptedBlocks() }
            }
        } message: {
            Text("BookLoop will write a reviewed patch containing only accepted rendered blocks, run git apply --check, then apply it if the check succeeds.")
        }
        .alert("Commit applied changes?", isPresented: $confirmingCommit) {
            Button("Cancel", role: .cancel) {}
            Button("Commit", role: .destructive) {
                Task { await commitAppliedChanges() }
            }
        } message: {
            Text("BookLoop will run git add on the patch's changed files, then git commit with your message. Commit only after Apply Accepted Blocks or Apply Full Original Patch has succeeded.")
        }
    }

    private func defaultCommitMessage(for proposal: PatchProposal?) -> String {
        guard let proposal else { return "Apply BookLoop patch" }
        return "Apply BookLoop patch: \(proposal.rootStem)"
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
                    patchStore.refresh(book: book)
                }
                Button("Open Patch Folder") {
                    FileHelpers.openInFinder(path: book.patchDirectoryPath)
                }
            }
            .padding(8)

            List(patchStore.proposals, selection: $patchStore.selectedProposalID) { proposal in
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.displayTitle)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text("\(proposal.kindLabel) • \(proposal.changedFiles.count) changed file(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if proposal.title != proposal.displayTitle {
                        Text(proposal.title)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .tag(proposal.id)
            }

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

    private var fullPatchApplyConfirmationText: String {
        guard let proposal = patchStore.selectedProposal else {
            return "No patch selected."
        }
        return "BookLoop will run in \(book.projectRootPath):\n\ngit apply --check '\(proposal.filePath)'\ngit apply '\(proposal.filePath)'\n\nThis applies the full original patch, ignoring block-level Accept/Reject choices."
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
        try FileHelpers.ensureDirectory(book.patchDirectoryPath)
        let url = URL(fileURLWithPath: book.patchDirectoryPath, isDirectory: true)
            .appendingPathComponent(PatchParser().reviewedPatchFilename(for: proposal))
        try text.write(to: url, atomically: true, encoding: .utf8)
        saveOutput = "Saved reviewed patch: \(url.path)"
        return url.path
    }

    private func copyAcceptedPatch() {
        do {
            FileHelpers.copyToPasteboard(try reviewedPatchText())
            saveOutput = "Copied reviewed patch for \(acceptedBlockIDs.count) accepted block(s)."
        } catch {
            saveOutput = error.localizedDescription
        }
    }

    private func saveAcceptedPatch() {
        do {
            _ = try writeAcceptedPatchToDisk()
            patchStore.refresh(book: book)
        } catch {
            saveOutput = error.localizedDescription
        }
    }

    private func checkOriginalPatch() {
        guard let proposal = patchStore.selectedProposal else {
            preflightOutput = PatchReviewError.noSelectedPatch.localizedDescription
            return
        }
        Task { await runPatchPreflight(label: "Original patch", path: proposal.filePath) }
    }

    private func checkAcceptedBlocksPatch() {
        Task {
            do {
                let path = try writeAcceptedPatchToDisk()
                await runPatchPreflight(label: "Accepted-block patch", path: path)
                patchStore.refresh(book: book)
            } catch {
                preflightOutput = error.localizedDescription
            }
        }
    }

    private func refreshGitStatus() {
        Task {
            isRunningPatchCommand = true
            gitStatusOutput = "Running: git status --short"
            defer { isRunningPatchCommand = false }
            do {
                let result = try await PatchApplier().gitStatus(book: book)
                let body = result.combinedOutput.nilIfBlank ?? "Working tree clean."
                gitStatusOutput = "git status --short\nExit code: \(result.exitCode)\n\(body)"
            } catch {
                gitStatusOutput = error.localizedDescription
            }
        }
    }

    private func runPatchPreflight(label: String, path: String) async {
        isRunningPatchCommand = true
        preflightOutput = "Running: git apply --check \(path)"
        defer { isRunningPatchCommand = false }
        do {
            let status = try await PatchApplier().gitStatus(book: book)
            let check = try await PatchApplier().checkPatchFileAsync(path: path, book: book)
            let statusBody = status.combinedOutput.nilIfBlank ?? "Working tree clean."
            preflightOutput = "\(label) preflight\n\nGit status:\n\(statusBody)\n\nPatch check exit code: \(check.exitCode)\n\(check.combinedOutput)"
        } catch {
            preflightOutput = error.localizedDescription
        }
    }

    private func applyFullPatch() async {
        guard let proposal = patchStore.selectedProposal else { return }
        guard book.allowPatchApply else {
            applyOutput = "Patch apply is disabled for this book."
            return
        }
        isRunningPatchCommand = true
        applyOutput = "Applying full original patch..."
        defer { isRunningPatchCommand = false }
        do {
            let result = try await PatchApplier().applyAsync(patch: proposal, book: book)
            let status = try await PatchApplier().gitStatus(book: book)
            let statusBody = status.combinedOutput.nilIfBlank ?? "Working tree clean."
            if result.exitCode == 0 {
                archiveAppliedPatches(sourcePath: proposal.filePath, appliedReviewedPath: nil)
                applyOutput = "Full patch applied successfully.\nExit code: \(result.exitCode)\n\(result.combinedOutput)\n\nGit status after apply:\n\(statusBody)\n\nPatch archived. Next: Commit Applied Changes, or copy the git commit command."
            } else {
                applyOutput = "Full patch exit code: \(result.exitCode)\n\(result.combinedOutput)\n\nGit status:\n\(statusBody)\n\nIf this patch was already applied, the Before preview is a static snapshot — git apply cannot re-apply the same change."
            }
            refreshGitStatus()
            await checkSelectedPatchApplicability()
        } catch {
            applyOutput = error.localizedDescription
        }
    }

    private func applyAcceptedBlocks() async {
        guard book.allowPatchApply else {
            applyOutput = "Patch apply is disabled for this book."
            return
        }
        isRunningPatchCommand = true
        applyOutput = "Applying accepted rendered blocks..."
        defer { isRunningPatchCommand = false }
        do {
            guard let sourceProposal = patchStore.selectedProposal else { throw PatchReviewError.noSelectedPatch }
            let sourcePath = sourceProposal.filePath
            let reviewedPatchPath = try writeAcceptedPatchToDisk()
            let result = try await PatchApplier().applyPatchFileAsync(path: reviewedPatchPath, book: book)
            let status = try await PatchApplier().gitStatus(book: book)
            let statusBody = status.combinedOutput.nilIfBlank ?? "Working tree clean."
            if result.exitCode == 0 {
                archiveAppliedPatches(sourcePath: sourcePath, appliedReviewedPath: reviewedPatchPath)
                applyOutput = "Accepted blocks applied successfully.\nPatch: \(reviewedPatchPath)\nExit code: \(result.exitCode)\n\(result.combinedOutput)\n\nGit status after apply:\n\(statusBody)\n\nPatches archived. Next: Commit Applied Changes, or copy the git commit command."
            } else {
                applyOutput = "Accepted-block patch: \(reviewedPatchPath)\nExit code: \(result.exitCode)\n\(result.combinedOutput)\n\nGit status:\n\(statusBody)\n\nIf this patch was already applied, the Before preview is a static snapshot — git apply cannot re-apply the same change."
            }
            patchStore.refresh(book: book)
            refreshGitStatus()
            await checkSelectedPatchApplicability()
        } catch {
            applyOutput = error.localizedDescription
        }
    }

    private func archiveAppliedPatches(sourcePath: String, appliedReviewedPath: String?) {
        var archivedNames: [String] = []
        if let appliedReviewedPath {
            if let destination = try? PatchFileHelpers.archivePatch(at: appliedReviewedPath, patchDirectory: book.patchDirectoryPath) {
                archivedNames.append(URL(fileURLWithPath: destination).lastPathComponent)
            }
        }
        if sourcePath != appliedReviewedPath {
            if let destination = try? PatchFileHelpers.archivePatch(at: sourcePath, patchDirectory: book.patchDirectoryPath) {
                archivedNames.append(URL(fileURLWithPath: destination).lastPathComponent)
            }
        }
        patchStore.refresh(book: book)
        if !archivedNames.isEmpty {
            applyOutput = (applyOutput ?? "") + "\n\nArchived: \(archivedNames.joined(separator: ", "))"
        }
    }

    private func checkSelectedPatchApplicability() async {
        guard let proposal = patchStore.selectedProposal else {
            patchApplicabilityStatus = .unknown
            return
        }
        patchApplicabilityStatus = .checking
        do {
            let check = try await PatchApplier().checkPatchFileAsync(path: proposal.filePath, book: book)
            if check.exitCode == 0 {
                patchApplicabilityStatus = .applicable
            } else {
                let message = check.combinedOutput.nilIfBlank ?? "Patch check failed."
                if message.localizedCaseInsensitiveContains("already exists")
                    || message.localizedCaseInsensitiveContains("patch does not apply")
                    || message.localizedCaseInsensitiveContains("conflict") {
                    patchApplicabilityStatus = .alreadyApplied(message)
                } else {
                    patchApplicabilityStatus = .checkFailed(message)
                }
            }
        } catch {
            patchApplicabilityStatus = .checkFailed(error.localizedDescription)
        }
    }

    private func copyCommitCommand() {
        let paths = patchStore.selectedProposal?.changedFiles ?? []
        let command = PatchApplier.suggestedCommitCommand(
            message: commitMessage.nilIfBlank ?? defaultCommitMessage(for: patchStore.selectedProposal),
            changedPaths: paths,
            book: book
        )
        FileHelpers.copyToPasteboard(command)
        commitOutput = "Copied git commit command to the clipboard."
    }

    private func commitAppliedChanges() async {
        guard book.allowShellCommands else {
            commitOutput = PatchReviewError.shellCommandsDisabled.localizedDescription
            return
        }
        isRunningPatchCommand = true
        commitOutput = "Running git add and git commit..."
        defer { isRunningPatchCommand = false }
        do {
            let paths = patchStore.selectedProposal?.changedFiles ?? []
            let message = commitMessage.nilIfBlank ?? defaultCommitMessage(for: patchStore.selectedProposal)
            let result = try await PatchApplier().gitCommit(message: message, changedPaths: paths, book: book)
            let status = try await PatchApplier().gitStatus(book: book)
            let statusBody = status.combinedOutput.nilIfBlank ?? "Working tree clean."
            commitOutput = "git commit exit code: \(result.exitCode)\n\(result.combinedOutput)\n\nGit status after commit:\n\(statusBody)"
            refreshGitStatus()
        } catch {
            commitOutput = error.localizedDescription
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

struct PatchActionPanel: View {
    let book: BookConfig
    let proposal: PatchProposal?
    let blocks: [RenderedPatchBlock]
    @Binding var decisions: [String: PatchBlockDecision]
    @Binding var applyOutput: String?
    @Binding var saveOutput: String?
    @Binding var preflightOutput: String?
    @Binding var gitStatusOutput: String?
    let patchApplicabilityStatus: PatchApplicabilityStatus
    let isRunningPatchCommand: Bool
    @Binding var confirmingApplyFullPatch: Bool
    @Binding var confirmingApplyAcceptedBlocks: Bool
    @Binding var confirmingCommit: Bool
    @Binding var commitMessage: String
    @Binding var commitOutput: String?
    let copyAcceptedPatch: () -> Void
    let saveAcceptedPatch: () -> Void
    let checkOriginalPatch: () -> Void
    let checkAcceptedBlocksPatch: () -> Void
    let refreshGitStatus: () -> Void
    let copyCommitCommand: () -> Void
    let commitAppliedChanges: () -> Void
    @State private var confirmingArchive = false
    @State private var archiveOutput: String?

    private var acceptedCount: Int { decisions.values.filter { $0 == .accepted }.count }
    private var rejectedCount: Int { decisions.values.filter { $0 == .rejected }.count }
    private var pendingCount: Int { blocks.count - acceptedCount - rejectedCount }

    private var isAlreadyApplied: Bool {
        if case .alreadyApplied = patchApplicabilityStatus { return true }
        return false
    }

    @ViewBuilder
    private var patchApplicabilityLabel: some View {
        switch patchApplicabilityStatus {
        case .unknown:
            Text("Select a patch to check whether it can still be applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            Text("Checking git apply --check…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .applicable:
            Label("Ready to apply", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .alreadyApplied:
            Label("Likely already applied — re-applying the same patch will fail", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .checkFailed(let message):
            Label("Patch check failed", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rendered Patch Review")
                    .font(.headline)
                if let proposal {
                Text(proposal.displayTitle)
                    .fontWeight(.medium)
                Text(proposal.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let summary = proposal.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                GroupBox("Patch Status") {
                    VStack(alignment: .leading, spacing: 6) {
                        patchApplicabilityLabel
                        Text("Before/After previews are a static snapshot from the patch file. They still show TBD text even after a successful apply.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Block Decisions") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Accepted", value: "\(acceptedCount)")
                        LabeledContent("Rejected", value: "\(rejectedCount)")
                        LabeledContent("Pending", value: "\(pendingCount)")
                        HStack {
                            Button("Accept All") { setAll(.accepted) }
                            Button("Reject All") { setAll(.rejected) }
                            Button("Reset") { decisions.removeAll() }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Text("Changed Files")
                    .font(.headline)
                ForEach(proposal.changedFiles, id: \.self) { path in
                    Text(path)
                        .font(.caption)
                        .lineLimit(1)
                }

                Divider()

                Button("Refresh Git Status") { refreshGitStatus() }
                    .disabled(isRunningPatchCommand)
                Button("Check Accepted-Blocks Patch") { checkAcceptedBlocksPatch() }
                    .disabled(isRunningPatchCommand || acceptedCount == 0)
                Button("Copy Accepted-Blocks Patch") { copyAcceptedPatch() }
                    .disabled(acceptedCount == 0)
                Button("Save Accepted-Blocks Patch") { saveAcceptedPatch() }
                    .disabled(acceptedCount == 0)
                Button(isRunningPatchCommand ? "Patch Command Running..." : "Apply Accepted Blocks", role: .destructive) {
                    confirmingApplyAcceptedBlocks = true
                }
                .disabled(isRunningPatchCommand || !book.allowPatchApply || acceptedCount == 0 || isAlreadyApplied)

                GroupBox("Commit After Apply") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accept blocks → Apply Accepted Blocks writes files to disk. Then commit here (or copy the command for Terminal).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("Commit message", text: $commitMessage)
                        Button("Copy Git Commit Command") { copyCommitCommand() }
                        Button(isRunningPatchCommand ? "Patch Command Running..." : "Commit Applied Changes") {
                            commitAppliedChanges()
                        }
                        .disabled(isRunningPatchCommand || !book.allowShellCommands || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !book.allowShellCommands {
                            Text("Enable Allow shell commands in book Settings to commit from BookLoop.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                Button("Open Original Patch File") { FileHelpers.openInFinder(path: proposal.filePath) }
                Button("Copy Original Raw Patch") { FileHelpers.copyToPasteboard(proposal.rawPatch) }
                Button("Check Full Original Patch") { checkOriginalPatch() }
                    .disabled(isRunningPatchCommand)
                Button(isRunningPatchCommand ? "Patch Command Running..." : "Apply Full Original Patch", role: .destructive) {
                    confirmingApplyFullPatch = true
                }
                .disabled(isRunningPatchCommand || !book.allowPatchApply || isAlreadyApplied)
                Button("Reject / Archive Original Patch") {
                    confirmingArchive = true
                }

                if let gitStatusOutput {
                    Text(gitStatusOutput)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let preflightOutput {
                    Text(preflightOutput)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let saveOutput {
                    Text(saveOutput)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let archiveOutput {
                    Text(archiveOutput)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let applyOutput {
                    Text(applyOutput)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let commitOutput {
                    Text(commitOutput)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } else {
                Text("Select a patch proposal to review rendered before/after blocks.")
                    .foregroundStyle(.secondary)
            }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Archive original patch proposal?", isPresented: $confirmingArchive) {
            Button("Cancel", role: .cancel) {}
            Button("Archive") { archivePatch() }
        } message: {
            Text("BookLoop will move the selected original patch into bookloop/patches/archive. No book content is changed.")
        }
    }

    private func setAll(_ decision: PatchBlockDecision) {
        decisions = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, decision) })
    }

    private func archivePatch() {
        guard let proposal else { return }
        do {
            let destination = try PatchFileHelpers.archivePatch(at: proposal.filePath, patchDirectory: book.patchDirectoryPath)
            archiveOutput = "Archived to \(destination). Refresh patches to update the list."
        } catch {
            archiveOutput = error.localizedDescription
        }
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

    var body: some View {
        Form {
            Section("Book") {
                TextField("Display Name", text: $draft.displayName)
                PathField(title: "Project Root", path: $draft.projectRootPath, isDirectory: true)
                LabeledContent("Folder Access", value: draft.projectRootBookmark == nil ? "Bookmark will be captured on save" : "Security-scoped bookmark saved")
                TextField("Preview URL", text: $draft.previewURL)
                TextField("Feedback API Base URL", text: $draft.feedbackAPIBaseURL)
            }

            Section("Paths") {
                PathField(title: "mkdocs.yml", path: $draft.mkdocsConfigPath, isDirectory: false)
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
                OptionalTextField("MkDocs serve command", text: $draft.mkdocsServeCommand)
                OptionalTextField("Feedback API command", text: $draft.feedbackAPICommand)
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
