import AppKit
import SwiftUI
import WebKit

enum WebViewSupport {
    static let embedCSS = """
    aside.md-sidebar, .md-sidebar--primary, .md-sidebar--secondary {
      display: none !important; visibility: hidden !important; width: 0 !important;
    }
    .md-main, .md-main__inner, .md-content, .md-content__inner {
      max-width: none !important; margin-left: 0 !important; width: 100% !important;
    }
    .md-main__inner, .md-content, .md-content__inner, article.md-content__inner {
      padding-left: 1.50rem !important; padding-right: 1.00rem !important;
    }
    .md-grid { max-width: none !important; }
    .md-overlay, label[for="__drawer"], .md-header__button[for="__drawer"] {
      display: none !important;
    }
    @media screen and (max-width: 76.1875em) {
      aside.md-sidebar, .md-sidebar--primary { display: none !important; }
      .md-content { margin-left: 0 !important; }
    }
    body:not(.bookloop-ready) .md-main {
      opacity: 0 !important;
    }
    body.bookloop-ready .md-main {
      opacity: 1 !important;
    }
    """

    static var cssInjectionScript: String {
        let cssLiteral = embedCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        return """
        (function() {
          var viewport = document.querySelector('meta[name=\"viewport\"]');
          if (!viewport) {
            viewport = document.createElement('meta');
            viewport.name = 'viewport';
            (document.head || document.documentElement).appendChild(viewport);
          }
          viewport.content = 'width=1600';

          var styleId = 'bookloop-mkdocs-embed-style';
          var style = document.getElementById(styleId);
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = `\(cssLiteral)`;
        })();
        """
    }

    static var mkdocsEmbedScript: String {
        """
        \(cssInjectionScript)
        (function() {
          if (document.body) {
            document.body.classList.add('bookloop-ready');
          }
        })();
        """
    }

    static let hideContentScript = """
    (function() {
      if (document.body) {
        document.body.classList.remove('bookloop-ready');
      }
    })();
    """
}

private struct RawChapterNavItem: Decodable {
    let title: String
    let href: String
    let children: [RawChapterNavItem]?
}

final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    var parent: WebView
    var lastGoBackToken: UUID?
    var lastGoForwardToken: UUID?
    var lastReloadToken: UUID?
    var lastLoadedPreviewURL: URL?
    var lastNavigateToken: UUID?

    init(parent: WebView) {
        self.parent = parent
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavigationState(webView)
        webView.evaluateJavaScript(WebViewSupport.hideContentScript, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavigationState(webView)
        webView.evaluateJavaScript(WebViewSupport.mkdocsEmbedScript) { _, _ in
            self.parent.onPageLoaded?(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavigationState(webView)
        webView.evaluateJavaScript(WebViewSupport.mkdocsEmbedScript, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateNavigationState(webView)
        webView.evaluateJavaScript(WebViewSupport.mkdocsEmbedScript, completionHandler: nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    private func updateNavigationState(_ webView: WKWebView) {
        parent.currentURL = webView.url
        parent.canGoBack = webView.canGoBack
        parent.canGoForward = webView.canGoForward
    }
}

struct WebView: NSViewRepresentable {
    let url: URL
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    var reloadToken: UUID = UUID()
    var goBackToken: UUID?
    var goForwardToken: UUID?
    var navigateToken: UUID?
    var navigateURL: URL?
    var onPageLoaded: ((WKWebView) -> Void)?

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop

        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: WebViewSupport.cssInjectionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: WebViewSupport.cssInjectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastLoadedPreviewURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if let navigateURL, let navigateToken,
           navigateToken != context.coordinator.lastNavigateToken {
            context.coordinator.lastNavigateToken = navigateToken
            webView.load(URLRequest(url: navigateURL))
            return
        }

        if context.coordinator.lastLoadedPreviewURL != url {
            context.coordinator.lastLoadedPreviewURL = url
            context.coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: url))
            return
        }

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

        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
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
          const article = document.querySelector('article')
            || document.querySelector('.md-content')
            || document.querySelector('main');
          const text = article ? article.innerText : document.body.innerText;
          return text ? text.trim() : '';
        })()
        """
        let text = try? await webView.evaluateJavaScript(script) as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func extractChapterNav(in webView: WKWebView) async -> [ChapterNavItem] {
        guard let json = try? await webView.evaluateJavaScript(ChapterNavExtractor.script) as? String,
              let data = json.data(using: .utf8),
              let rawItems = try? JSONDecoder().decode([RawChapterNavItem].self, from: data) else {
            return []
        }
        return rawItems.map(mapRawItem)
    }

    private static func mapRawItem(_ raw: RawChapterNavItem) -> ChapterNavItem {
        ChapterNavItem(
            title: raw.title,
            href: raw.href,
            children: (raw.children ?? []).map(mapRawItem)
        )
    }
}

@MainActor
final class BookPreviewModel: ObservableObject {
    @Published var book: BookConfig?
    @Published var previewURL: URL?
    @Published var currentURL: URL?
    @Published var pageTitle: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var reloadToken = UUID()
    @Published var goBackToken: UUID?
    @Published var goForwardToken: UUID?
    @Published var navigateToken: UUID?
    @Published var navigateURL: URL?
    @Published var chapterNav: [ChapterNavItem] = []
    @Published var autoRefreshEnabled = false
    @Published var detectedChapterID: String?
    @Published var selectedText: String?
    @Published var loadError: String?

    weak var webView: WKWebView?

    func reset() {
        book = nil
        previewURL = nil
        currentURL = nil
        pageTitle = nil
        canGoBack = false
        canGoForward = false
        navigateToken = nil
        navigateURL = nil
        chapterNav = []
        detectedChapterID = nil
        selectedText = nil
        loadError = nil
        webView = nil
    }

    func load(book: BookConfig) {
        self.book = book
        previewURL = URLHelpers.normalizedPreviewURL(from: book.previewURL)
        chapterNav = []
        detectedChapterID = nil
        reloadToken = UUID()
    }

    func reload() {
        reloadToken = UUID()
    }

    func goBack() { goBackToken = UUID() }
    func goForward() { goForwardToken = UUID() }

    func navigate(to url: URL) {
        navigateURL = url
        navigateToken = UUID()
    }

    func updateChapterNav(_ items: [ChapterNavItem]) {
        if !items.isEmpty { chapterNav = items }
    }

    func openInBrowser() {
        guard let url = currentURL ?? previewURL else { return }
        NSWorkspace.shared.open(url)
    }

    func handlePageLoaded(_ webView: WKWebView) {
        self.webView = webView
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
}

typealias WebViewModel = BookPreviewModel
