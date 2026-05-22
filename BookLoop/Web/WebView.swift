import SwiftUI
import WebKit

@MainActor
final class WebViewModel: NSObject, ObservableObject {
    @Published var currentURL: URL?
    @Published var pageTitle: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var detectedChapterID: String?
    @Published var selectedText: String?
    @Published var loadError: String?

    weak var webView: WKWebView?

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func reload() {
        webView?.reload()
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        guard let webView else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func captureSelectedText() async {
        do {
            let result = try await evaluateJavaScript("window.getSelection()?.toString()")
            selectedText = (result as? String)?.nilIfBlank
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshNavigationState(from webView: WKWebView) {
        currentURL = webView.url
        pageTitle = webView.title
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func detectChapterID() async {
        do {
            let meta = try await evaluateJavaScript("document.querySelector('meta[name=\"chapter-id\"]')?.getAttribute('content')")
            if let chapter = (meta as? String)?.nilIfBlank {
                detectedChapterID = chapter
            } else {
                detectedChapterID = currentURL?.detectedChapterSlug
            }
        } catch {
            detectedChapterID = currentURL?.detectedChapterSlug
        }
    }
}

struct WebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var model: WebViewModel

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        model.webView = nsView
        if nsView.url == nil || nsView.url?.absoluteString != url.absoluteString && nsView.isLoading == false {
            nsView.load(URLRequest(url: url))
        }
    }
}

final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    private weak var model: WebViewModel?

    init(model: WebViewModel) {
        self.model = model
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            model?.refreshNavigationState(from: webView)
            await model?.detectChapterID()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            model?.refreshNavigationState(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            model?.loadError = error.localizedDescription
            model?.refreshNavigationState(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            model?.loadError = error.localizedDescription
            model?.refreshNavigationState(from: webView)
        }
    }
}
