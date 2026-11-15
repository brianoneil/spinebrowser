import SwiftUI

/// Paper: one window onto a tab. Full-bleed web content with the URL pill as its only
/// persistent chrome. In the Pair each window carries a bar tinted by its binding.
struct PageCard: View {
    let paneIndex: Int
    /// The card meets the Spine with square corners so the active spine joins the page.
    var joined = false

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        if store.panes.indices.contains(paneIndex) {
            card(store.panes[paneIndex])
        }
    }

    private func card(_ pane: Pane) -> some View {
        let tab = pane.tabID.flatMap(store.tab(id:))
        let space = store.space(id: pane.spaceID) ?? store.activeSpace
        let isPair = store.isPair
        let isFocused = store.focusedPaneIndex == paneIndex
        let radius = Metrics.cardRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: joined ? 0 : radius, bottomLeadingRadius: joined ? 0 : radius,
            bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous
        )
        return VStack(spacing: 0) {
            if isPair {
                PairBar(paneIndex: paneIndex, tab: tab, space: space)
            }
            ZStack(alignment: .top) {
                if let tab, tab.url != nil {
                    WebViewHost(tabID: tab.id, engine: store.engine) { store.focus(pane: paneIndex) }
                } else {
                    StartPage(space: space)
                        .contentShape(Rectangle())
                        .onTapGesture { store.focus(pane: paneIndex) }
                }
                if let tab {
                    LoadingHairline(runtime: store.runtime[tab.id])
                }
                if !isPair, let tab, tab.url != nil {
                    AddressChrome(tab: tab)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.page)
        .overlay {
            if store.isCommandBarOpen, isFocused {
                CommandBar().transition(.opacity)
            }
        }
        .clipShape(shape)
        .overlay {
            // Exactly one window is focused, outlined in its binding's ink.
            if isPair, isFocused {
                shape.strokeBorder(space.binding.ink(p), lineWidth: 1.5)
            }
        }
        .background {
            if !p.isDark {
                shape.fill(p.page)
                    .shadow(color: Color(hex: 0x221D18, opacity: 0.06), radius: 1, y: 1)
                    .shadow(color: Color(hex: 0x221D18, opacity: 0.08), radius: 15, y: 10)
            }
        }
    }
}

/// The URL pill, or the nub it leaves behind once it has receded.
struct AddressChrome: View {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        // VoiceOver needs the address findable, so the pill stays put.
        let hidden = store.isAddressHidden && !voiceOver
        ZStack(alignment: .top) {
            URLPill(tab: tab)
                .padding(.top, 14)
                .offset(y: hidden && !reduceMotion ? -72 : 0)
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)

            if hidden {
                Button {
                    store.showAddress()
                } label: {
                    Capsule()
                        .fill(p.textTertiary.opacity(0.55))
                        .frame(width: 36, height: 5)
                        .frame(width: 88, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityLabel("Show address")
            }
        }
        .animation(Motion.spring(reduce: reduceMotion), value: hidden)
    }
}

/// Domain only. Tap or pull down for the command bar; flick up to put it away.
struct URLPill: View {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Upward travel while the pill is being flicked away. It follows the finger, never down.
    @State private var lift: CGFloat = 0
    /// Set while a drag is under way and briefly after, so the Button doesn't treat a flick as a tap.
    @State private var isDragging = false
    @State private var ignoreTapsUntil = Date.distantPast

    var body: some View {
        let runtime = store.runtime[tab.id]
        let url = store.currentURL(for: tab)
        let host = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "New tab"
        let insecure = runtime.map { !$0.isSecure } ?? (url?.scheme == "http")
        // A real Button, so the pill wins taps over the web page underneath. It fires on release while
        // the finger is still over the pill, and the pill follows the finger, so drags veto it.
        Button {
            guard !isDragging, Date.now >= ignoreTapsUntil else { return }
            store.isCommandBarOpen = true
        } label: {
            HStack(spacing: 6) {
                // A secure page shows its own icon when it has one; otherwise the lock holds the place.
                if !insecure, let icon = store.favicons.image(for: url?.host()) {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: insecure ? "exclamationmark.triangle.fill" : "lock")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(insecure ? p.danger : p.textSecondary)
                }
                if insecure {
                    // Madder always comes with a word.
                    Text("Not secure").font(Typeface.footnoteStrong).foregroundStyle(p.danger)
                }
                Text(host)
                    .font(Typeface.footnoteStrong)
                    .foregroundStyle(p.text)
                    .lineLimit(1)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background(p.raised, in: Capsule())
            .overlay {
                if p.isDark { Capsule().strokeBorder(p.line, lineWidth: 1) }
            }
            .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.14), radius: 5, y: 2)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .offset(y: lift)
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    isDragging = true
                    lift = min(0, value.translation.height)
                }
                .onEnded { value in
                    let spring = Motion.spring(reduce: reduceMotion)
                    if value.translation.height > 24 {
                        store.isCommandBarOpen = true
                    } else if value.translation.height < -24 || value.predictedEndTranslation.height < -60 {
                        withAnimation(spring) { store.hideAddress() }
                    }
                    withAnimation(spring) { lift = 0 }
                    isDragging = false
                    ignoreTapsUntil = .now.addingTimeInterval(0.3)
                }
        )
        .contextMenu {
            Button("Reload", systemImage: "arrow.clockwise") { store.engine.reload(tab.id) }
            if let url {
                Button("Copy link", systemImage: "link") { UIPasteboard.general.url = url }
            }
        }
        .accessibilityLabel("Address, \(host)")
        .accessibilityHint("Opens the command bar")
        .accessibilityAction(named: "Hide address") { store.hideAddress() }
    }
}

struct LoadingHairline: View {
    let runtime: TabRuntime?
    @Environment(\.palette) private var p

    var body: some View {
        if let runtime, runtime.isLoading {
            GeometryReader { geo in
                Capsule()
                    .fill(p.accent)
                    .frame(width: max(24, geo.size.width * runtime.progress), height: 2)
                    .animation(.easeOut(duration: 0.25), value: runtime.progress)
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
    }
}

/// The Pair's window bar: space chip, domain, window menu. Tinted by the window's binding.
struct PairBar: View {
    let paneIndex: Int
    let tab: BrowserTab?
    let space: Space

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = space.binding.ink(p)
        let host = tab.flatMap { store.currentURL(for: $0)?.host() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        ZStack {
            Button {
                store.focus(pane: paneIndex)
                store.isCommandBarOpen = true
            } label: {
                Text(host ?? "New tab")
                    .font(Typeface.footnote)
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                    .padding(.horizontal, 96)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                HStack(spacing: 6) {
                    Circle().fill(ink).frame(width: 7, height: 7)
                    Text(space.name).font(Typeface.footnoteStrong).foregroundStyle(ink).lineLimit(1)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(p.raised, in: Capsule())

                Spacer()

                Menu {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        if let tab { store.engine.reload(tab.id) }
                    }
                    Button("Swap sides", systemImage: "arrow.left.arrow.right") {
                        withAnimation(Motion.spring(reduce: reduceMotion)) { store.swapPair() }
                    }
                    Button("Close this window", systemImage: "xmark.rectangle") {
                        withAnimation(Motion.spring(reduce: reduceMotion)) { store.closePair(keeping: 1 - paneIndex) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(space.binding.secondary(p))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Window options")
            }
            .padding(.leading, 10)
        }
        .frame(height: 44)
        .background(space.binding.tint(p))
    }
}

/// A tab with nowhere to go yet. Quiet paper and one line.
struct StartPage: View {
    let space: Space
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 14) {
            Text("A fresh page")
                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                .foregroundStyle(p.text)
            Text("Search, paste a link, or type a command.")
                .font(.body)
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                store.isCommandBarOpen = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold))
                    Text("Search or command").font(Typeface.rowActive)
                }
                .foregroundStyle(space.binding.ink(p))
                .padding(.vertical, 12)
                .padding(.horizontal, 18)
                .background(space.binding.tint(p), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.page)
    }
}
