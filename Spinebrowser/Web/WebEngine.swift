import UIKit
import WebKit

/// Owns one WKWebView per loaded tab. Switching tabs re-parents a live view, so nothing
/// reloads and scroll, form input and in-flight loads survive.
@MainActor
final class WebEngine: NSObject {
    private weak var store: BrowserStore?
    private var views: [UUID: WKWebView] = [:]
    private var observers: [UUID: [NSKeyValueObservation]] = [:]
    /// Navigation state for tabs unloaded to save memory; restored on activation.
    private var parked: [UUID: Any] = [:]
    private let configuration = WKWebViewConfiguration()

    init(store: BrowserStore) {
        self.store = store
        super.init()
        // One shared cookie jar in MVP. Per-space data stores arrive with Profiles.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        ContentBlocker.install(into: configuration.userContentController)
    }

    func webView(for tabID: UUID) -> WKWebView? {
        if let existing = views[tabID] { return existing }
        guard let tab = store?.tab(id: tabID) else { return nil }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        views[tabID] = view
        observe(view, tabID: tabID)

        if let state = parked.removeValue(forKey: tabID) {
            view.interactionState = state
        } else if let url = tab.url {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func load(_ url: URL, in tabID: UUID) {
        parked[tabID] = nil
        if let view = views[tabID] {
            view.load(URLRequest(url: url))
        }
        // Otherwise the tab's stored URL loads when its view is first shown.
    }

    func goBack(_ tabID: UUID) { views[tabID]?.goBack() }
    func goForward(_ tabID: UUID) { views[tabID]?.goForward() }

    func reload(_ tabID: UUID) {
        guard let view = views[tabID] else { return }
        if view.url == nil, let url = store?.tab(id: tabID)?.url {
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    /// Drops the view but keeps its history so the tab comes back where it was.
    func park(_ tabID: UUID) {
        guard let view = views[tabID] else { return }
        parked[tabID] = view.interactionState
        release(tabID)
    }

    func discard(_ tabID: UUID) {
        parked[tabID] = nil
        release(tabID)
    }

    private func release(_ tabID: UUID) {
        observers[tabID]?.forEach { $0.invalidate() }
        observers[tabID] = nil
        if let view = views.removeValue(forKey: tabID) {
            view.stopLoading()
            view.removeFromSuperview()
        }
    }

    private func tabID(for webView: WKWebView) -> UUID? {
        views.first { $0.value === webView }?.key
    }

    private func observe(_ view: WKWebView, tabID: UUID) {
        // KVO fires synchronously, sometimes in the middle of a SwiftUI update (a view being
        // parented kicks off its first load). Mutating the store there re-enters the update
        // and hangs, so every sync hops to the next main-actor turn.
        let sync: @Sendable (WKWebView) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, let view = self.views[tabID] else { return }
                self.sync(view, tabID: tabID)
            }
        }
        observers[tabID] = [
            view.observe(\.title) { view, _ in sync(view) },
            view.observe(\.url) { view, _ in sync(view) },
            view.observe(\.canGoBack) { view, _ in sync(view) },
            view.observe(\.canGoForward) { view, _ in sync(view) },
            view.observe(\.isLoading) { view, _ in sync(view) },
            view.observe(\.estimatedProgress) { view, _ in sync(view) },
            view.observe(\.hasOnlySecureContent) { view, _ in sync(view) },
        ]
    }

    private func sync(_ view: WKWebView, tabID: UUID) {
        let url = view.url
        let state = TabRuntime(
            currentURL: url,
            canGoBack: view.canGoBack,
            canGoForward: view.canGoForward,
            isLoading: view.isLoading,
            progress: view.estimatedProgress,
            isSecure: url?.scheme != "http"
        )
        store?.webDidUpdate(tabID, title: view.title, state: state)
    }
}

extension WebEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tabID = tabID(for: webView), let pageURL = webView.url, let host = pageURL.host() else { return }
        let tabHost = store?.tab(id: tabID)?.url?.host()
        let script = """
        (function () {
          var link = document.querySelector('link[rel~="apple-touch-icon"]') || document.querySelector('link[rel~="icon"]');
          return link ? link.href : null;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            let declared = (result as? String).flatMap { URL(string: $0) }
            let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
            let candidates = [declared, fallback].compactMap { $0 }
            let hosts = [host, tabHost].compactMap { $0 }
            Task { @MainActor in
                self?.store?.favicons.fetch(hosts: hosts, candidates: candidates)
            }
        }
    }
}

extension WebEngine: WKUIDelegate {
    /// target=_blank and window.open land in a new Today tab instead of a popup.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            store?.newTab(url: url)
        }
        return nil
    }
}

/// Built-in tracker and ad blocking from a bundled WebKit content-rule list.
enum ContentBlocker {
    static func install(into controller: WKUserContentController) {
        guard
            let url = Bundle.main.url(forResource: "blocklist", withExtension: "json"),
            let rules = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "spinebrowser-blocklist-1",
            encodedContentRuleList: rules
        ) { list, _ in
            guard let list else { return }
            Task { @MainActor in controller.add(list) }
        }
    }
}
