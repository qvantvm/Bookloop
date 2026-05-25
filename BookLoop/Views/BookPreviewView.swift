import SwiftUI
import WebKit

struct BookPreviewView: View {
    @EnvironmentObject private var projectStore: ProjectContentStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @ObservedObject var model: BookPreviewModel
    @ObservedObject var chatModel: ChatPanelModel
    @Binding var isSidebarVisible: Bool
    @Binding var isChatVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            previewToolbar
            if let hint = model.navigationHint ?? projectStore.navigationHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            Divider()
            previewContent
        }
        .onChange(of: model.autoRefreshEnabled) { _, enabled in
            model.setAutoRefreshEnabled(enabled)
        }
        .onAppear {
            model.setColorSchemeMode(settingsStore.previewColorScheme)
        }
        .onChange(of: settingsStore.previewColorScheme) { _, mode in
            model.setColorSchemeMode(mode)
            Task { await model.applyColorSchemeToWebView() }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let html = model.renderedHTML, let baseURL = model.renderedBaseURL {
            WebView(
                html: html,
                baseURL: baseURL,
                contentID: model.renderContentID,
                currentURL: $model.currentURL,
                canGoBack: $model.canGoBack,
                canGoForward: $model.canGoForward,
                reloadToken: model.reloadToken,
                goBackToken: model.goBackToken,
                goForwardToken: model.goForwardToken,
                onPageLoaded: { webView in
                    model.handlePageLoaded(webView)
                    Task { await refreshPageContext(from: webView) }
                },
                onInternalChapterLink: { url in
                    model.handleInternalLink(url)
                }
            )
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Preview Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if model.book != nil {
            ContentUnavailableView {
                Label("No Chapter Loaded", systemImage: "doc.text")
            } description: {
                Text("Select a chapter from the sidebar.")
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

            Button {
                withAnimation { isChatVisible.toggle() }
            } label: {
                Text(isChatVisible ? "Hide Chat" : "Show Chat")
            }

            Button(action: model.goBack) { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button(action: model.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button(action: model.reload) { Image(systemName: "arrow.clockwise") }

            Text(model.currentChapterPath ?? "No chapter loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Auto Refresh", isOn: $model.autoRefreshEnabled)
                .toggleStyle(.checkbox)

            Picker("Preview theme", selection: $settingsStore.previewColorScheme) {
                ForEach(PreviewColorSchemeMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .help("Preview color scheme: System follows macOS appearance, Light and Dark override it.")

            if let chapter = currentChapter {
                Button("Open Chapter") {
                    FileHelpers.openFile(path: chapter.markdownPath)
                }
            }
        }
        .padding(10)
    }

    private var currentChapter: Chapter? {
        guard let path = model.currentChapterPath else { return nil }
        return projectStore.chapters.first { $0.relativePath == path }
            ?? projectStore.chapters.first { $0.id == model.detectedChapterID }
    }

    private func refreshPageContext(from webView: WKWebView) async {
        let chapterID = await WebView.detectChapterID(in: webView)
        let pageTitle = await WebView.detectPageTitle(in: webView)
        model.detectedChapterID = chapterID
        model.pageTitle = pageTitle
        chatModel.updatePageContext(chapterID: chapterID, pageTitle: pageTitle, pageURL: model.currentURL)
    }
}
