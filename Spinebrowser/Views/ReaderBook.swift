import SwiftUI

/// Reader when the Duo bends like a book: the crease becomes the gutter, the article runs across
/// two pages at a time, and the Spine becomes a thumb index cut into the left page's edge.
struct ReaderBook: View {
    let tab: BrowserTab
    /// The crease, in the layout's coordinates.
    let crease: CGRect
    let size: CGSize
    /// The system column on the right.
    let trailing: CGFloat

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @State private var turn: ReaderTurn?

    /// Text keeps 35.5pt off the crease on the left page and 26pt on the right, as Settings does.
    private static let beforeCrease: CGFloat = 35.5
    private static let afterCrease: CGFloat = 26
    private static let outerMargin: CGFloat = 70
    private static let columnTrailing: CGFloat = 27.5
    private static let top: CGFloat = 84
    private static let bottom: CGFloat = 69

    var body: some View {
        let preferences = store.settings.reader
        let tone = ReaderTone(preferences, isDark: p.isDark)
        let session = store.readerSession(for: tab.id)
        let right = size.width - trailing
        let width = floor(min(
            crease.minX - Self.beforeCrease - Self.outerMargin,
            right - Self.columnTrailing - (crease.maxX + Self.afterCrease)
        ))
        let gap = (crease.maxX + Self.afterCrease) - (crease.minX - Self.beforeCrease)
        let x0 = crease.minX - Self.beforeCrease - width
        let spread = tone.spread
        let page = session?.page ?? 0
        let pages = session?.pages ?? 1

        ZStack(alignment: .topLeading) {
            Color(hex: tone.desk)

            // Each page darkens toward the gutter; the gutter sinks deepest.
            LinearGradient(
                stops: [
                    .init(color: Color(hex: spread.page), location: 0),
                    .init(color: Color(hex: spread.toward), location: 0.78),
                    .init(color: Color(hex: spread.edge), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: crease.minX)
            LinearGradient(
                colors: [Color(hex: spread.gutter), Color(hex: spread.gutterDeep), Color(hex: spread.gutter)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: crease.width)
            .offset(x: crease.minX)
            LinearGradient(
                stops: [
                    .init(color: Color(hex: spread.edge), location: 0),
                    .init(color: Color(hex: spread.toward), location: 0.22),
                    .init(color: Color(hex: spread.page), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: max(0, right - crease.maxX))
            .offset(x: crease.maxX)

            // The margins turn pages too: back on the left, on on the right.
            Color.clear
                .frame(width: max(0, x0 - 44), height: size.height)
                .offset(x: 44)
                .contentShape(Rectangle())
                .onTapGesture { turn = ReaderTurn(forward: false) }
                .accessibilityHidden(true)
            Color.clear
                .frame(width: max(0, right - (x0 + width * 2 + gap)), height: size.height)
                .offset(x: x0 + width * 2 + gap)
                .contentShape(Rectangle())
                .onTapGesture { turn = ReaderTurn(forward: true) }
                .accessibilityHidden(true)

            if let article = session?.article {
                ReaderWebView(
                    tabID: tab.id, article: article, tone: tone, preferences: preferences,
                    flow: .paged(width: width, gap: gap, perSpread: 2), start: session?.progress ?? 0, turn: turn,
                    onState: { progress, page, pages in
                        store.library.readerMoved(tab.id, progress: progress, page: page, pages: pages)
                    },
                    onLink: { url in store.followReaderLink(url, in: tab.id) },
                    onPeek: { url in store.openGlance(url, from: tab.id, origin: WebContainerView.recentPress) }
                )
                .frame(width: width * 2 + gap, height: max(0, size.height - Self.top - Self.bottom))
                .offset(x: x0, y: Self.top)
            }

            ReaderChip(tab: tab, tone: tone, showsBackground: false)
                .offset(x: x0 - 4, y: 40)

            folio(page + 1, tone: tone)
                .position(x: x0 + width / 2, y: size.height - 43)
            if page + 2 <= pages {
                folio(page + 2, tone: tone)
                    .position(x: x0 + width + gap + width / 2, y: size.height - 43)
            }

            ThumbIndex(current: tab, tone: tone, height: size.height)
                .offset(y: 92)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay {
            // A Glance and the command bar take the right-hand page, never the gutter.
            GlanceOverlay(region: CGRect(x: crease.maxX, y: 0, width: max(0, right - crease.maxX), height: size.height))
        }
        .overlay(alignment: .topLeading) {
            if store.isCommandBarOpen {
                CommandBar()
                    .frame(width: max(0, right - crease.maxX), height: size.height)
                    .offset(x: crease.maxX)
                    .transition(.opacity)
            }
        }
        .accessibilityAction(named: "Next page") { turn = ReaderTurn(forward: true) }
        .accessibilityAction(named: "Previous page") { turn = ReaderTurn(forward: false) }
    }

    private func folio(_ number: Int, tone: ReaderTone) -> some View {
        Text("\(number)")
            .font(.system(size: 13, design: .serif).italic().monospacedDigit())
            .foregroundStyle(Color(hex: tone.secondary))
            .accessibilityLabel("Page \(number)")
    }
}

/// The Spine as a thumb index: tabs cut into the left page's outer edge, each in its space's cloth.
/// The open one stands proud, in paper. Same tabs, same order as the Spine.
private struct ThumbIndex: View {
    let current: BrowserTab
    let tone: ReaderTone
    let height: CGFloat

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        let room = max(1, Int((height - 92 - 80) / 102))
        let entries = store.spineEntries(in: store.activeSpace.id)
        let tabs = (entries.pinned + entries.today).compactMap { entry -> BrowserTab? in
            switch entry {
            case .tab(let tab): tab
            case .pair(let pair): pair.tabIDs.first.flatMap(store.tab(id:))
            }
        }
        // The open tab always has its place, even when the index runs long.
        let shown = Array(tabs.prefix(room)).contains(where: { $0.id == current.id })
            ? Array(tabs.prefix(room))
            : [current] + Array(tabs.filter { $0.id != current.id }.prefix(room - 1))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { tab in
                IndexTab(tab: tab, isCurrent: tab.id == current.id, tone: tone)
            }
        }
    }
}

private struct IndexTab: View {
    let tab: BrowserTab
    let isCurrent: Bool
    let tone: ReaderTone

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Kinfolk — Slow rooms" files under Kinfolk.
    private var shortTitle: String {
        let title = tab.displayTitle
        for separator in [" — ", " – ", " - ", " | ", ": ", " · "] {
            if let range = title.range(of: separator) { return String(title[..<range.lowerBound]) }
        }
        return title
    }

    var body: some View {
        let binding = (store.space(id: tab.spaceID) ?? store.activeSpace).binding
        let radius: CGFloat = isCurrent ? 12 : 10
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: radius, topTrailingRadius: radius,
            style: .continuous
        )
        Button {
            withAnimation(Motion.spring(reduce: reduceMotion)) { store.select(tab.id) }
        } label: {
            VStack(spacing: 8) {
                FaviconView(tab: tab, size: 16)
                Text(shortTitle)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color(hex: tone.text) : binding.secondary(p))
                    .lineLimit(1)
                    .frame(width: 56, alignment: .leading)
                    .rotationEffect(.degrees(90))
                    .frame(width: 16, height: 56)
            }
            .padding(.top, 10)
            .padding(.leading, isCurrent ? 13 : 8)
            .frame(width: isCurrent ? 42 : 32, height: 96, alignment: .topLeading)
            .background {
                shape.fill(isCurrent ? Color(hex: tone.background) : binding.tint(p))
                    .shadow(color: Color(hex: 0x221D18, opacity: isCurrent && !tone.isDark ? 0.12 : 0), radius: 4, x: 2)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Tabletop

/// Reader half-folded on a table: the page stands on the raised half, and everything you touch
/// lies flat under your hands. Nothing to tap sits up top but the page itself.
struct ReaderTabletop: View {
    let tab: BrowserTab
    let crease: CGRect
    let size: CGSize
    let insets: EdgeInsets

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn: ReaderTurn?
    @State private var seek: ReaderSeek?
    @State private var scrub: Double?
    @State private var isPanelOpen = false

    var body: some View {
        let preferences = store.settings.reader
        let tone = ReaderTone(preferences, isDark: p.isDark)
        let session = store.readerSession(for: tab.id)
        let width = floor(min(560, size.width - 64))
        let pageTop = insets.top + 12
        let pageHeight = max(0, crease.minY - 24 - pageTop)

        ZStack(alignment: .topLeading) {
            p.desk

            // The raised half: one page at a time, turned by the console below.
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color(hex: tone.background))
                .frame(width: size.width - 20, height: max(0, crease.minY - 10 - insets.top))
                .offset(x: 10, y: insets.top)
            if let article = session?.article {
                ReaderWebView(
                    tabID: tab.id, article: article, tone: tone, preferences: preferences,
                    flow: .paged(width: width, gap: 64, perSpread: 1), start: session?.progress ?? 0,
                    turn: turn, seek: seek,
                    onState: { progress, page, pages in
                        store.library.readerMoved(tab.id, progress: progress, page: page, pages: pages)
                    },
                    onLink: { url in store.followReaderLink(url, in: tab.id) },
                    onPeek: { url in store.openGlance(url, from: tab.id, origin: WebContainerView.recentPress) }
                )
                .frame(width: width, height: pageHeight)
                .offset(x: (size.width - width) / 2, y: pageTop)
            }

            console(session: session, tone: tone)
                .frame(width: size.width)
                .offset(y: crease.maxY + 18)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay {
            GlanceOverlay(region: CGRect(x: 0, y: insets.top, width: size.width, height: max(0, crease.minY - insets.top)))
        }
        .overlay(alignment: .topLeading) {
            if store.isCommandBarOpen {
                CommandBar()
                    .frame(width: size.width, height: max(0, crease.minY - insets.top))
                    .offset(y: insets.top)
                    .transition(.opacity)
            }
        }
    }

    private func console(session: ReaderSession?, tone: ReaderTone) -> some View {
        let page = (session?.page ?? 0) + 1
        let pages = session?.pages ?? 1
        let progress = scrub ?? session?.progress ?? 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(session?.article?.title ?? tab.displayTitle)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Spacer(minLength: 12)
                // Copper is time: where you are and how long is left.
                Text("Page \(page) of \(pages) · \(session?.timeLeft ?? "")")
                    .font(Typeface.footnote.monospacedDigit())
                    .foregroundStyle(p.time)
                    .lineLimit(1)
            }

            // The page follows the scrubber as it moves.
            Slider(value: Binding(get: { progress }, set: { value in
                scrub = value
                seek = ReaderSeek(progress: value)
            }), in: 0...1) { editing in
                if !editing { scrub = nil }
            }
            .tint(p.time)
            .accessibilityLabel("Place in the article")
            .accessibilityValue("Page \(page) of \(pages)")

            HStack(spacing: 12) {
                consoleButton("Previous page", symbol: "chevron.left") { turn = ReaderTurn(forward: false) }
                    .disabled(page <= 1)
                consoleButton("Next page", symbol: "chevron.right") { turn = ReaderTurn(forward: true) }
                    .disabled(page >= pages)
            }

            HStack(spacing: 12) {
                Button {
                    isPanelOpen = true
                } label: {
                    Text("Aa")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(p.text)
                        .frame(width: 64, height: 48)
                        .background(p.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.line, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reader type and theme")
                .popover(isPresented: $isPanelOpen) {
                    ReaderTypePanel(tabID: tab.id).presentationCompactAdaptation(.popover)
                }

                Spacer()

                Button {
                    withAnimation(Motion.spring(reduce: reduceMotion)) { store.toggleReader(tab.id) }
                } label: {
                    Text("Show the page")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.text)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(p.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.line, lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }

    /// Big targets that work without looking.
    private func consoleButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if symbol == "chevron.left" { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
                Text(label).font(.body.weight(.semibold))
                if symbol == "chevron.right" { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
            }
            .foregroundStyle(p.text)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(p.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.line, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
