import AppKit
import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @StateObject private var projectStore = ProjectContentStore()
    @StateObject private var reviewStore = ReviewStore()
    @StateObject private var figureStore = FigureStore()
    @StateObject private var taskStore = TaskStore()
    @StateObject private var patchStore = PatchStore()
    @StateObject private var webModel = WebViewModel()

    @State private var selectedTab: WorkspaceTab = .preview
    @State private var previewStatus: LocalAPIStatus = .unknown
    @State private var feedbackStatus: LocalAPIStatus = .unknown
    @State private var agentStatus: LocalAPIStatus = .unknown
    @State private var editingBook: BookConfig?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedTab: $selectedTab,
                previewStatus: previewStatus,
                feedbackStatus: feedbackStatus,
                agentStatus: agentStatus,
                addBook: addBookFromPanel,
                editBook: beginEditingSelectedBook,
                deleteBook: deleteSelectedBook
            )
            .environmentObject(library)
            .environmentObject(projectStore)
            .environmentObject(reviewStore)
            .environmentObject(figureStore)
            .environmentObject(patchStore)
            .environmentObject(taskStore)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            WorkspaceView(
                selectedTab: $selectedTab,
                feedbackStatus: $feedbackStatus,
                agentStatus: $agentStatus
            )
            .environmentObject(library)
            .environmentObject(projectStore)
            .environmentObject(reviewStore)
            .environmentObject(figureStore)
            .environmentObject(taskStore)
            .environmentObject(patchStore)
            .environmentObject(webModel)
            .navigationSplitViewColumnWidth(min: 620, ideal: 820)
        } detail: {
            InspectorView(
                selectedTab: $selectedTab,
                previewStatus: $previewStatus,
                feedbackStatus: $feedbackStatus,
                agentStatus: $agentStatus,
                checkPreview: checkPreview,
                checkFeedbackAPI: checkFeedbackAPI,
                checkAgentHarness: checkAgentHarness
            )
            .environmentObject(library)
            .environmentObject(reviewStore)
            .environmentObject(figureStore)
            .environmentObject(taskStore)
            .environmentObject(patchStore)
            .environmentObject(webModel)
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        }
        .sheet(item: $editingBook) { book in
            BookSettingsView(book: book) { updated in
                library.updateBook(updated)
                refreshProjectState()
                editingBook = nil
            } onCancel: {
                editingBook = nil
            }
            .frame(width: 760, height: 720)
        }
        .onAppear {
            refreshProjectState()
        }
        .onChange(of: library.selectedBookID) {
            refreshProjectState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookLoopReloadPreview)) { _ in
            webModel.reload()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    refreshProjectState()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    Task {
                        await checkPreview()
                        await checkFeedbackAPI()
                        await checkAgentHarness()
                    }
                } label: {
                    Label("Check APIs", systemImage: "network")
                }
            }
        }
    }

    private func refreshProjectState() {
        let book = library.selectedBook
        projectStore.refresh(book: book)
        reviewStore.refresh(book: book)
        figureStore.refresh(book: book)
        taskStore.refresh(book: book)
        patchStore.refresh(book: book)
        previewStatus = .unknown
        feedbackStatus = .unknown
        agentStatus = book?.agentHarnessBaseURL?.nilIfBlank == nil ? .notConfigured : .unknown
    }

    private func addBookFromPanel() {
        guard let path = PathPicker.pickDirectory(title: "Choose MkDocs Project Root", initialPath: nil) else { return }
        var book = BookConfig.defaults(projectRootPath: path)
        book.displayName = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        library.addBook(book)
        refreshProjectState()
    }

    private func beginEditingSelectedBook() {
        editingBook = library.selectedBook
    }

    private func deleteSelectedBook() {
        guard let book = library.selectedBook else { return }
        library.deleteBook(book)
        refreshProjectState()
    }

    private func checkPreview() async {
        guard let book = library.selectedBook else {
            previewStatus = .notConfigured
            return
        }
        previewStatus = .checking
        previewStatus = await PreviewHealthChecker().check(previewURL: book.previewURL)
    }

    private func checkFeedbackAPI() async {
        guard let book = library.selectedBook else {
            feedbackStatus = .notConfigured
            return
        }
        feedbackStatus = .checking
        do {
            _ = try await FeedbackAPIClient().checkHealth(baseURL: book.feedbackAPIBaseURL)
            feedbackStatus = .online
        } catch {
            feedbackStatus = .offline(error.localizedDescription)
        }
    }

    private func checkAgentHarness() async {
        guard let baseURL = library.selectedBook?.agentHarnessBaseURL?.nilIfBlank else {
            agentStatus = .notConfigured
            return
        }
        agentStatus = .checking
        do {
            _ = try await AgentHarnessClient().checkHealth(baseURL: baseURL)
            agentStatus = .online
        } catch {
            agentStatus = .offline(error.localizedDescription)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var taskStore: TaskStore

    @Binding var selectedTab: WorkspaceTab
    let previewStatus: LocalAPIStatus
    let feedbackStatus: LocalAPIStatus
    let agentStatus: LocalAPIStatus
    let addBook: () -> Void
    let editBook: () -> Void
    let deleteBook: () -> Void

    var body: some View {
        List(selection: $library.selectedBookID) {
            Section("Books") {
                ForEach(library.books) { book in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.displayName)
                            .fontWeight(.medium)
                        Text(book.projectRootPath.isEmpty ? "No project root" : book.projectRootPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(book.id)
                }
            }

            if library.selectedBook != nil {
                Section("Workspace") {
                    ForEach(WorkspaceTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Label(tab.rawValue, systemImage: icon(for: tab))
                        }
                    }
                }

                Section("Status") {
                    StatusBadge(title: "MkDocs Preview", status: previewStatus)
                    StatusBadge(title: "Feedback API", status: feedbackStatus)
                    StatusBadge(title: "Agent", status: agentStatus)
                    Label("\(reviewStore.openCount) open reviews", systemImage: "text.badge.checkmark")
                    Label("\(figureStore.staleCount) stale figures", systemImage: "photo.on.rectangle")
                    Label("\(patchStore.proposals.count) pending patches", systemImage: "square.and.pencil")
                    Label("\(taskStore.taskFiles.count) tasks", systemImage: "doc.text")
                }

                Section("Chapters") {
                    ForEach(projectStore.chapters.prefix(12)) { chapter in
                        Text(chapter.title)
                            .lineLimit(1)
                    }
                    if projectStore.chapters.count > 12 {
                        Text("\(projectStore.chapters.count - 12) more...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: addBook) {
                    Label("Add", systemImage: "plus")
                }
                Button(action: editBook) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .disabled(library.selectedBook == nil)
                Button(role: .destructive, action: deleteBook) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(library.selectedBook == nil)
            }
            .labelStyle(.iconOnly)
            .padding(8)
        }
    }

    private func icon(for tab: WorkspaceTab) -> String {
        switch tab {
        case .preview: return "safari"
        case .reviews: return "quote.bubble"
        case .figures: return "photo"
        case .tasks: return "checklist"
        case .patches: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var webModel: WebViewModel

    @Binding var selectedTab: WorkspaceTab
    @Binding var feedbackStatus: LocalAPIStatus
    @Binding var agentStatus: LocalAPIStatus

    var body: some View {
        if let book = library.selectedBook {
            TabView(selection: $selectedTab) {
                PreviewView(book: book)
                    .environmentObject(webModel)
                    .tabItem { Text("Preview") }
                    .tag(WorkspaceTab.preview)
                ReviewBrowserView(book: book)
                    .environmentObject(reviewStore)
                    .environmentObject(taskStore)
                    .environmentObject(webModel)
                    .tabItem { Text("Reviews") }
                    .tag(WorkspaceTab.reviews)
                FigureBrowserView(book: book)
                    .environmentObject(figureStore)
                    .environmentObject(taskStore)
                    .tabItem { Text("Figures") }
                    .tag(WorkspaceTab.figures)
                TaskBrowserView(book: book)
                    .environmentObject(taskStore)
                    .environmentObject(reviewStore)
                    .environmentObject(webModel)
                    .tabItem { Text("Tasks") }
                    .tag(WorkspaceTab.tasks)
                PatchReviewView(book: book)
                    .environmentObject(patchStore)
                    .tabItem { Text("Patches") }
                    .tag(WorkspaceTab.patches)
                BookSettingsTab(book: book)
                    .environmentObject(library)
                    .tabItem { Text("Settings") }
                    .tag(WorkspaceTab.settings)
            }
            .padding(.top, 8)
        } else {
            EmptyStateView(
                title: "No Books Configured",
                message: "Add a local MkDocs project to start reading, reviewing, and generating revision tasks.",
                systemImage: "books.vertical"
            )
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var webModel: WebViewModel

    @Binding var selectedTab: WorkspaceTab
    @Binding var previewStatus: LocalAPIStatus
    @Binding var feedbackStatus: LocalAPIStatus
    @Binding var agentStatus: LocalAPIStatus
    let checkPreview: () async -> Void
    let checkFeedbackAPI: () async -> Void
    let checkAgentHarness: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let book = library.selectedBook {
                    DashboardView(book: book, previewStatus: previewStatus, feedbackStatus: feedbackStatus, agentStatus: agentStatus)
                        .environmentObject(reviewStore)
                        .environmentObject(figureStore)
                        .environmentObject(taskStore)
                        .environmentObject(patchStore)

                    Button("Check MkDocs Preview") {
                        Task { await checkPreview() }
                    }

                    Divider()

                    FeedbackPanelView(
                        book: book,
                        feedbackStatus: $feedbackStatus,
                        checkFeedbackAPI: checkFeedbackAPI
                    )
                    .environmentObject(webModel)
                    .environmentObject(reviewStore)

                    Divider()

                    AgentHarnessPanel(book: book, agentStatus: $agentStatus, checkAgentHarness: checkAgentHarness)
                        .environmentObject(reviewStore)
                } else {
                    EmptyStateView(title: "Inspector", message: "Select or add a book to see workflow controls.", systemImage: "sidebar.right")
                }
            }
            .padding()
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var patchStore: PatchStore

    let book: BookConfig
    let previewStatus: LocalAPIStatus
    let feedbackStatus: LocalAPIStatus
    let agentStatus: LocalAPIStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dashboard")
                .font(.headline)
            StatusBadge(title: "MkDocs Preview", status: previewStatus)
            StatusBadge(title: "Feedback API", status: feedbackStatus)
            StatusBadge(title: "Agent Harness", status: agentStatus)
            LabeledContent("Review Items", value: "\(reviewStore.openCount) open")
            LabeledContent("Critical Reviews", value: "\(reviewStore.criticalCount)")
            LabeledContent("Figures", value: "\(figureStore.okCount) ok, \(figureStore.staleCount) stale, \(figureStore.missingCount) missing")
            LabeledContent("Patches", value: "\(patchStore.proposals.count) pending")
            LabeledContent("Tasks", value: "\(taskStore.taskFiles.count) generated")
        }
    }
}

struct PreviewView: View {
    @EnvironmentObject private var webModel: WebViewModel
    @EnvironmentObject private var projectStore: ProjectContentStore
    let book: BookConfig

    private var previewURL: URL? {
        let value = book.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: value).validFileURL
    }

    private var currentChapter: Chapter? {
        guard let detected = webModel.detectedChapterID?.nilIfBlank else { return nil }
        return projectStore.chapters.first { chapter in
            chapter.id == detected || chapter.urlSlug == detected || chapter.relativePath.replacingOccurrences(of: ".md", with: "") == detected
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { webModel.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!webModel.canGoBack)
                Button { webModel.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!webModel.canGoForward)
                Button { webModel.reload() } label: { Image(systemName: "arrow.clockwise") }
                Text(webModel.currentURL?.absoluteString ?? book.previewURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let chapter = currentChapter {
                    Button("Open Chapter") {
                        FileHelpers.openFile(path: chapter.markdownPath)
                    }
                    Button("Show Chapter") {
                        FileHelpers.openInFinder(path: chapter.markdownPath)
                    }
                }
                if let url = webModel.currentURL ?? URL(string: book.previewURL) {
                    Button("Open in Browser") {
                        FileHelpers.openExternal(url: url)
                    }
                }
            }
            .padding(8)

            Divider()

            if let url = previewURL {
                WebView(url: url, model: webModel)
            } else {
                EmptyStateView(title: "Invalid Preview URL", message: "Check the selected book's preview URL in Settings.", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

struct FeedbackPanelView: View {
    @EnvironmentObject private var webModel: WebViewModel
    @EnvironmentObject private var reviewStore: ReviewStore

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
            if chapter.isEmpty {
                chapter = webModel.detectedChapterID ?? ""
            }
        }
        .onChange(of: webModel.detectedChapterID) { _, newValue in
            if chapter.isEmpty, let newValue {
                chapter = newValue
            }
        }
    }

    private func appendSelectedText() async {
        await webModel.captureSelectedText()
        guard let selected = webModel.selectedText?.nilIfBlank else { return }
        let block = "\n\nSelected passage:\n\n" + selected.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
        bodyText += block
    }

    private func submitReview() async {
        let validation = validate()
        guard validation == nil else {
            message = validation
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let request = ReviewRequest(
                chapter: chapter.trimmingCharacters(in: .whitespacesAndNewlines),
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
        return nil
    }

    private func clearAll() {
        chapter = webModel.detectedChapterID ?? ""
        type = .confusion
        severity = .medium
        section = ""
        title = ""
        bodyText = ""
        suggestedFix = ""
        message = nil
    }
}

struct AgentHarnessPanel: View {
    @EnvironmentObject private var reviewStore: ReviewStore
    let book: BookConfig
    @Binding var agentStatus: LocalAPIStatus
    let checkAgentHarness: () async -> Void
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Harness")
                    .font(.headline)
                Spacer()
                StatusBadge(title: "Harness", status: agentStatus)
            }
            Text("Task-file generation is the default. Harness submission is optional and local.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Check Harness") {
                    Task { await checkAgentHarness() }
                }
                Button("Send Task to Harness") {
                    Task { await sendTask() }
                }
                .disabled(agentStatus != .online)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
    }

    private func sendTask() async {
        guard let baseURL = book.agentHarnessBaseURL?.nilIfBlank else {
            message = "Agent harness is not configured."
            return
        }
        let selected = reviewStore.items.filter { reviewStore.selectedIDs.contains($0.id) }
        let request = AgentTaskRequest(
            bookRoot: book.projectRootPath,
            chapterID: selected.compactMap(\.chapter).first,
            reviewItemIDs: selected.map(\.id),
            mode: RevisionTaskMode.fixReviews.rawValue,
            constraints: ["Return a unified diff.", "Do not apply changes directly."]
        )
        do {
            let response = try await AgentHarnessClient().submitFixReviewsTask(baseURL: baseURL, request: request)
            message = "Harness task \(response.taskID): \(response.status)"
        } catch {
            message = error.localizedDescription
        }
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

    let book: BookConfig
    @State private var selectedDetailID: String?
    @State private var grouping: ReviewGrouping = .chapter

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
            }
            .padding(8)

            Divider()

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
                        Button("Regenerate") {
                            confirmingRegeneration = true
                        }
                        .disabled(!book.allowShellCommands || !book.allowFigureRegeneration || regenerationCommand(for: figure) == nil)
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
                Button("Run") { runRegeneration(for: figure) }
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

    private func runRegeneration(for figure: FigureItem) {
        guard book.allowShellCommands, book.allowFigureRegeneration, let command = regenerationCommand(for: figure) else {
            regenerationOutput = "Figure regeneration is disabled or no command is configured."
            return
        }
        do {
            let result = try ShellCommandRunner().run(command: command, workingDirectory: book.projectRootPath)
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
                    Button("Run Validation Command") {
                        confirmingValidation = true
                    }
                    .disabled(!book.allowShellCommands || book.validationCommand?.nilIfBlank == nil)
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
            Button("Run") { runValidationCommand() }
        } message: {
            Text("BookLoop will run this command in the book root: \(book.validationCommand ?? "")")
        }
    }

    private func runValidationCommand() {
        guard book.allowShellCommands, let command = book.validationCommand?.nilIfBlank else {
            validationOutput = "Shell commands are disabled or no validation command is configured."
            return
        }
        do {
            let result = try ShellCommandRunner().run(command: command, workingDirectory: book.projectRootPath)
            validationOutput = "Command: \(command)\nExit code: \(result.exitCode)\n\(result.combinedOutput)"
        } catch {
            validationOutput = error.localizedDescription
        }
    }
}

enum PatchReviewError: LocalizedError {
    case noSelectedPatch
    case noAcceptedBlocks
    case emptyReviewedPatch

    var errorDescription: String? {
        switch self {
        case .noSelectedPatch: return "No patch proposal is selected."
        case .noAcceptedBlocks: return "Accept at least one rendered block before generating a reviewed patch."
        case .emptyReviewedPatch: return "The reviewed patch is empty."
        }
    }
}

struct PatchReviewView: View {
    @EnvironmentObject private var patchStore: PatchStore
    let book: BookConfig
    @State private var applyOutput: String?
    @State private var saveOutput: String?
    @State private var confirmingApplyFullPatch = false
    @State private var confirmingApplyAcceptedBlocks = false
    @State private var blockDecisions: [String: PatchBlockDecision] = [:]

    private var renderedBlocks: [RenderedPatchBlock] {
        guard let proposal = patchStore.selectedProposal else { return [] }
        return PatchParser().renderedBlocks(from: proposal)
    }

    private var acceptedBlockIDs: Set<String> {
        Set(blockDecisions.filter { $0.value == .accepted }.map { $0.key })
    }

    var body: some View {
        HSplitView {
            patchListPane
                .frame(minWidth: 260)

            RenderedPatchReviewView(blocks: renderedBlocks, decisions: $blockDecisions)
                .frame(minWidth: 620)

            PatchActionPanel(
                book: book,
                proposal: patchStore.selectedProposal,
                blocks: renderedBlocks,
                decisions: $blockDecisions,
                applyOutput: $applyOutput,
                saveOutput: $saveOutput,
                confirmingApplyFullPatch: $confirmingApplyFullPatch,
                confirmingApplyAcceptedBlocks: $confirmingApplyAcceptedBlocks,
                copyAcceptedPatch: copyAcceptedPatch,
                saveAcceptedPatch: saveAcceptedPatch
            )
            .frame(minWidth: 280)
        }
        .onChange(of: patchStore.selectedProposalID) {
            blockDecisions.removeAll()
            applyOutput = nil
            saveOutput = nil
        }
        .alert("Apply full patch?", isPresented: $confirmingApplyFullPatch) {
            Button("Cancel", role: .cancel) {}
            Button("Apply Full Patch", role: .destructive) {
                applyFullPatch()
            }
        } message: {
            Text(fullPatchApplyConfirmationText)
        }
        .alert("Apply accepted rendered blocks?", isPresented: $confirmingApplyAcceptedBlocks) {
            Button("Cancel", role: .cancel) {}
            Button("Apply Accepted Blocks", role: .destructive) {
                applyAcceptedBlocks()
            }
        } message: {
            Text("BookLoop will write a reviewed patch containing only accepted rendered blocks, run git apply --check, then apply it if the check succeeds.")
        }
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
                VStack(alignment: .leading) {
                    Text(proposal.title)
                        .fontWeight(.medium)
                    Text("\(proposal.changedFiles.count) changed file(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private func applyFullPatch() {
        guard let proposal = patchStore.selectedProposal else { return }
        guard book.allowPatchApply else {
            applyOutput = "Patch apply is disabled for this book."
            return
        }
        do {
            let result = try PatchApplier().apply(patch: proposal, book: book)
            applyOutput = "Full patch exit code: \(result.exitCode)\n\(result.combinedOutput)"
        } catch {
            applyOutput = error.localizedDescription
        }
    }

    private func applyAcceptedBlocks() {
        guard book.allowPatchApply else {
            applyOutput = "Patch apply is disabled for this book."
            return
        }
        do {
            let reviewedPatchPath = try writeAcceptedPatchToDisk()
            let result = try PatchApplier().applyPatchFile(path: reviewedPatchPath, book: book)
            applyOutput = "Accepted-block patch: \(reviewedPatchPath)\nExit code: \(result.exitCode)\n\(result.combinedOutput)"
            patchStore.refresh(book: book)
        } catch {
            applyOutput = error.localizedDescription
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
    @Binding var confirmingApplyFullPatch: Bool
    @Binding var confirmingApplyAcceptedBlocks: Bool
    let copyAcceptedPatch: () -> Void
    let saveAcceptedPatch: () -> Void
    @State private var confirmingArchive = false
    @State private var archiveOutput: String?

    private var acceptedCount: Int { decisions.values.filter { $0 == .accepted }.count }
    private var rejectedCount: Int { decisions.values.filter { $0 == .rejected }.count }
    private var pendingCount: Int { blocks.count - acceptedCount - rejectedCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rendered Patch Review")
                .font(.headline)
            if let proposal {
                Text(proposal.title)
                    .fontWeight(.medium)
                if let summary = proposal.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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

                Button("Copy Accepted-Blocks Patch") { copyAcceptedPatch() }
                    .disabled(acceptedCount == 0)
                Button("Save Accepted-Blocks Patch") { saveAcceptedPatch() }
                    .disabled(acceptedCount == 0)
                Button("Apply Accepted Blocks", role: .destructive) {
                    confirmingApplyAcceptedBlocks = true
                }
                .disabled(!book.allowPatchApply || acceptedCount == 0)

                Divider()

                Button("Open Original Patch File") { FileHelpers.openInFinder(path: proposal.filePath) }
                Button("Copy Original Raw Patch") { FileHelpers.copyToPasteboard(proposal.rawPatch) }
                Button("Apply Full Original Patch", role: .destructive) {
                    confirmingApplyFullPatch = true
                }
                .disabled(!book.allowPatchApply)
                Button("Reject / Archive Original Patch") {
                    confirmingArchive = true
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
            } else {
                Text("Select a patch proposal to review rendered before/after blocks.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
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
            let source = URL(fileURLWithPath: proposal.filePath)
            let archiveDirectory = URL(fileURLWithPath: book.patchDirectoryPath, isDirectory: true).appendingPathComponent("archive", isDirectory: true)
            try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true, attributes: nil)
            var destination = archiveDirectory.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let timestamp = DateFormatting.taskFilename.string(from: Date())
                destination = archiveDirectory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(timestamp).\(source.pathExtension)")
            }
            try FileManager.default.moveItem(at: source, to: destination)
            archiveOutput = "Archived to \(destination.path). Refresh patches to update the list."
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
                TextField("Preview URL", text: $draft.previewURL)
                TextField("Feedback API Base URL", text: $draft.feedbackAPIBaseURL)
                OptionalTextField("Agent Harness Base URL", text: $draft.agentHarnessBaseURL)
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
