import SwiftUI
import WebKit

/// Shows the live web view for a tab. The view belongs to the engine; this host only parents it.
struct WebViewHost: UIViewRepresentable {
    let tabID: UUID
    let engine: WebEngine
    var onTouch: () -> Void = {}

    func makeUIView(context: Context) -> WebContainerView {
        WebContainerView()
    }

    func updateUIView(_ container: WebContainerView, context: Context) {
        container.onTouch = onTouch
        container.show(engine.webView(for: tabID))
    }
}

final class WebContainerView: UIView, UIGestureRecognizerDelegate {
    var onTouch: () -> Void = {}
    private weak var current: WKWebView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Web content swallows touches, so focus-follows-tap needs its own recognizer.
        let tap = UITapGestureRecognizer(target: self, action: #selector(touched))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
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

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
