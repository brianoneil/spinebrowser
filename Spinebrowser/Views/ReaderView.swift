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

/// The article set in type: a web view of its own that loads nothing but the article, with scripts
/// for the page off. It keeps no cookies, so the article's images load without your sign-ins.
struct ReaderWebView: UIViewRepresentable {
    let tabID: UUID
    let article: Article
    let tone: ReaderTone
    let preferences: ReaderPreferences
    let flow: ReaderFlow
    /// Where to open, 0 to 1.
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

    static let world = WKContentWorld.world(name: "spine-reader-page")

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.dataDetectorTypes = []
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: ReaderDocument.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
        ))
        controller.add(context.coordinator.proxy, contentWorld: Self.world, name: "reader")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isFindInteractionEnabled = true
        view.scrollView.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.panned(_:)))
        context.coordinator.view = view
        context.coordinator.update(self)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var view: WKWebView?
        var parent: ReaderWebView?
        lazy var proxy = ReaderMessageProxy(coordinator: self)
        private var loadedKey: String?
        private var appliedStyle: [String: String] = [:]
        private var appliedFlow: ReaderFlow?
        private var lastTurn: UUID?
        private var lastSeek: UUID?
        private var progress: Double = 0
        private var panAnchor: CGFloat = 0

        func update(_ next: ReaderWebView) {
            parent = next
            guard let view else { return }
            let style = ReaderDocument.variables(tone: next.tone, preferences: next.preferences)
            // A new article, or a switch between scrolling and pages, needs a fresh document.
            let key = "\(next.article.url.absoluteString)|\(next.article.html.count)|\(next.flow.isPaged)|\(perSpread(next.flow))|\(Int(next.topInset))"
            view.scrollView.isScrollEnabled = !next.flow.isPaged
            view.scrollView.bounces = !next.flow.isPaged
            if key != loadedKey {
                let start = loadedKey == nil ? next.start : progress
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
            view?.evaluateJavaScript(script, in: nil, in: ReaderWebView.world, completionHandler: nil)
        }

        func received(_ body: Any) {
            guard let message = body as? [String: Any], let kind = message["kind"] as? String, kind == "state" else { return }
            let value = (message["progress"] as? Double) ?? (message["progress"] as? NSNumber)?.doubleValue ?? 0
            let page = (message["page"] as? Int) ?? 0
            let pages = (message["pages"] as? Int) ?? 1
            progress = value
            parent?.onState(value, page, pages)
        }

        @objc func panned(_ pan: UIPanGestureRecognizer) {
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
                if url.fragment != nil, url.scheme == "about" || url.absoluteString.hasPrefix("about:blank") { return .allow }
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
    }
}

/// The content controller keeps its handlers alive, so it holds this instead of the coordinator.
final class ReaderMessageProxy: NSObject, WKScriptMessageHandler {
    weak var coordinator: ReaderWebView.Coordinator?

    init(coordinator: ReaderWebView.Coordinator) { self.coordinator = coordinator }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { coordinator?.received(body) }
    }
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
                        tabID: tab.id, article: article, tone: tone, preferences: preferences, flow: .scroll,
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
