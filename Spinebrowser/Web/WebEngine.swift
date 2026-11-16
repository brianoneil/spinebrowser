import UIKit
import WebKit

/// Owns one WKWebView per loaded tab. Switching tabs re-parents a live view, so nothing
/// reloads and scroll, form input and in-flight loads survive.
@MainActor
final class WebEngine: NSObject {
    private weak var library: Library?
    private var views: [UUID: WKWebView] = [:]
    private var observers: [UUID: [NSKeyValueObservation]] = [:]
    /// Navigation state for tabs unloaded to save memory; restored on activation.
    private var parked: [UUID: Any] = [:]
    /// The navigation loading each tab's own saved address. Only that page's icon may stand in for
    /// the address: a pinned tab you've searched from must keep its own icon.
    private var homeNavigations: [UUID: WKNavigation] = [:]
    private let configuration = WKWebViewConfiguration()
    private var blocker: ContentBlocker?
    /// Drag position where the pill last changed, so it takes a deliberate pull to flip it back.
    private var panAnchor: CGFloat = 0

    init(library: Library) {
        self.library = library
        super.init()
        // One shared cookie jar in MVP. Per-space data stores arrive with Profiles.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        blocker = ContentBlocker(controller: configuration.userContentController, enabled: library.settings.blocksTrackers)
        // Pages report when a drag of theirs starts and ends, so the other window can offer a drop zone.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.dragScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(DragMessageProxy(engine: self), name: Self.dragMessage)
    }

    private static let dragMessage = "spineDrag"
    private static let dragScript = """
    (function () {
      function post(kind) {
        try { window.webkit.messageHandlers.\(dragMessage).postMessage(kind); } catch (e) {}
      }
      addEventListener('dragstart', function () { post('start'); }, true);
      addEventListener('dragend', function () { post('end'); }, true);
    })();
    """

    fileprivate func pageDrag(_ kind: String, in webView: WKWebView?) {
        guard let webView, let tabID = tabID(for: webView) else { return }
        // Off the current turn, in case WebKit calls in mid-update.
        Task { @MainActor in
            self.library?.pageDragged(kind == "start", from: tabID)
        }
    }

    /// Drag is off by default on iPhone, and WKWebView follows that default. With two windows
    /// side by side, images, links and text need to travel between them.
    private func enableDragging(in view: UIView) {
        for case let drag as UIDragInteraction in view.interactions { drag.isEnabled = true }
        view.subviews.forEach(enableDragging)
    }

    /// Turns the bundled rule list on or off for every web view, then reloads the given tabs.
    func setContentBlocking(_ enabled: Bool, reloading tabIDs: [UUID]) {
        blocker?.setEnabled(enabled, in: views.values.map(\.configuration.userContentController))
        tabIDs.forEach(reload)
    }

    /// Cookies, local storage, caches: everything the shared data store holds, plus the
    /// app-wide URL cache and cookies the favicon fetches use.
    func removeWebsiteData() async {
        await configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }

    /// Throws away every web view and parked history. Tabs reload at their address when shown.
    func discardAll() {
        for tabID in Array(views.keys) { release(tabID) }
        parked.removeAll()
    }

    func webView(for tabID: UUID) -> WKWebView? {
        if let existing = views[tabID] { return existing }
        guard let tab = library?.tab(id: tabID) else { return nil }

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        // Edit ▸ Find (⌘F) and ⌘G reach the page through the system's find bar.
        view.isFindInteractionEnabled = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.panGestureRecognizer.addTarget(self, action: #selector(scrollPanned(_:)))
        views[tabID] = view
        observe(view, tabID: tabID)
        enableDragging(in: view)

        if let state = parked.removeValue(forKey: tabID) {
            view.interactionState = state
        } else if let url = tab.url {
            homeNavigations[tabID] = view.load(URLRequest(url: url))
        }
        return view
    }

    func load(_ url: URL, in tabID: UUID) {
        parked[tabID] = nil
        if let view = views[tabID] {
            let navigation = view.load(URLRequest(url: url))
            homeNavigations[tabID] = url == library?.tab(id: tabID)?.url ? navigation : nil
        }
        // Otherwise the tab's stored URL loads when its view is first shown.
    }

    func goBack(_ tabID: UUID) { views[tabID]?.goBack() }
    func goForward(_ tabID: UUID) { views[tabID]?.goForward() }

    /// Steps the page's zoom, between half and three times. Nil goes back to actual size.
    func zoom(_ tabID: UUID, by step: CGFloat?) {
        guard let view = views[tabID] else { return }
        view.pageZoom = step.map { min(3, max(0.5, view.pageZoom + $0)) } ?? 1
    }

    func reload(_ tabID: UUID) {
        guard let view = views[tabID] else { return }
        if view.url == nil, let url = library?.tab(id: tabID)?.url {
            homeNavigations[tabID] = view.load(URLRequest(url: url))
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
        homeNavigations[tabID] = nil
        if let view = views.removeValue(forKey: tabID) {
            view.stopLoading()
            view.removeFromSuperview()
        }
    }

    /// Reading down the page hides the URL pill; pulling back up, or reaching the top, shows it.
    /// Only real drags count, so a page that moves on its own never hides the pill.
    @objc private func scrollPanned(_ pan: UIPanGestureRecognizer) {
        guard let scroll = pan.view as? UIScrollView,
              let tabID = views.first(where: { $0.value.scrollView === scroll })?.key else { return }
        let y = pan.translation(in: scroll).y
        switch pan.state {
        case .began:
            panAnchor = y
        case .changed, .ended:
            let atTop = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1
            let delta = y - panAnchor
            // A quick flick ends before it travels far, so its speed counts too.
            let flick = pan.state == .ended ? pan.velocity(in: scroll).y : 0
            if delta < -24 || flick < -400 {
                library?.setAddressHidden(true, for: tabID)
                panAnchor = y
            } else if delta > 24 || flick > 400 || (atTop && delta >= 0) {
                library?.setAddressHidden(false, for: tabID)
                panAnchor = y
            }
        default:
            break
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
        library?.webDidUpdate(tabID, title: view.title, state: state)
    }
}

extension WebEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Transparent until the first page commits, so a loading tab shows the card instead of
        // a white flash. After that WebKit must paint the page canvas itself: a site that sets
        // no background of its own expects white behind its text, not the app's dark surface.
        if !webView.isOpaque {
            webView.isOpaque = true
            webView.backgroundColor = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tabID = tabID(for: webView), let pageURL = webView.url, let host = pageURL.host() else { return }
        // The tab's saved host borrows this icon only when this page is where its address led,
        // redirects included. Anywhere else the tab browses keeps its icon to itself.
        let isHome = navigation != nil && homeNavigations[tabID] === navigation
        if isHome { homeNavigations[tabID] = nil }
        let aliases = isHome ? [library?.tab(id: tabID)?.url?.host()].compactMap { $0 } : []
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
            Task { @MainActor in
                self?.library?.favicons.fetch(pageHost: host, aliases: aliases, candidates: candidates)
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
            library?.pageOpened(url, from: tabID(for: webView))
        }
        return nil
    }
}

/// The content controller keeps its handlers alive, so it holds this instead of the engine.
private final class DragMessageProxy: NSObject, WKScriptMessageHandler {
    weak var engine: WebEngine?

    init(engine: WebEngine) { self.engine = engine }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let kind = message.body as? String else { return }
        MainActor.assumeIsolated { engine?.pageDrag(kind, in: message.webView) }
    }
}

/// Built-in tracker and ad blocking from a bundled WebKit content-rule list, on by default.
@MainActor
final class ContentBlocker {
    private let controller: WKUserContentController
    private var list: WKContentRuleList?
    private var isEnabled: Bool

    private static let source: String? = Bundle.main.url(forResource: "blocklist", withExtension: "json")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// How many hosts the list blocks outright. Settings quotes it, so it's counted, not hard-coded.
    static let blockedHostCount: Int = {
        guard let data = source?.data(using: .utf8),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return rules.filter { ($0["action"] as? [String: Any])?["type"] as? String == "block" }.count
    }()

    init(controller: WKUserContentController, enabled: Bool) {
        self.controller = controller
        self.isEnabled = enabled
        guard let source = Self.source else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "spinebrowser-blocklist-1",
            encodedContentRuleList: source
        ) { [weak self] list, _ in
            guard let list else { return }
            Task { @MainActor in
                guard let self else { return }
                self.list = list
                if self.isEnabled { self.controller.add(list) }
            }
        }
    }

    /// Live web views copy their configuration, so each one's controller is updated too.
    func setEnabled(_ enabled: Bool, in controllers: [WKUserContentController]) {
        isEnabled = enabled
        guard let list else { return }
        var seen = Set<ObjectIdentifier>()
        for controller in [controller] + controllers where seen.insert(ObjectIdentifier(controller)).inserted {
            controller.remove(list)
            if enabled { controller.add(list) }
        }
    }
}
