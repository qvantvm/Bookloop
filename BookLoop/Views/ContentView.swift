import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore

    @StateObject private var projectStore = ProjectContentStore()
    @StateObject private var bookProjectStore = BookProjectStore()
    @StateObject private var reviewStore = ReviewStore()
    @StateObject private var figureStore = FigureStore()
    @StateObject private var taskStore = TaskStore()
    @StateObject private var patchStore = PatchStore()
    @StateObject private var previewModel = BookPreviewModel()
    @StateObject private var chatModel = ChatPanelModel()
    @StateObject private var agentPanelModel = AgentPanelModel()
    @StateObject private var searchPanelModel = SearchPanelModel()

    @State private var workspaceMode: WorkspaceMode = .reading
    @State private var editingBook: BookConfig?
    @State private var showingAppSettings = false
    @State private var isSidebarVisible = true
    @State private var isChatVisible = true

    var body: some View {
        HSplitView {
            WorkspaceToolbarView(
                workspaceMode: $workspaceMode,
                showingAppSettings: $showingAppSettings
            )
            libraryColumn
            centerColumn
            chatColumn
        }
        .environmentObject(projectStore)
        .environmentObject(bookProjectStore)
        .environmentObject(reviewStore)
        .environmentObject(figureStore)
        .environmentObject(taskStore)
        .environmentObject(patchStore)
        .environmentObject(previewModel)
        .environmentObject(agentPanelModel)
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
                .frame(width: 520)
        }
        .onAppear {
            settingsStore.load()
            refreshProjectState()
        }
        .onChange(of: library.selectedBookID) {
            workspaceMode = .reading
            refreshProjectState()
        }
        .onChange(of: previewModel.detectedChapterID) { _, newValue in
            bookProjectStore.refresh(book: library.selectedBook, currentChapterID: newValue)
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
            }
        }
    }

    private var libraryColumn: some View {
        LibrarySidebarView(
            isSidebarVisible: $isSidebarVisible,
            previewStatus: previewModel.previewStatus,
            chapterItems: effectiveChapterNav,
            currentChapterPath: previewModel.currentChapterPath,
            addBook: addBookFromPanel,
            editBook: beginEditingSelectedBook,
            deleteBook: deleteSelectedBook,
            onChapterSelect: { path in previewModel.navigateToChapter(path) }
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
                isSidebarVisible: $isSidebarVisible,
                isChatVisible: $isChatVisible,
                showingAppSettings: $showingAppSettings
            )
            .environmentObject(library)
            .environmentObject(projectStore)
            .environmentObject(bookProjectStore)
            .environmentObject(reviewStore)
            .environmentObject(figureStore)
            .environmentObject(taskStore)
            .environmentObject(patchStore)
            .environmentObject(previewModel)
            .environmentObject(settingsStore)
            .environmentObject(agentPanelModel)
            .environmentObject(searchPanelModel)
            .frame(minWidth: 500)
        }
    }

    private var chatColumn: some View {
        ChatPanelView(
            model: chatModel,
            previewModel: previewModel
        )
        .environmentObject(library)
        .environmentObject(settingsStore)
        .environmentObject(projectStore)
        .environmentObject(reviewStore)
        .frame(width: isChatVisible ? 360 : 0)
        .clipped()
        .opacity(isChatVisible ? 1 : 0)
        .allowsHitTesting(isChatVisible)
    }

    private var effectiveChapterNav: [ChapterNavItem] {
        if !previewModel.chapterNav.isEmpty {
            return previewModel.chapterNav
        }
        if !projectStore.chapterNav.isEmpty {
            return projectStore.chapterNav
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
        bookProjectStore.refresh(book: book, currentChapterID: previewModel.detectedChapterID)

        guard let book else {
            previewModel.reset()
            chatModel.reset()
            return
        }

        if let navigation = projectStore.navigationResult {
            previewModel.setColorSchemeMode(settingsStore.previewColorScheme)
            previewModel.load(book: book, navigation: navigation)
        } else {
            previewModel.reset()
            previewModel.book = book
            previewModel.loadError = projectStore.errorMessage ?? "Could not load navigation."
            previewModel.previewStatus = PreviewHealthChecker().check(book: book)
        }
    }

    private func addBookFromPanel() {
        guard let path = PathPicker.pickDirectory(title: "Choose Book Project Root", initialPath: nil) else { return }
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
}

struct ToolWorkspaceView: View {
    @EnvironmentObject private var library: BookLibraryStore
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var bookProjectStore: BookProjectStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var figureStore: FigureStore
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var patchStore: PatchStore
    @EnvironmentObject private var previewModel: BookPreviewModel
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @EnvironmentObject private var agentPanelModel: AgentPanelModel
    @EnvironmentObject private var searchPanelModel: SearchPanelModel

    @Binding var workspaceMode: WorkspaceMode
    let tool: WorkspaceTab
    @Binding var isSidebarVisible: Bool
    @Binding var isChatVisible: Bool
    @Binding var showingAppSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    workspaceMode = .reading
                } label: {
                    Label("Back to Reading", systemImage: "book")
                }

                Button {
                    withAnimation { isSidebarVisible.toggle() }
                } label: {
                    Text(isSidebarVisible ? "Hide Panel" : "Show Panel")
                }
                .help(isSidebarVisible ? "Hide books and chapters panel" : "Show books and chapters panel")

                Button {
                    withAnimation { isChatVisible.toggle() }
                } label: {
                    Text(isChatVisible ? "Hide Chat" : "Show Chat")
                }
                .help(isChatVisible ? "Hide chapter chat panel" : "Show chapter chat panel")

                Text(tool.rawValue)
                    .font(.headline)
                Spacer()
            }
            .padding(10)

            Divider()

            if let book = library.selectedBook {
                toolContent(book: book)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    title: "No Books Configured",
                    message: "Add a local book project to use \(tool.rawValue).",
                    systemImage: "books.vertical"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func toolContent(book: BookConfig) -> some View {
        switch tool {
        case .preview:
            EmptyStateView(title: "Preview", message: "Use Back to Reading to return to the book preview.", systemImage: "safari")
        case .agent:
            AgentPanelView(
                projectStore: bookProjectStore,
                settingsStore: settingsStore,
                model: agentPanelModel,
                workspaceMode: $workspaceMode,
                showingAppSettings: $showingAppSettings
            )
                .environmentObject(library)
                .environmentObject(patchStore)
        case .search:
            SearchPanelView(
                projectStore: bookProjectStore,
                settingsStore: settingsStore,
                model: searchPanelModel,
                previewModel: previewModel,
                workspaceMode: $workspaceMode,
                showingAppSettings: $showingAppSettings
            )
        case .reviews:
            ReviewBrowserView(book: book)
                .environmentObject(reviewStore)
                .environmentObject(taskStore)
                .environmentObject(projectStore)
                .environmentObject(previewModel)
        case .figures:
            FigureBrowserView(book: book)
                .environmentObject(figureStore)
                .environmentObject(taskStore)
        case .tasks:
            TaskBrowserView(book: book)
                .environmentObject(taskStore)
                .environmentObject(reviewStore)
                .environmentObject(previewModel)
        case .patches:
            PatchReviewView(book: book)
                .environmentObject(patchStore)
                .environmentObject(library)
        case .settings:
            BookSettingsTab(book: book)
                .environmentObject(library)
        }
    }
}
