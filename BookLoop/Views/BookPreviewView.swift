import SwiftUI
import WebKit

struct BookPreviewView: View {
    @EnvironmentObject private var projectStore: ProjectContentStore
    @ObservedObject var model: BookPreviewModel
    @ObservedObject var chatModel: ChatPanelModel
    @Binding var isSidebarVisible: Bool
    @Binding var isChatVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            previewToolbar
            Divider()
            previewContent
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let previewURL = model.previewURL {
            WebView(
                url: previewURL,
                currentURL: $model.currentURL,
                canGoBack: $model.canGoBack,
                canGoForward: $model.canGoForward,
                reloadToken: model.reloadToken,
                goBackToken: model.goBackToken,
                goForwardToken: model.goForwardToken,
                navigateToken: model.navigateToken,
                navigateURL: model.navigateURL,
                onPageLoaded: { webView in
                    model.handlePageLoaded(webView)
                    Task { await refreshPageContext(from: webView) }
                }
            )
        } else if model.book != nil {
            ContentUnavailableView {
                Label("Invalid Preview URL", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check the book's preview URL in settings.")
            }
        } else {
            EmptyStateView(
                title: "Select a Book",
                message: "Choose a book from the sidebar or add one.",
                systemImage: "book.fill"
            )
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 8) {
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

            Button(action: model.goBack) { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button(action: model.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button(action: model.reload) { Image(systemName: "arrow.clockwise") }

            Text(model.currentURL?.absoluteString ?? model.previewURL?.absoluteString ?? "No URL loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Auto Refresh", isOn: $model.autoRefreshEnabled)
                .toggleStyle(.checkbox)

            if let chapter = currentChapter {
                Button("Open Chapter") {
                    FileHelpers.openFile(path: chapter.markdownPath)
                }
            }

            Button("Open in Browser", action: model.openInBrowser)
                .disabled(model.previewURL == nil)
        }
        .padding(10)
    }

    private var currentChapter: Chapter? {
        guard let detected = model.detectedChapterID?.nilIfBlank else { return nil }
        return projectStore.chapters.first { chapter in
            chapter.id == detected || chapter.urlSlug == detected || chapter.relativePath.replacingOccurrences(of: ".md", with: "") == detected
        }
    }

    private func refreshPageContext(from webView: WKWebView) async {
        await updatePageContext(from: webView)
        try? await Task.sleep(nanoseconds: 600_000_000)
        await updatePageContext(from: webView)
    }

    private func updatePageContext(from webView: WKWebView) async {
        let chapterID = await WebView.detectChapterID(in: webView)
        let pageTitle = await WebView.detectPageTitle(in: webView)
        let navItems = await WebView.extractChapterNav(in: webView)
        model.updateChapterNav(navItems)
        model.detectedChapterID = chapterID
        model.pageTitle = pageTitle
        chatModel.updatePageContext(chapterID: chapterID, pageTitle: pageTitle, pageURL: webView.url)
    }
}
