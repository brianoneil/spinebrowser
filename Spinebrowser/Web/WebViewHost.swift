import SwiftUI
import WebKit

/// Shows the live web view for a tab. The view belongs to the engine; this host only parents it.
struct WebViewHost: UIViewRepresentable {
    let tabID: UUID
    let engine: WebEngine
    /// Off while something is carried over the window, so the drop reaches the window, not the page.
    var isInteractive = true
    /// Whether this window still shows the tab, asked before taking its page back.
    var isWanted: () -> Bool = { true }
    var onTouch: () -> Void = {}

    func makeUIView(context: Context) -> WebContainerView {
        WebContainerView()
    }

    func updateUIView(_ container: WebContainerView, context: Context) {
        container.onTouch = onTouch
        container.isWanted = isWanted
        container.isUserInteractionEnabled = isInteractive
        container.show(engine.webView(for: tabID))
    }
}

final class WebContainerView: UIView, UIGestureRecognizerDelegate {
    /// Where a finger last pressed and held on a page, in screen points. A Glance grows from it.
    private static var lastPress: (point: CGPoint, at: Date)?
    static var recentPress: CGPoint? {
        guard let lastPress, Date.now.timeIntervalSince(lastPress.at) < 2 else { return nil }
        return lastPress.point
    }

    var onTouch: () -> Void = {}
    var isWanted: () -> Bool = { true }
    private weak var current: WKWebView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Web content swallows touches, so focus-follows-tap needs its own recognizer.
        let tap = UITapGestureRecognizer(target: self, action: #selector(touched))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.2
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delegate = self
        addGestureRecognizer(press)
        // A page shows in one window at a time. Another window may have held it while this one
        // was in the background; coming back, this window takes its page back.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneActivated(_:)), name: UIScene.didActivateNotification, object: nil
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reclaim()
    }

    @objc private func sceneActivated(_ note: Notification) {
        guard let scene = note.object as? UIWindowScene, scene === window?.windowScene else { return }
        reclaim()
    }

    private func reclaim() {
        guard window != nil, let current, current.superview !== self, isWanted() else { return }
        current.removeFromSuperview()
        current.frame = bounds
        addSubview(current)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ webView: WKWebView?) {
        if current === webView, webView?.superview === self { return }
        if let current, current.superview === self { current.removeFromSuperview() }
        current = webView
        guard let webView else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
    }

    @objc private func touched() { onTouch() }

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        Self.lastPress = (press.location(in: nil), .now)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
