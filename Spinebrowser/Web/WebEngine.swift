#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
    /// Live pages peeked at in a Glance, by Glance. They belong to no tab until kept.
    private var glanceViews: [UUID: WKWebView] = [:]
    private var glanceObservers: [UUID: [NSKeyValueObservation]] = [:]
    /// Reader pages by tab. One stays alive while its tab shows the same page, so Reader comes
    /// back instantly. A spare waits warm, so even the first Reader doesn't wait on a new process.
    private var readerPages: [UUID: ReaderPageController] = [:]
    private var spareReaderPage: ReaderPageController?
    private let configuration = WKWebViewConfiguration()
    private var blocker: ContentBlocker?
    /// Drag position where the pill last changed, so it takes a deliberate pull to flip it back.
    private var panAnchor: CGFloat = 0

    init(library: Library) {
        self.library = library
        super.init()
        // One shared cookie jar in MVP. Per-space data stores arrive with Profiles.
        configuration.websiteDataStore = .default()
        // Every page shares the extension controller, so content scripts reach all of them.
        configuration.webExtensionController = library.extensions.controller
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        blocker = ContentBlocker(controller: configuration.userContentController, enabled: library.settings.blocksTrackers)
        // Pages report when a drag of theirs starts and ends, so the other window can offer a drop zone.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.dragScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(DragMessageProxy(engine: self), name: Self.dragMessage)
        // The Chrome Web Store's own button adds to this browser instead of sitting disabled.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.storeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.addScriptMessageHandler(
            StoreMessageProxy(engine: self), contentWorld: .page, name: Self.storeMessage
        )
        #if os(macOS)
        // The Mac's long-press is the right mouse button. Links hand themselves to the app
        // before WebKit's own menu can open, so they can become a Glance.
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.contextScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(ContextMenuProxy(engine: self), name: Self.contextMessage)
        #endif
    }

    private static let storeMessage = "spineExtensionStore"
    /// The store disables "Add to Chrome" anywhere that isn't Chrome. On an extension's page this
    /// wakes the button, renames it, and sends its click here. Other languages keep the puzzle piece.
    private static let storeScript = """
    (function () {
      if (location.host !== 'chromewebstore.google.com') return;
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(storeMessage);
      if (!handler) return;
      var installed = false;
      function current() {
        var match = location.pathname.match(/\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})/);
        return match && match[1];
      }
      function label(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT), node;
        while ((node = walker.nextNode())) {
          if (!node.nodeValue.trim()) continue;
          if (node.nodeValue !== text) node.nodeValue = text;
          return;
        }
      }
      function dress() {
        if (!current()) return;
        document.querySelectorAll('button').forEach(function (button) {
          if (!button.dataset.spine) {
            if (!/^Add to (Chrome|Desktop)$/i.test((button.textContent || '').trim())) return;
            button.dataset.spine = '1';
            button.addEventListener('click', function (event) {
              event.preventDefault();
              event.stopImmediatePropagation();
              var id = current();
              if (id && !installed) handler.postMessage({ kind: 'add', id: id });
            }, true);
          }
          label(button, installed ? 'Added to Spine' : 'Add to Spine');
          if (button.disabled !== installed) button.disabled = installed;
        });
      }
      function refresh() {
        var id = current();
        if (!id) return;
        handler.postMessage({ kind: 'state', id: id }).then(function (answer) {
          installed = !!answer;
          dress();
        }, function () {});
      }
      new MutationObserver(dress).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['disabled']
      });
      setInterval(refresh, 1500);
      refresh();
    })();
    """

    /// The store page asks whether its extension is added, or asks to add it. Only the page for
    /// that extension may ask, and adding still waits for a yes.
    fileprivate func storeAsked(_ body: Any, in webView: WKWebView?) -> Bool {
        guard let message = body as? [String: String], let id = message["id"], let webView,
              ChromeWebStore.extensionID(in: webView.url) == id, let extensions = library?.extensions else { return false }
        if message["kind"] == "add", let tabID = tabID(for: webView) { extensions.want(id, in: tabID) }
        return extensions.isInstalled(id)
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

    #if os(macOS)
    private static let contextMessage = "spineContextMenu"
    private static let contextScript = """
    (function () {
      document.addEventListener('contextmenu', function (event) {
        var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
        if (!anchor) return;
        var href = anchor.href;
        if (!/^https?:/i.test(href)) return;
        event.preventDefault();
        try { window.webkit.messageHandlers.\(contextMessage).postMessage(href); } catch (e) {}
      }, true);
    })();
    """

    fileprivate func linkRightClicked(_ href: String, in webView: WKWebView?) {
        guard let webView, let url = URL(string: href),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if isGlance(webView) {
            webView.load(URLRequest(url: url))
        } else {
            library?.peek(url, from: tabID(for: webView), origin: WebContainerView.recentPress)
        }
    }
    #endif

    fileprivate func pageDrag(_ kind: String, in webView: WKWebView?) {
        guard let webView, let tabID = tabID(for: webView) else { return }
        // Off the current turn, in case WebKit calls in mid-update.
        Task { @MainActor in
            self.library?.pageDragged(kind == "start", from: tabID)
        }
    }

    #if os(iOS)
    /// Drag is off by default on iPhone, and WKWebView follows that default. With two windows
    /// side by side, images, links and text need to travel between them.
    private func enableDragging(in view: UIView) {
        for case let drag as UIDragInteraction in view.interactions { drag.isEnabled = true }
        view.subviews.forEach(enableDragging)
    }
    #endif

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

        // An extension's own page runs in that extension's process, with its configuration.
        let view = WKWebView(frame: .zero, configuration: library?.extensions.configuration(for: tab.url) ?? configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        #if os(iOS)
        // Edit ▸ Find (⌘F) and ⌘G reach the page through the system's find bar.
        view.isFindInteractionEnabled = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.panGestureRecognizer.addTarget(self, action: #selector(scrollPanned(_:)))
        #endif
        views[tabID] = view
        observe(view, tabID: tabID)
        #if os(iOS)
        enableDragging(in: view)
        #endif

        if let state = parked.removeValue(forKey: tabID) {
            view.interactionState = state
        } else if let url = tab.url {
            homeNavigations[tabID] = view.load(URLRequest(url: url))
        }
        return view
    }

    /// The tab's web view if it's loaded, without loading it.
    func loadedView(_ tabID: UUID) -> WKWebView? { views[tabID] }

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
        releaseReaderPage(tabID)
        observers[tabID]?.forEach { $0.invalidate() }
        observers[tabID] = nil
        homeNavigations[tabID] = nil
        if let view = views.removeValue(forKey: tabID) {
            view.stopLoading()
            view.removeFromSuperview()
        }
    }

    // MARK: Reader pages

    func readerPage(for tabID: UUID) -> ReaderPageController {
        if let page = readerPages[tabID] { return page }
        let page = spareReaderPage ?? ReaderPageController()
        spareReaderPage = nil
        readerPages[tabID] = page
        return page
    }

    /// Readies a reader page before anyone asks for one.
    func warmReaderPage() {
        guard spareReaderPage == nil else { return }
        let page = ReaderPageController()
        page.warm()
        spareReaderPage = page
    }

    /// The tab's page changed or it went away: its reader page goes too.
    func releaseReaderPage(_ tabID: UUID) {
        readerPages.removeValue(forKey: tabID)?.close()
    }

    // MARK: Glance

    /// The live page in a Glance card, made on first ask.
    func glanceView(for glance: Glance) -> WKWebView {
        if let existing = glanceViews[glance.id] { return existing }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        glanceViews[glance.id] = view
        #if os(iOS)
        enableDragging(in: view)
        #endif
        let id = glance.id
        let sync: @Sendable (WKWebView) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, let view = self.glanceViews[id] else { return }
                self.library?.glanceDidUpdate(id, url: view.url, isLoading: view.isLoading, progress: view.estimatedProgress)
            }
        }
        glanceObservers[id] = [
            view.observe(\.url) { view, _ in sync(view) },
            view.observe(\.isLoading) { view, _ in sync(view) },
            view.observe(\.estimatedProgress) { view, _ in sync(view) },
        ]
        view.load(URLRequest(url: glance.url))
        return view
    }

    /// Where the Glance has got to: the link it opened with, or wherever it was followed.
    func glanceURL(_ id: UUID) -> URL? { glanceViews[id]?.url }

    func releaseGlance(_ id: UUID) {
        glanceObservers.removeValue(forKey: id)?.forEach { $0.invalidate() }
        if let view = glanceViews.removeValue(forKey: id) {
            view.stopLoading()
            view.removeFromSuperview()
        }
    }

    /// Keeping a Glance hands its live page to the new tab, so nothing reloads and the scroll stays put.
    @discardableResult
    func adoptGlance(_ id: UUID, as tabID: UUID) -> Bool {
        glanceObservers.removeValue(forKey: id)?.forEach { $0.invalidate() }
        guard let view = glanceViews.removeValue(forKey: id) else { return false }
        parked[tabID] = nil
        views[tabID] = view
        view.allowsLinkPreview = true
        #if os(iOS)
        view.isFindInteractionEnabled = true
        view.scrollView.panGestureRecognizer.addTarget(self, action: #selector(scrollPanned(_:)))
        #endif
        observe(view, tabID: tabID)
        sync(view, tabID: tabID)
        return true
    }

    private func isGlance(_ webView: WKWebView) -> Bool {
        glanceViews.values.contains { $0 === webView }
    }

    /// The registrable part of a host, near enough: "mail.google.com" and "accounts.google.com"
    /// are one site, "bbc.co.uk" keeps its country code.
    static func site(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let shared: Set = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]
        let keep = labels[labels.count - 1].count == 2 && shared.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Pinned tabs and Essentials stay on their own site. A link off it opens in a Glance.
    private func glancesOffSite(_ url: URL, from webView: WKWebView) -> UUID? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let tabID = tabID(for: webView), let tab = library?.tab(id: tabID), tab.tier != .today,
              let home = tab.url?.host(), let host = url.host(),
              Self.site(of: home) != Self.site(of: host) else { return nil }
        return tabID
    }

    #if os(iOS)
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
    #endif

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
    /// Schemes a web view shows itself. Anything else (tel, mailto, sms, maps, another app's
    /// scheme) belongs to some other app.
    static let pageSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]

    static func isPage(_ url: URL) -> Bool {
        url.scheme.map { pageSchemes.contains($0.lowercased()) } ?? true
    }

    /// Hands a link the web can't show to the app that handles it. Frames inside a page can't,
    /// so an ad's iframe can't throw you into another app.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame ?? false,
           let tabID = glancesOffSite(url, from: webView) {
            library?.peek(url, from: tabID, origin: WebContainerView.recentPress)
            return .cancel
        }
        guard !Self.isPage(url), library?.extensions.controller.extensionContext(for: url) == nil else { return .allow }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            Platform.openExternally(url)
        }
        return .cancel
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let tabID = tabID(for: webView) { sync(webView, tabID: tabID) }
        #if os(iOS)
        // Transparent until the first page commits, so a loading tab shows the card instead of
        // a white flash. After that WebKit must paint the page canvas itself: a site that sets
        // no background of its own expects white behind its text, not the app's dark surface.
        if !webView.isOpaque {
            webView.isOpaque = true
            webView.backgroundColor = nil
        }
        #endif
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tabID = tabID(for: webView) { sync(webView, tabID: tabID) }
        guard let pageURL = webView.url, let host = pageURL.host() else { return }
        let tabID = tabID(for: webView)
        guard tabID != nil || isGlance(webView) else { return }
        // The tab's saved host borrows this icon only when this page is where its address led,
        // redirects included. Anywhere else the tab browses keeps its icon to itself.
        let isHome = navigation != nil && tabID.map { homeNavigations[$0] === navigation } ?? false
        if isHome, let tabID { homeNavigations[tabID] = nil }
        let aliases = isHome ? [tabID.flatMap { library?.tab(id: $0)?.url?.host() }].compactMap { $0 } : []
        if let tabID {
            // Offer Reader only where there's an article to read.
            Task { @MainActor [weak self] in
                let readable = await ReaderExtractor.isReaderable(webView)
                guard webView.url == pageURL else { return }
                self?.library?.setReaderable(readable, for: tabID, url: pageURL)
            }
        }
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

extension WebEngine {
    /// target=_blank and window.open land in a new Today tab instead of a popup.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if let tabID = glancesOffSite(url, from: webView) {
            library?.peek(url, from: tabID, origin: WebContainerView.recentPress)
        } else if isGlance(webView), Self.isPage(url) {
            // A Glance stays one page: a new window from it opens in the same card.
            webView.load(URLRequest(url: url))
        } else if Self.isPage(url) || library?.extensions.controller.extensionContext(for: url) != nil {
            library?.pageOpened(url, from: tabID(for: webView))
        } else {
            Platform.openExternally(url)
        }
        return nil
    }
}

extension WebEngine: WKUIDelegate {
    #if os(iOS)
    /// Long-press a link to peek at it in a Glance over the other window. The system menu stays away.
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if isGlance(webView) {
            // Inside a Glance, the card follows the link.
            webView.load(URLRequest(url: url))
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            library?.peek(url, from: tabID(for: webView), origin: WebContainerView.recentPress)
        }
        // Nil would bring back WebKit's own menu. An empty one shows nothing.
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: []) }
    }
    #else
    /// A page's file field opens the standard panel.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    #endif
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

/// The Chrome Web Store's button, asking after its extension.
private final class StoreMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var engine: WebEngine?

    init(engine: WebEngine) { self.engine = engine }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame else { return replyHandler(false, nil) }
        replyHandler(MainActor.assumeIsolated { engine?.storeAsked(message.body, in: message.webView) ?? false }, nil)
    }
}

#if os(macOS)
/// A right-clicked link, on its way to a Glance.
private final class ContextMenuProxy: NSObject, WKScriptMessageHandler {
    weak var engine: WebEngine?

    init(engine: WebEngine) { self.engine = engine }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let href = message.body as? String else { return }
        MainActor.assumeIsolated { engine?.linkRightClicked(href, in: message.webView) }
    }
}
#endif

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

#if os(macOS)
extension WebEngine {
    /// Find on the focused page. The bar lives in the SwiftUI shell.
    func find(_ text: String, forward: Bool, in tabID: UUID) {
        guard let view = views[tabID], !text.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        Task { _ = try? await view.find(text, configuration: configuration) }
    }

    #if DEBUG
    /// Test-only: dispatch a contextmenu from the page's first link, exercising the Mac's
    /// right-click-to-Glance path without a mouse.
    func debugContextMenu(_ tabID: UUID) {
        views[tabID]?.evaluateJavaScript("""
        (function () {
          var a = document.querySelector('a[href^="http"]');
          if (a) a.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, view: window }));
        })();
        """)
    }
    #endif

    /// File ▸ Print prints the focused page.
    func printPage(_ tabID: UUID) {
        guard let view = views[tabID] else { return }
        let operation = view.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
}

extension WebEngine: WKDownloadDelegate {
    /// Downloads land in Downloads, with a numbered name when one is already there.
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let folder = ProcessInfo.processInfo.environment["SPINE_DOWNLOAD_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(suggestedFilename)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {}
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {}
}

extension WebEngine {
    /// A file the page can't show is a download, not an error page.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
}
#endif
