import AppKit
import SwiftUI
import WebKit

final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var parent: WebView
    var lastGoBackToken: UUID?
    var lastGoForwardToken: UUID?
    var lastReloadToken: UUID?
    var lastLoadedContentID: UUID?
    var lastNavigateToken: UUID?

    init(parent: WebView) {
        self.parent = parent
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bookloopAnnotation",
              let body = message.body as? [String: Any],
              body["type"] as? String == "click",
              let id = body["id"] as? String else { return }
        let callback = parent.onAnnotationClicked
        Task { @MainActor in
            callback?(id)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        deliverNavigationUpdate(for: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        deliverNavigationUpdate(for: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        deliverNavigationUpdate(for: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "bookloop", url.host == "chapter" {
            let callback = parent.onInternalChapterLink
            Task { @MainActor in
                callback?(url)
            }
            decisionHandler(.cancel)
            return
        }

        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }

        if url.isFileURL, url.pathExtension.lowercased() == "md" {
            let callback = parent.onInternalChapterLink
            Task { @MainActor in
                callback?(url)
            }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    private func deliverNavigationUpdate(for webView: WKWebView) {
        let url = webView.url
        let canGoBack = webView.canGoBack
        let canGoForward = webView.canGoForward
        let onPageLoaded = parent.onPageLoaded
        Task { @MainActor in
            parent.currentURL = url
            parent.canGoBack = canGoBack
            parent.canGoForward = canGoForward
            onPageLoaded?(webView)
        }
    }
}

struct WebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    let contentID: UUID
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    var reloadToken: UUID = UUID()
    var goBackToken: UUID?
    var goForwardToken: UUID?
    var navigateToken: UUID?
    var onPageLoaded: ((WKWebView) -> Void)?
    var onInternalChapterLink: ((URL) -> Void)?
    var onAnnotationClicked: ((String) -> Void)?

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.userContentController.add(context.coordinator, name: "bookloopAnnotation")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastLoadedContentID = contentID
        context.coordinator.lastReloadToken = reloadToken
        webView.loadHTMLString(html, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if let goBackToken, goBackToken != context.coordinator.lastGoBackToken {
            context.coordinator.lastGoBackToken = goBackToken
            webView.goBack()
            return
        }

        if let goForwardToken, goForwardToken != context.coordinator.lastGoForwardToken {
            context.coordinator.lastGoForwardToken = goForwardToken
            webView.goForward()
            return
        }

        let shouldReload = reloadToken != context.coordinator.lastReloadToken || contentID != context.coordinator.lastLoadedContentID
        if shouldReload {
            context.coordinator.lastReloadToken = reloadToken
            context.coordinator.lastLoadedContentID = contentID
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    static func detectChapterID(in webView: WKWebView) async -> String? {
        let metaScript = "document.querySelector('meta[name=\"chapter-id\"]')?.getAttribute('content')"
        if let metaValue = try? await webView.evaluateJavaScript(metaScript) as? String {
            let trimmed = metaValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return URLHelpers.inferChapterID(from: webView.url)
    }

    static func detectPageTitle(in webView: WKWebView) async -> String? {
        let title = try? await webView.evaluateJavaScript("document.title") as? String
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func extractPageContent(in webView: WKWebView?) async -> String {
        guard let webView else { return "" }
        let script = """
        (function() {
          const article = document.getElementById('bookloop-content')
            || document.querySelector('article')
            || document.querySelector('main');
          const text = article ? article.innerText : document.body.innerText;
          return text ? text.trim() : '';
        })()
        """
        let text = try? await webView.evaluateJavaScript(script) as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func applyColorScheme(_ mode: PreviewColorSchemeMode, in webView: WKWebView) async {
        guard let data = try? JSONEncoder().encode(mode.rawValue),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        let script = "window.BookLoopPreview?.setColorSchemeMode(\(encoded))"
        _ = try? await webView.evaluateJavaScript(script)
    }

    static func setupAnnotationHandlers(in webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript("window.BookLoopPreview?.setupAnnotationHandlers?.()")
    }

    static func captureSelectionQuote(in webView: WKWebView) async -> PreviewSelectionQuote? {
        let script = "window.BookLoopPreview?.captureSelectionQuote?.()"
        guard let value = try? await webView.evaluateJavaScript(script) else { return nil }
        guard let dictionary = value as? [String: Any],
              let exact = dictionary["exact"] as? String,
              !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PreviewSelectionQuote(
            exact: exact,
            prefix: dictionary["prefix"] as? String ?? "",
            suffix: dictionary["suffix"] as? String ?? ""
        )
    }

    static func applyAnnotations(_ annotations: [PreviewAnnotation], in webView: WKWebView) async {
        let wire = annotations.map {
            PreviewAnnotationWire(
                id: $0.id.uuidString,
                exact: $0.exact,
                prefix: $0.prefix,
                suffix: $0.suffix,
                note: $0.note
            )
        }
        guard let data = try? JSONEncoder().encode(wire),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.BookLoopPreview?.applyHighlights(\(json))"
        _ = try? await webView.evaluateJavaScript(script)
    }
}

private struct PreviewAnnotationWire: Encodable {
    var id: String
    var exact: String
    var prefix: String
    var suffix: String
    var note: String
}

@MainActor
final class BookPreviewModel: ObservableObject {
    @Published var book: BookConfig?
    @Published var currentChapterPath: String?
    @Published var renderedHTML: String?
    @Published var renderedBaseURL: URL?
    @Published var renderContentID = UUID()
    @Published var currentURL: URL?
    @Published var pageTitle: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var reloadToken = UUID()
    @Published var goBackToken: UUID?
    @Published var goForwardToken: UUID?
    @Published var chapterNav: [ChapterNavItem] = []
    @Published var autoRefreshEnabled = false
    @Published var detectedChapterID: String?
    @Published var selectedText: String?
    @Published var loadError: String?
    @Published var navigationHint: String?
    @Published var previewStatus: LocalAPIStatus = .unknown

    var colorSchemeMode: PreviewColorSchemeMode = .system {
        didSet {
            renderer.colorSchemeMode = colorSchemeMode
        }
    }

    private var history: [String] = []
    private var historyIndex = -1
    private var lastRenderedModificationDate: Date?
    private var autoRefreshTask: Task<Void, Never>?
    private let renderer = BookMarkdownRenderer()

    weak var webView: WKWebView?

    deinit {
        autoRefreshTask?.cancel()
    }

    func reset() {
        book = nil
        currentChapterPath = nil
        renderedHTML = nil
        renderedBaseURL = nil
        currentURL = nil
        pageTitle = nil
        canGoBack = false
        canGoForward = false
        chapterNav = []
        detectedChapterID = nil
        selectedText = nil
        loadError = nil
        navigationHint = nil
        previewStatus = .unknown
        history = []
        historyIndex = -1
        webView = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    func load(book: BookConfig, navigation: BookNavigationScanResult) {
        self.book = book
        chapterNav = navigation.navItems
        navigationHint = BookloopYamlConfig.migrationHint(for: BookloopYamlConfig.resolveConfigPath(for: book))
        previewStatus = FileManager.default.fileExists(atPath: book.docsPath ?? book.suggestedPath("docs"))
            ? .online
            : .offline("docs/ folder not found.")

        let initialPath = ChapterNavItem.firstNavigablePath(in: navigation.navItems)
            ?? navigation.chapters.first?.relativePath
            ?? "index.md"
        history = [initialPath]
        historyIndex = 0
        renderChapter(initialPath, recordHistory: false)
    }

    func reload() {
        guard let path = currentChapterPath else { return }
        renderChapter(path, recordHistory: false)
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        renderChapter(history[historyIndex], recordHistory: false)
    }

    func goForward() {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        renderChapter(history[historyIndex], recordHistory: false)
    }

    func navigateToChapter(_ relativePath: String) {
        let normalized = ChapterResolver.normalizedDocsRelativeMarkdownPath(relativePath)
        renderChapter(normalized, recordHistory: true)
    }

    func handleInternalLink(_ url: URL) {
        if url.scheme == "bookloop", url.host == "chapter",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            navigateToChapter(path)
            return
        }

        if url.isFileURL, url.pathExtension.lowercased() == "md", let book {
            let docsPath = URL(fileURLWithPath: book.docsPath ?? book.suggestedPath("docs"), isDirectory: true).standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            if filePath.hasPrefix(docsPath + "/") {
                let relative = String(filePath.dropFirst(docsPath.count + 1))
                navigateToChapter(relative)
            }
        }
    }

    func openInBrowser() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    func handlePageLoaded(_ webView: WKWebView) {
        self.webView = webView
        canGoBack = historyIndex > 0
        canGoForward = historyIndex + 1 < history.count
        Task { await applyColorSchemeToWebView() }
    }

    func setColorSchemeMode(_ mode: PreviewColorSchemeMode) {
        colorSchemeMode = mode
    }

    func applyColorSchemeToWebView() async {
        guard let webView else { return }
        await WebView.applyColorScheme(colorSchemeMode, in: webView)
    }

    func captureSelectedText() async {
        guard let webView else { return }
        do {
            let result = try await webView.evaluateJavaScript("window.getSelection()?.toString()")
            selectedText = (result as? String)?.nilIfBlank
        } catch {
            loadError = error.localizedDescription
        }
    }

    func captureSelectionQuote() async -> PreviewSelectionQuote? {
        guard let webView else { return nil }
        return await WebView.captureSelectionQuote(in: webView)
    }

    func applyAnnotations(_ annotations: [PreviewAnnotation]) async {
        guard let webView else { return }
        await WebView.setupAnnotationHandlers(in: webView)
        await WebView.applyAnnotations(annotations, in: webView)
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        autoRefreshTask?.cancel()
        guard enabled else { return }
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.pollForChapterChanges()
            }
        }
    }

    private func pollForChapterChanges() async {
        guard autoRefreshEnabled,
              let book,
              let path = currentChapterPath else { return }
        let docsURL = URL(fileURLWithPath: book.docsPath ?? book.suggestedPath("docs"), isDirectory: true)
        let fileURL = docsURL.appendingPathComponent(path)
        guard let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return
        }
        if let lastRenderedModificationDate, modified <= lastRenderedModificationDate {
            return
        }
        renderChapter(path, recordHistory: false)
    }

    private func renderChapter(_ relativePath: String, recordHistory: Bool) {
        guard let book else { return }
        do {
            let rendered = try renderer.renderChapter(book: book, relativePath: relativePath)
            renderedHTML = rendered.html
            renderedBaseURL = rendered.baseDirectory
            renderContentID = UUID()
            currentChapterPath = rendered.relativePath
            pageTitle = rendered.title
            detectedChapterID = rendered.chapterID
            currentURL = URLHelpers.bookloopChapterURL(for: rendered.relativePath)
            loadError = nil

            let fileURL = rendered.baseDirectory.appendingPathComponent(rendered.relativePath)
            lastRenderedModificationDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

            if recordHistory {
                if historyIndex >= 0 && historyIndex + 1 < history.count {
                    history.removeSubrange((historyIndex + 1)...)
                }
                if history.last != rendered.relativePath {
                    history.append(rendered.relativePath)
                    historyIndex = history.count - 1
                }
            } else if historyIndex >= 0 {
                history[historyIndex] = rendered.relativePath
            }

            canGoBack = historyIndex > 0
            canGoForward = historyIndex + 1 < history.count
        } catch {
            loadError = error.localizedDescription
        }
    }
}

typealias WebViewModel = BookPreviewModel
