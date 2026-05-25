import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore

    @StateObject private var projectStore = ProjectContentStore()
    @StateObject private var reviewStore = ReviewStore()
    @StateObject private var figureStore = FigureStore()
    @StateObject private var taskStore = TaskStore()
    @StateObject private var patchStore = PatchStore()
    @StateObject private var previewModel = BookPreviewModel()
    @StateObject private var chatModel = ChatPanelModel()

    @State private var workspaceMode: WorkspaceMode = .reading
    @State private var previewStatus: LocalAPIStatus = .unknown
    @State private var feedbackStatus: LocalAPIStatus = .unknown
    @State private var agentStatus: LocalAPIStatus = .unknown
    @State private var editingBook: BookConfig?
    @State private var showingAppSettings = false
    @State private var isSidebarVisible = true
    @State private var isChatVisible = true

    var body: some View {
        HSplitView {
            libraryColumn
            centerColumn
            chatColumn
        }
        .environmentObject(projectStore)
        .environmentObject(reviewStore)
        .environmentObject(figureStore)
        .environmentObject(taskStore)
        .environmentObject(patchStore)
        .environmentObject(previewModel)
        .sheet(item: $editingBook) { book in
            BookSettingsView(book: book) { updated in
                var updated = updated
                updated.refreshProjectRootBookmark()
                library.updateBook(updated)
                refreshProjectState()
                editingBook = nil
            } onCancel: {
                editingBook = nil
            }
            .frame(width: 760, height: 720)
        }
        .sheet(isPresented: $showingAppSettings) {
            AppSettingsView()
                .environmentObject(settingsStore)
                .frame(width: 480)
        }
        .onAppear {
            settingsStore.load()
            refreshProjectState()
        }
        .onChange(of: library.selectedBookID) {
            workspaceMode = .reading
            refreshProjectState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookLoopReloadPreview)) { _ in
            previewModel.reload()
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
                        await chatModel.checkHealth(baseURL: library.selectedBook?.feedbackAPIBaseURL ?? "")
                    }
                } label: {
                    Label("Check APIs", systemImage: "network")
                }
            }
        }
    }

    private var libraryColumn: some View {
        LibrarySidebarView(
            workspaceMode: $workspaceMode,
            showingAppSettings: $showingAppSettings,
            isSidebarVisible: $isSidebarVisible,
            previewStatus: previewStatus,
            feedbackStatus: feedbackStatus,
            agentStatus: agentStatus,
            chapterItems: effectiveChapterNav,
            currentURL: previewModel.currentURL ?? previewModel.previewURL,
            addBook: addBookFromPanel,
            editBook: beginEditingSelectedBook,
            deleteBook: deleteSelectedBook,
            onChapterSelect: { url in previewModel.navigate(to: url) }
        )
        .environmentObject(library)
        .environmentObject(projectStore)
        .environmentObject(reviewStore)
        .environmentObject(figureStore)
        .environmentObject(patchStore)
        .environmentObject(taskStore)
        .frame(width: isSidebarVisible ? 280 : 0)
        .clipped()
        .opacity(isSidebarVisible ? 1 : 0)
        .allowsHitTesting(isSidebarVisible)
    }

    @ViewBuilder
    private var centerColumn: some View {
        switch workspaceMode {
        case .reading:
            BookPreviewView(
                model: previewModel,
                chatModel: chatModel,
                isSidebarVisible: $isSidebarVisible,
                isChatVisible: $isChatVisible
            )
            .environmentObject(projectStore)
            .frame(minWidth: 500)
        case .tool(let tab):
            ToolWorkspaceView(
                workspaceMode: $workspaceMode,
                tool: tab,
                feedbackStatus: $feedbackStatus,
                agentStatus: $agentStatus,
                checkFeedbackAPI: checkFeedbackAPI,
                checkAgentHarness: checkAgentHarness
            )
            .environmentObject(library)
            .environmentObject(projectStore)
            .environmentObject(reviewStore)
            .environmentObject(figureStore)
            .environmentObject(taskStore)
            .environmentObject(patchStore)
            .environmentObject(previewModel)
            .frame(minWidth: 500)
        }
    }

    private var chatColumn: some View {
        ChatPanelView(
            model: chatModel,
            previewModel: previewModel,
            feedbackStatus: $feedbackStatus
        )
        .environmentObject(library)
        .environmentObject(settingsStore)
        .environmentObject(projectStore)
        .environmentObject(reviewStore)
        .frame(minWidth: isChatVisible ? 300 : 0, idealWidth: 360, maxWidth: isChatVisible ? 420 : 0)
        .clipped()
        .opacity(isChatVisible ? 1 : 0)
        .allowsHitTesting(isChatVisible)
    }

    private var effectiveChapterNav: [ChapterNavItem] {
        if !previewModel.chapterNav.isEmpty {
            return previewModel.chapterNav
        }
        return projectStore.chapters.map { chapter in
            ChapterNavItem(
                id: chapter.id,
                title: chapter.title,
                href: chapter.relativePath,
                children: []
            )
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
        let hasHarness = book?.agentHarnessBaseURL?.nilIfBlank != nil || book?.cursorCLIHarnessCommand?.nilIfBlank != nil
        agentStatus = hasHarness ? .unknown : .notConfigured

        guard let book else {
            previewModel.reset()
            chatModel.reset()
            return
        }
        previewModel.load(book: book)
        Task {
            await checkFeedbackAPI()
            await chatModel.checkHealth(baseURL: book.feedbackAPIBaseURL)
        }
    }

    private func addBookFromPanel() {
        guard let path = PathPicker.pickDirectory(title: "Choose MkDocs Project Root", initialPath: nil) else { return }
        var book = BookConfig.defaults(projectRootPath: path)
        book.displayName = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        book.refreshProjectRootBookmark()
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
        await chatModel.checkHealth(baseURL: book.feedbackAPIBaseURL)
    }

    private func checkAgentHarness() async {
        guard let book = library.selectedBook else {
            agentStatus = .notConfigured
            return
        }
        if let commandTemplate = book.cursorCLIHarnessCommand?.nilIfBlank {
            agentStatus = .checking
            agentStatus = AgentHarnessClient().checkCursorCLI(commandTemplate: commandTemplate, workingDirectory: book.projectRootPath)
            return
        }
        guard let baseURL = book.agentHarnessBaseURL?.nilIfBlank else {
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

struct ToolWorkspaceView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var previewModel: BookPreviewModel

    @Binding var workspaceMode: WorkspaceMode
    let tool: WorkspaceTab
    @Binding var feedbackStatus: LocalAPIStatus
    @Binding var agentStatus: LocalAPIStatus
    let checkFeedbackAPI: () async -> Void
    let checkAgentHarness: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    workspaceMode = .reading
                } label: {
                    Label("Back to Reading", systemImage: "book")
                }
                Text(tool.rawValue)
                    .font(.headline)
                Spacer()
            }
            .padding(10)

            Divider()

            if let book = library.selectedBook {
                toolContent(book: book)
            } else {
                EmptyStateView(
                    title: "No Books Configured",
                    message: "Add a local MkDocs project to use \(tool.rawValue).",
                    systemImage: "books.vertical"
                )
            }
        }
    }

    @ViewBuilder
    private func toolContent(book: BookConfig) -> some View {
        switch tool {
        case .preview:
            EmptyStateView(title: "Preview", message: "Use Back to Reading to return to the book preview.", systemImage: "safari")
        case .reviews:
            ReviewBrowserView(
                book: book,
                feedbackStatus: $feedbackStatus,
                checkFeedbackAPI: checkFeedbackAPI
            )
            .environmentObject(reviewStore)
            .environmentObject(taskStore)
            .environmentObject(projectStore)
            .environmentObject(previewModel)
        case .figures:
            FigureBrowserView(book: book)
                .environmentObject(figureStore)
                .environmentObject(taskStore)
        case .tasks:
            TaskBrowserView(
                book: book,
                agentStatus: $agentStatus,
                checkAgentHarness: checkAgentHarness
            )
            .environmentObject(taskStore)
            .environmentObject(reviewStore)
            .environmentObject(previewModel)
        case .patches:
            PatchReviewView(book: book)
                .environmentObject(patchStore)
        case .settings:
            BookSettingsTab(book: book)
                .environmentObject(library)
        }
    }
}
