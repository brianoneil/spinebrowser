import SwiftUI
import WebKit

/// A turn of the page asked for from outside the page: a margin tap, a button on the console.
struct ReaderTurn: Equatable {
    let id = UUID()
    var forward: Bool
}

/// A jump to a point in the article, from a scrubber.
struct ReaderSeek: Equatable {
    let id = UUID()
    var progress: Double
}

/// Hosts a tab's reader page. The page itself lives in the engine, so hiding Reader and showing it
/// again is instant and keeps your place, and moving between postures never rebuilds it.
struct ReaderWebView: UIViewRepresentable {
    let tabID: UUID
    let engine: WebEngine
    let article: Article
    let tone: ReaderTone
    let preferences: ReaderPreferences
    let flow: ReaderFlow
    /// Where to open, 0 to 1, when the page is new.
    var start: Double = 0
    var turn: ReaderTurn?
    var seek: ReaderSeek?
    /// Scroll-flow insets: room above the article for the chip and the pill.
    var topInset: CGFloat = 76
    var onState: (Double, Int, Int) -> Void = { _, _, _ in }
    var onLink: (URL) -> Void = { _ in }
    var onPeek: (URL) -> Void = { _ in }
    /// Reading down hides the pill; pulling back up shows it.
    var onReadingDown: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> ReaderHostView {
        ReaderHostView()
    }

    func updateUIView(_ host: ReaderHostView, context: Context) {
        host.show(engine.readerPage(for: tabID), with: self)
    }
}

/// Holds a reader page while it's on screen. During a change of posture two hosts can be alive at
/// once, the old one fading out. The newest host on screen owns the page; one on its way out never
/// takes it back, and only the owner gives the page its layout.
final class ReaderHostView: UIView {
    private var page: ReaderPageController?
    private var config: ReaderWebView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    func show(_ page: ReaderPageController, with config: ReaderWebView) {
        self.page = page
        self.config = config
        // Claim the page only when no other host on screen holds it.
        if page.view.superview !== self, page.view.superview?.window == nil, window != nil {
            claim()
        } else if page.view.superview === self {
            page.update(config)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Arriving on screen, this host takes the page, even from one still fading out.
        guard window != nil else { return }
        MainActor.assumeIsolated { claim() }
    }

    @MainActor
    private func claim() {
        guard let page, let config else { return }
        let view = page.view
        let moved = view.superview !== self
        if moved {
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        // Moved first, then laid out, so a new layout measures this window.
        page.update(config)
        if moved { page.attached() }
    }
}

/// One tab's article set in type: a web view that loads nothing but the article, with the page's
/// scripts off. Every reader page shares one cookie-free data store, so the article's images load
/// without your sign-ins.
@MainActor
final class ReaderPageController: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let world = WKContentWorld.world(name: "spine-reader-page")

    /// One configuration for every reader page: the paging script and the message route are set
    /// up once, and pages share a data store, so WebKit can keep their process warm.
    private static let configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.dataDetectorTypes = []
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: ReaderDocument.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world
        ))
        controller.add(ReaderMessageRouter.shared, contentWorld: world, name: "reader")
        return configuration
    }()

    let view: WKWebView
    private var parent: ReaderWebView?
    private var loadedKey: String?
    private var appliedStyle: [String: String] = [:]
    private var appliedFlow: ReaderFlow?
    private var lastTurn: UUID?
    private var lastSeek: UUID?
    private var state: (progress: Double, page: Int, pages: Int)?
    private var panAnchor: CGFloat = 0

    override init() {
        view = WKWebView(frame: .zero, configuration: Self.configuration)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isFindInteractionEnabled = true
        view.scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
        ReaderMessageRouter.shared.register(self, for: view)
    }

    /// A blank page, so the web process is up before the first article needs it.
    func warm() {
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
    }

    func close() {
        ReaderMessageRouter.shared.unregister(view)
        view.stopLoading()
        view.removeFromSuperview()
    }

    func update(_ next: ReaderWebView) {
        parent = next
        let style = ReaderDocument.variables(tone: next.tone, preferences: next.preferences)
        // A new article, or a switch between scrolling and pages, needs a fresh document.
        let key = "\(next.article.url.absoluteString)|\(next.article.html.count)|\(next.flow.isPaged)|\(perSpread(next.flow))|\(Int(next.topInset))"
        view.scrollView.isScrollEnabled = !next.flow.isPaged
        view.scrollView.bounces = !next.flow.isPaged
        if key != loadedKey {
            // The same article in a new shape opens where you were.
            let sameArticle = loadedKey?.hasPrefix("\(next.article.url.absoluteString)|\(next.article.html.count)|") ?? false
            let start = sameArticle ? (state?.progress ?? next.start) : next.start
            loadedKey = key
            appliedStyle = style
            appliedFlow = next.flow
            lastTurn = next.turn?.id
            lastSeek = next.seek?.id
            var html = ReaderDocument.html(
                article: next.article, tone: next.tone, preferences: next.preferences, flow: next.flow, start: start
            )
            if !next.flow.isPaged {
                html = html.replacingOccurrences(of: "<body class=\"scroll\"", with: "<body class=\"scroll\" style=\"--top: \(Int(next.topInset))px\"")
            }
            view.loadHTMLString(html, baseURL: nil)
            return
        }
        if style != appliedStyle {
            appliedStyle = style
            run("spineReader.restyle(\(json(style)))")
        }
        if next.flow != appliedFlow, case let .paged(width, gap, count) = next.flow {
            appliedFlow = next.flow
            run("spineReader.layout(\(width), \(gap), \(count))")
        }
        if let turn = next.turn, turn.id != lastTurn {
            lastTurn = turn.id
            run(turn.forward ? "spineReader.next()" : "spineReader.previous()")
        }
        if let seek = next.seek, seek.id != lastSeek {
            lastSeek = seek.id
            run("spineReader.goTo(\(seek.progress))")
        }
    }

    /// Back on screen with its place kept: tell the chip where that is.
    func attached() {
        guard let state else { return }
        Task { @MainActor [weak self] in self?.parent?.onState(state.progress, state.page, state.pages) }
    }

    private func perSpread(_ flow: ReaderFlow) -> Int {
        if case let .paged(_, _, count) = flow { return count }
        return 0
    }

    private func json(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func run(_ script: String) {
        view.evaluateJavaScript(script, in: nil, in: Self.world, completionHandler: nil)
    }

    func received(_ body: Any) {
        guard let message = body as? [String: Any], let kind = message["kind"] as? String, kind == "state" else { return }
        let value = (message["progress"] as? Double) ?? (message["progress"] as? NSNumber)?.doubleValue ?? 0
        let page = (message["page"] as? Int) ?? 0
        let pages = (message["pages"] as? Int) ?? 1
        state = (value, page, pages)
        parent?.onState(value, page, pages)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let scroll = pan.view as? UIScrollView, parent?.flow.isPaged == false else { return }
        let y = pan.translation(in: scroll).y
        switch pan.state {
        case .began:
            panAnchor = y
        case .changed, .ended:
            let atTop = scroll.contentOffset.y <= 1
            let delta = y - panAnchor
            if delta < -24 {
                parent?.onReadingDown(true)
                panAnchor = y
            } else if delta > 24 || (atTop && delta >= 0) {
                parent?.onReadingDown(false)
                panAnchor = y
            }
        default:
            break
        }
    }

    // The reader page loads only its own document. Links leave Reader for the real page.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == "about" { return .allow }
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true {
            parent?.onLink(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        parent?.onPeek(url)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: []) }
    }

    /// If WebKit ever drops the page's process, the next update loads the article again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadedKey = nil
        if let parent { update(parent) }
    }
}

/// The content controller keeps its handler alive, and every reader page shares one, so messages
/// find their page by the web view that sent them.
final class ReaderMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = ReaderMessageRouter()
    private var pages: [ObjectIdentifier: WeakReaderPage] = [:]

    @MainActor func register(_ page: ReaderPageController, for view: WKWebView) {
        pages[ObjectIdentifier(view)] = WeakReaderPage(page: page)
    }

    @MainActor func unregister(_ view: WKWebView) {
        pages[ObjectIdentifier(view)] = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated {
            guard let view = message.webView else { return }
            pages[ObjectIdentifier(view)]?.page?.received(body)
        }
    }
}

private struct WeakReaderPage {
    weak var page: ReaderPageController?
}

// MARK: - Reader in a window

/// Reader on the open display, flat, or in a window of the Pair: one scrolling column, 60 to 66
/// characters wide, on Reader's own paper.
struct ReaderPage: View {
    let tab: BrowserTab
    let paneIndex: Int

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let session = store.readerSession(for: tab.id)
        let preferences = store.settings.reader
        let tone = ReaderTone(preferences, isDark: p.isDark)
        GeometryReader { geo in
            // On a narrow page the chip sits under the pill instead of beside it.
            let narrow = geo.size.width < 560 && !store.isPair
            ZStack(alignment: .topLeading) {
                Color(hex: tone.background)
                if let article = session?.article {
                    ReaderWebView(
                        tabID: tab.id, engine: store.engine, article: article, tone: tone, preferences: preferences, flow: .scroll,
                        start: session?.progress ?? 0, topInset: narrow ? 112 : 76,
                        onState: { progress, page, pages in
                            store.library.readerMoved(tab.id, progress: progress, page: page, pages: pages)
                        },
                        onLink: { url in store.followReaderLink(url, in: tab.id) },
                        onPeek: { url in store.openGlance(url, from: tab.id, origin: WebContainerView.recentPress) },
                        onReadingDown: { down in store.setAddressHidden(down, for: tab.id) }
                    )
                    .transition(.opacity)
                } else if session?.failed == true {
                    ReaderUnavailable(tab: tab, tone: tone)
                }
                ReaderChip(tab: tab, tone: tone)
                    .padding(.leading, 18)
                    .padding(.top, narrow ? 62 : 16)
                    .opacity(store.isAddressHidden && !store.isPair ? 0 : 1)
                    .animation(Motion.spring(reduce: reduceMotion), value: store.isAddressHidden)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { store.focus(pane: paneIndex) })
        }
        .animation(.easeOut(duration: 0.2), value: session?.isReady)
    }
}

/// Readability found nothing worth reading. Say so, and offer the page back.
private struct ReaderUnavailable: View {
    let tab: BrowserTab
    let tone: ReaderTone
    @Environment(BrowserStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            Text("No article here")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(Color(hex: tone.text))
            Text("Reader works on pages with a story to tell. This one is mostly links and layout.")
                .font(.subheadline)
                .foregroundStyle(Color(hex: tone.secondary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Show the page") { store.toggleReader(tab.id) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: tone.link))
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Aa · Reader · 6 min left". Aa opens the type panel.
struct ReaderChip: View {
    let tab: BrowserTab
    let tone: ReaderTone
    var showsBackground = true

    @Environment(BrowserStore.self) private var store
    @State private var isPanelOpen = false

    var body: some View {
        let session = store.readerSession(for: tab.id)
        HStack(spacing: 10) {
            Button {
                isPanelOpen = true
            } label: {
                Text("Aa")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(hex: tone.text))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Color(hex: tone.sunken), in: Capsule())
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .accessibilityLabel("Reader type and theme")
            .popover(isPresented: $isPanelOpen, arrowEdge: .top) {
                ReaderTypePanel(tabID: tab.id)
                    .presentationCompactAdaptation(.popover)
            }

            Text(session?.isReady == true ? "Reader · \(session?.timeLeft ?? "")" : "Reader")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color(hex: tone.secondary))
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .background {
            if showsBackground {
                Capsule().fill(Color(hex: tone.background).opacity(0.94))
            }
        }
    }
}

/// Type size, face and paper. Changes land on the page as you make them, without losing your place.
struct ReaderTypePanel: View {
    let tabID: UUID

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preferences = store.settings.reader
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 0) {
                sizeButton(smaller: true, preferences: preferences)
                Text("\(preferences.size) pt")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(p.text)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Text size \(preferences.size) points")
                sizeButton(smaller: false, preferences: preferences)
            }
            .padding(3)
            .background(p.sunken, in: Capsule())

            HStack(spacing: 8) {
                ForEach(ReaderPreferences.Face.allCases) { face in
                    let isSelected = preferences.face == face
                    Button {
                        store.updateSettings { $0.reader.face = face }
                    } label: {
                        Text(face == .serif ? "New York" : "San Francisco")
                            .font(.system(size: 15, weight: isSelected ? .semibold : .regular, design: face == .serif ? .serif : .default))
                            .foregroundStyle(isSelected ? p.accentStrong : p.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background {
                                if isSelected {
                                    Capsule().fill(p.raised)
                                        .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.08), radius: 2, y: 1)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(p.sunken, in: Capsule())

            HStack(spacing: 10) {
                ForEach(ReaderPreferences.Theme.allCases) { theme in
                    ReaderThemeSwatch(theme: theme, isSelected: preferences.theme == theme) {
                        store.updateSettings { $0.reader.theme = theme }
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { store.settings.reader.trueBlack },
                set: { value in store.updateSettings { $0.reader.trueBlack = value } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("True black at night").font(.subheadline).foregroundStyle(p.text)
                    Text("Night pages go OLED black.").font(.footnote).foregroundStyle(p.textSecondary)
                }
            }
            .tint(p.accent)
            .disabled(preferences.theme == .day || preferences.theme == .sepia)

            Rectangle().fill(p.line).frame(height: 1)

            Button {
                dismiss()
                store.toggleReader(tabID)
            } label: {
                Label("Show the original page", systemImage: "doc.richtext")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 300)
        .background(p.raised)
    }

    private func sizeButton(smaller: Bool, preferences: ReaderPreferences) -> some View {
        let next = preferences.size + (smaller ? -1 : 1)
        let allowed = ReaderPreferences.sizes.contains(next)
        return Button {
            store.updateSettings { $0.reader.size = next.clamped(to: ReaderPreferences.sizes) }
        } label: {
            Text("A")
                .font(.system(size: smaller ? 13 : 19, weight: .semibold, design: .serif))
                .foregroundStyle(allowed ? p.text : p.textTertiary)
                .frame(width: 56, height: 38)
                .background(p.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(smaller ? "Smaller text" : "Larger text")
    }
}

/// A chip of Reader's paper with a line of its ink.
private struct ReaderThemeSwatch: View {
    let theme: ReaderPreferences.Theme
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var p

    private var label: String {
        switch theme {
        case .match: "Match"
        case .day: "Day"
        case .sepia: "Sepia"
        case .night: "Night"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if theme == .match {
                        HStack(spacing: 0) {
                            Color(hex: ReaderTone.day.background)
                            Color(hex: ReaderTone.night.background)
                        }
                    } else {
                        Color(hex: tone.background)
                    }
                    Text("Aa")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(theme == .match ? Color(hex: 0x8A8580) : Color(hex: tone.text))
                }
                .frame(width: 54, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? p.accent : p.line, lineWidth: isSelected ? 2 : 1)
                }
                Text(label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? p.accentStrong : p.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tone: ReaderTone {
        switch theme {
        case .match, .day: .day
        case .sepia: .sepia
        case .night: .night
        }
    }
}
