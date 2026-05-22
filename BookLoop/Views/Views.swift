import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @StateObject private var projectStore = ProjectContentStore()
    @StateObject private var reviewStore = ReviewStore()
    @StateObject private var figureStore = FigureStore()
    @StateObject private var taskStore = TaskStore()
    @StateObject private var patchStore = PatchStore()
    @StateObject private var webModel = WebViewModel()

    @State private var selectedTab: WorkspaceTab = .preview
    @State private var feedbackStatus: LocalAPIStatus = .unknown
    @State private var agentStatus: LocalAPIStatus = .unknown
    @State private var showingSettingsSheet = false
    @State private var editingBook: BookConfig?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedTab: $selectedTab,
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
                feedbackStatus: $feedbackStatus,
                agentStatus: $agentStatus,
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
        .onChange(of: library.selectedBookID) { _ in
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
    @Binding var feedbackStatus: LocalAPIStatus
    @Binding var agentStatus: LocalAPIStatus
    let checkFeedbackAPI: () async -> Void
    let checkAgentHarness: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let book = library.selectedBook {
                    DashboardView(book: book, feedbackStatus: feedbackStatus, agentStatus: agentStatus)
                        .environmentObject(reviewStore)
                        .environmentObject(figureStore)
                        .environmentObject(taskStore)
                        .environmentObject(patchStore)

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
    let feedbackStatus: LocalAPIStatus
    let agentStatus: LocalAPIStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dashboard")
                .font(.headline)
            StatusBadge(title: "MkDocs Preview", status: .unknown)
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
    let book: BookConfig

    private var previewURL: URL? {
        let value = book.previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: value).validFileURL
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
        .onChange(of: webModel.detectedChapterID) { newValue in
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

struct ReviewBrowserView: View {
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var webModel: WebViewModel

    let book: BookConfig
    @State private var selectedDetailID: String?

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
                Picker("Sort", selection: $reviewStore.sortMode) {
                    ForEach(ReviewStore.SortMode.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .padding(8)

            Divider()

            if reviewStore.items.isEmpty {
                EmptyStateView(title: "No Review Items", message: "BookLoop could not find Markdown reviews in reviews/review_items.", systemImage: "quote.bubble")
            } else {
                HSplitView {
                    List(reviewStore.filteredItems, selection: $reviewStore.selectedIDs) { item in
                        ReviewRow(item: item)
                            .tag(item.id)
                            .onTapGesture {
                                selectedDetailID = item.id
                            }
                    }
                    .frame(minWidth: 320)

                    ReviewDetailView(item: selectedReview)
                        .frame(minWidth: 320)
                }
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
                Button("Generate Figure Task") {
                    let selected = reviewStore.items.filter { reviewStore.selectedIDs.contains($0.id) }
                    taskStore.generate(book: book, mode: .proposeFigure, chapterID: selected.compactMap(\.chapter).first, reviewItems: selected, selectedText: webModel.selectedText)
                }
                .disabled(reviewStore.selectedIDs.isEmpty)
                Spacer()
                Text("\(reviewStore.filteredItems.count) shown")
                    .foregroundStyle(.secondary)
            }
            .padding(8)
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

struct FigureBrowserView: View {
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var taskStore: TaskStore
    let book: BookConfig
    @State private var selectedID: String?

    var body: some View {
        HSplitView {
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
                List(figureStore.figures, selection: $selectedID) { figure in
                    VStack(alignment: .leading) {
                        Text(figure.id)
                            .fontWeight(.medium)
                        Text("\(figure.status.rawValue) • \(figure.type.rawValue)")
                            .font(.caption)
                            .foregroundStyle(figure.status == .ok ? .secondary : .orange)
                    }
                    .tag(figure.id)
                }
            }
            .frame(minWidth: 300)

            FigureDetailView(figure: selectedFigure)
                .frame(minWidth: 440)
        }
        .onAppear {
            if selectedID == nil {
                selectedID = figureStore.figures.first?.id
            }
        }
    }

    private var selectedFigure: FigureItem? {
        figureStore.figures.first { $0.id == selectedID } ?? figureStore.figures.first
    }
}

struct FigureDetailView: View {
    let figure: FigureItem?

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
                    }
                }
                .padding()
            }
        } else {
            EmptyStateView(title: "No Figures", message: "BookLoop scans Markdown image references and docs/assets/figures.", systemImage: "photo")
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
    }
}

struct PatchReviewView: View {
    @EnvironmentObject private var patchStore: PatchStore
    let book: BookConfig
    @State private var applyOutput: String?
    @State private var confirmingApply = false

    var body: some View {
        HSplitView {
            VStack {
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
            }
            .frame(minWidth: 260)

            DiffViewer(proposal: patchStore.selectedProposal)
                .frame(minWidth: 520)

            PatchActionPanel(book: book, proposal: patchStore.selectedProposal, applyOutput: $applyOutput, confirmingApply: $confirmingApply)
                .frame(minWidth: 260)
        }
        .alert("Apply patch?", isPresented: $confirmingApply) {
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                applySelectedPatch()
            }
        } message: {
            Text("BookLoop will run git apply --check first, then git apply if the check succeeds. It will not force apply.")
        }
    }

    private func applySelectedPatch() {
        guard let proposal = patchStore.selectedProposal else { return }
        guard book.allowPatchApply else {
            applyOutput = "Patch apply is disabled for this book."
            return
        }
        do {
            let result = try PatchApplier().apply(patch: proposal, book: book)
            applyOutput = "Exit code: \(result.exitCode)\n\(result.combinedOutput)"
        } catch {
            applyOutput = error.localizedDescription
        }
    }
}

struct DiffViewer: View {
    let proposal: PatchProposal?

    var body: some View {
        if let proposal {
            let files = PatchParser().parseDiff(proposal.rawPatch)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        Text(file.newPath)
                            .font(.headline)
                            .padding(.top, 10)
                        ForEach(file.hunks) { hunk in
                            ForEach(hunk.lines) { line in
                                Text(line.content)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(background(for: line.kind))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding()
            }
        } else {
            EmptyStateView(title: "No Patch Selected", message: "Place .patch or .diff files under bookloop/patches to review them.", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: return .green.opacity(0.14)
        case .deletion: return .red.opacity(0.14)
        case .header: return .blue.opacity(0.12)
        case .context: return .clear
        }
    }
}

struct PatchActionPanel: View {
    let book: BookConfig
    let proposal: PatchProposal?
    @Binding var applyOutput: String?
    @Binding var confirmingApply: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Patch Actions")
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
                Text("Changed Files")
                    .font(.headline)
                ForEach(proposal.changedFiles, id: \.self) { path in
                    Text(path)
                        .font(.caption)
                        .lineLimit(1)
                }
                Button("Open Patch File") { FileHelpers.openInFinder(path: proposal.filePath) }
                Button("Copy Raw Patch") { FileHelpers.copyToPasteboard(proposal.rawPatch) }
                Button("Copy git apply Command") {
                    FileHelpers.copyToPasteboard("git apply \(proposal.filePath)")
                }
                Button("Apply Patch", role: .destructive) {
                    confirmingApply = true
                }
                .disabled(!book.allowPatchApply)
                Button("Reject / Archive") {
                    FileHelpers.openInFinder(path: proposal.filePath)
                }
                if let applyOutput {
                    Text(applyOutput)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } else {
                Text("Select a patch proposal to inspect and apply it safely.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
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
                    Button("Infer Paths from Project Root") {
                        draft.inferExistingPaths()
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
            .onChange(of: book.id) { _ in
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
                Button("Infer Paths from Project Root") {
                    draft.inferExistingPaths()
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
