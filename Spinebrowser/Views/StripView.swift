import SwiftUI

/// The Spine at 56pt. Spines: tabs turned 90° like book spines. Rail: favicons only.
/// Both share one width, so switching between them never reflows the page.
struct StripView: View {
    let mode: SpineState

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spineTopInset) private var spineTopInset

    var body: some View {
        let space = store.activeSpace
        let binding = space.binding
        VStack(spacing: 14) {
            spaceMark(space)
            essentials
            rule
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // Pinned sit above the rule and Today below it, in both modes.
                        let entries = store.spineEntries(in: space.id)
                        if !entries.pinned.isEmpty || store.drag != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                if entries.pinned.isEmpty { PinPlaceholder(compact: true) }
                                ForEach(entries.pinned) { item($0) }
                            }
                            .keepDropTarget(.pinned, radius: 12)
                            rule.padding(.vertical, 4).padding(.leading, 7)
                        }
                        ForEach(entries.today) { item($0) }
                    }
                    .frame(width: 50, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                // A Pair on screen scrolls to its item; a tab on its own scrolls to itself.
                .onChange(of: store.shownPairID ?? store.focusedPane.tabID, initial: true) { _, anchor in
                    guard let anchor else { return }
                    withAnimation(Motion.spring(reduce: reduceMotion)) { scroller.scrollTo(anchor, anchor: .center) }
                }
            }
            expand(binding)
        }
        .padding(.top, SpineMetrics.stripTop + spineTopInset)
        .padding(.bottom, 16)
        .padding(.leading, 6)
        .frame(width: Metrics.stripWidth)
        .frame(maxHeight: .infinity)
        .background(binding.deep(p))
        // Pinch the strip to swap names for icons.
        .gesture(
            MagnifyGesture().onEnded { value in
                withAnimation(Motion.spring(reduce: reduceMotion)) {
                    if value.magnification < 0.85 { store.setSpine(.rail) }
                    if value.magnification > 1.15 { store.setSpine(.spines) }
                }
            }
        )
    }

    @ViewBuilder
    private func item(_ entry: SpineEntry) -> some View {
        let binding = store.activeSpace.binding
        Group {
            switch entry {
            case .pair(let pair):
                PairStripItem(pair: pair, binding: binding).id(pair.id)
            case .tab(let tab):
                tabItem(tab, binding: binding)
            }
        }
        .transition(.spineRow(shelving: store.isShelving(entry), reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func tabItem(_ tab: BrowserTab, binding: SpaceBinding) -> some View {
        if mode == .rail {
            RailItem(tab: tab, binding: binding).id(tab.id)
        } else {
            SpineItem(tab: tab, binding: binding).id(tab.id)
        }
    }

    private func spaceMark(_ space: Space) -> some View {
        Button {
            let next = store.spaces.firstIndex { $0.id == space.id }.map { ($0 + 1) % store.spaces.count } ?? 0
            withAnimation(Motion.spring(reduce: reduceMotion)) { store.switchSpace(to: store.spaces[next].id) }
        } label: {
            let ink = space.binding.ink(p)
            Circle()
                .fill(ink)
                .frame(width: 22, height: 22)
                .padding(4.5)
                .background {
                    Circle().fill(space.binding.deep(p))
                    Circle().strokeBorder(ink, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .pointerLift()
        .contextMenu { SpaceMenu(space: space) }
        .padding(.trailing, 6)
        .accessibilityLabel("\(space.name) space. Switch space")
    }

    private var essentials: some View {
        VStack(spacing: 8) {
            ForEach(store.essentials) { tab in
                Button {
                    store.select(tab.id)
                } label: {
                    FaviconView(tab: tab, size: 19)
                        .padding(4)
                        .contentShape(Rectangle())
                        .padding(-4)
                }
                .buttonStyle(.plain)
                .pointerLift()
                .accessibilityLabel(tab.displayTitle)
                .tabDragSource(tab)
                .contextMenu { TabMenu(tab: tab) }
            }
        }
        .keepDropTarget(.essential, radius: 12)
        .padding(.trailing, 6)
    }

    private var rule: some View {
        Rectangle()
            .fill(p.isDark ? p.line : store.activeSpace.binding.secondary(p).opacity(0.25))
            .frame(width: 30, height: 1)
            .padding(.trailing, 6)
    }

    /// » snaps back to the full Sidebar.
    private func expand(_ binding: SpaceBinding) -> some View {
        Button {
            withAnimation(Motion.spring(reduce: reduceMotion)) { store.setSpine(.sidebar) }
        } label: {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(binding.ink(p))
                .frame(width: 36, height: 36)
                .background(binding.tint(p), in: Circle())
        }
        .buttonStyle(.plain)
        .pointerLift()
        .padding(.trailing, 6)
        .accessibilityLabel("Show sidebar")
    }
}

/// One tab as a book spine: favicon upright, title running down. The active spine joins the
/// page — same surface, no gap — and carries the ×.
private struct SpineItem: View {
    let tab: BrowserTab
    let binding: SpaceBinding

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isActive = store.paneIndex(showing: tab.id) != nil
        let joins = isActive && !store.isPair
        let width: CGFloat = joins ? 50 : 44
        let titleLength: CGFloat = isActive ? 76 : 92
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 12, bottomLeadingRadius: 12,
            bottomTrailingRadius: joins ? 0 : 12, topTrailingRadius: joins ? 0 : 12,
            style: .continuous
        )
        Button {
            store.select(tab.id)
        } label: {
            VStack(spacing: 11) {
                FaviconView(tab: tab, size: 20)
                Text(tab.displayTitle)
                    .font(isActive ? Typeface.footnoteStrong : Typeface.footnote)
                    .foregroundStyle(isActive ? p.text : binding.secondary(p))
                    .lineLimit(1)
                    .frame(width: titleLength, height: 18, alignment: .leading)
                    .rotationEffect(.degrees(90))
                    .frame(width: 18, height: titleLength)
                Spacer(minLength: 0)
            }
            .padding(.top, 13)
            .frame(width: width, height: 150)
            .background(isActive ? p.page : binding.tint(p), in: shape)
            .overlay(alignment: .topLeading) {
                if isActive {
                    ActiveMark(
                        binding: binding,
                        isFocused: store.paneIndex(showing: tab.id) == store.focusedPaneIndex,
                        height: 24
                    )
                    .padding(.leading, 3)
                    .padding(.top, 11)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointerLift()
        .overlay(alignment: .bottom) {
            if isActive {
                Button {
                    withAnimation(Motion.spring(reduce: reduceMotion)) { store.close(tab.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(p.textSecondary)
                        .frame(width: 36, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerLift()
                .padding(.bottom, 4)
                .accessibilityLabel("Close \(tab.displayTitle)")
            }
        }
        .tabDragSource(tab)
        .contextMenu { TabMenu(tab: tab) }
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// One tab as an icon. A copper dot marks a tab about to archive.
private struct RailItem: View {
    let tab: BrowserTab
    let binding: SpaceBinding

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        let isActive = store.paneIndex(showing: tab.id) != nil
        let isFocused = store.paneIndex(showing: tab.id) == store.focusedPaneIndex
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 0, topTrailingRadius: 0,
            style: .continuous
        )
        Button {
            store.select(tab.id)
        } label: {
            FaviconView(tab: tab, size: 20)
                .overlay(alignment: .topTrailing) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if let date = store.archiveDate(for: tab), date.timeIntervalSince(context.date) < 3600 {
                            Circle()
                                .fill(p.time)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(binding.deep(p), lineWidth: 1))
                                .offset(x: 3, y: -3)
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .frame(width: 50, alignment: .leading)
                .background {
                    if isActive { shape.fill(p.page).opacity(isFocused ? 1 : 0.6) }
                }
                .overlay(alignment: .leading) {
                    if isActive { ActiveMark(binding: binding, isFocused: isFocused).padding(.leading, 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerLift()
        .tabDragSource(tab)
        .contextMenu { TabMenu(tab: tab) }
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The active tab's ink mark: a short bar on its leading edge, in the space's binding. Paler on the
/// unfocused window of a Pair.
struct ActiveMark: View {
    let binding: SpaceBinding
    var isFocused = true
    var height: CGFloat = 20

    @Environment(\.palette) private var p

    var body: some View {
        Capsule()
            .fill(binding.ink(p))
            .frame(width: 3, height: height)
            .opacity(isFocused ? 1 : 0.45)
            .accessibilityHidden(true)
    }
}
