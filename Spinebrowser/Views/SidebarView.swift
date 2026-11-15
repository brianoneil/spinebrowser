import SwiftUI

/// The Spine at 280pt: space header and bindings, Essentials, Pinned, Today with its copper
/// countdown, and Search or command. The home for organizing.
struct SidebarView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let space = store.activeSpace
        let binding = space.binding
        VStack(alignment: .leading, spacing: 18) {
            header(space)
            essentials(binding)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pinned(space)
                    today(space)
                }
            }
            .scrollIndicators(.hidden)
            commandField(binding)
        }
        .padding(.top, 30)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.bottom, 22)
        .frame(width: Metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [binding.tint(p), binding.deep(p)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Header

    private func header(_ space: Space) -> some View {
        HStack {
            Text(space.name)
                .font(Typeface.spaceTitle)
                .foregroundStyle(space.binding.ink(p))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                ForEach(store.spaces) { other in
                    SpaceDot(space: other, isActive: other.id == space.id, ground: space.binding.tint(p))
                        .onTapGesture {
                            withAnimation(Motion.spring(reduce: reduceMotion)) { store.switchSpace(to: other.id) }
                        }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(spaceSwipe)
    }

    /// Horizontal swipe on the header or Essentials switches spaces.
    private var spaceSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                withAnimation(Motion.spring(reduce: reduceMotion)) {
                    store.stepSpace(by: value.translation.width < 0 ? 1 : -1)
                }
            }
    }

    // MARK: Essentials

    private func essentials(_ binding: SpaceBinding) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(store.essentials) { tab in
                let isShown = store.paneIndex(showing: tab.id) != nil
                Button {
                    store.select(tab.id)
                } label: {
                    FaviconView(tab: tab, size: 22)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(p.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            if isShown {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(binding.ink(p), lineWidth: 1.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.displayTitle)
                .contextMenu { TabMenu(tab: tab) }
            }
        }
        .gesture(spaceSwipe)
    }

    // MARK: Pinned and Today

    @ViewBuilder
    private func pinned(_ space: Space) -> some View {
        let tabs = store.pinned(in: space.id)
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Pinned", color: space.binding.secondary(p))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                ForEach(tabs) { tab in
                    TabRow(tab: tab, binding: space.binding)
                }
            }
        }
    }

    private func today(_ space: Space) -> some View {
        let tabs = store.today(in: space.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(text: "Today", color: space.binding.secondary(p))
                Spacer()
                ArchiveCountdown(spaceID: space.id)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
            .frame(minHeight: 28)

            if tabs.isEmpty {
                Text("Nothing open today.")
                    .font(Typeface.footnote)
                    .foregroundStyle(space.binding.secondary(p))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
            ForEach(tabs) { tab in
                TabRow(tab: tab, binding: space.binding)
            }
        }
    }

    // MARK: Command

    private func commandField(_ binding: SpaceBinding) -> some View {
        Button {
            store.isSidebarOverlayOpen = false
            store.isCommandBarOpen = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(binding.ink(p))
                Text("Search or command")
                    .font(Typeface.row)
                    .foregroundStyle(p.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(p.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A space's binding as a dot. The active one wears a ring; color is never the only cue,
/// so the label carries the name.
struct SpaceDot: View {
    let space: Space
    let isActive: Bool
    let ground: Color
    var activeSize: CGFloat = 16
    @Environment(\.palette) private var p

    var body: some View {
        let ink = space.binding.ink(p)
        Circle()
            .fill(ink)
            .frame(width: isActive ? activeSize : activeSize - 2, height: isActive ? activeSize : activeSize - 2)
            .padding(isActive ? 3.5 : 0)
            .background {
                if isActive {
                    Circle().fill(ground)
                    Circle().strokeBorder(ink, lineWidth: 1.5)
                }
            }
            .padding(6)
            .contentShape(Rectangle())
            .padding(-6)
            .accessibilityElement()
            .accessibilityLabel("\(space.name) space")
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// Copper counts down. The time until the next unpinned tab archives sits on the Today label,
/// never on a tab.
struct ArchiveCountdown: View {
    let spaceID: UUID
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let date = store.nextArchiveDate(in: spaceID) {
                let remaining = max(0, date.timeIntervalSince(context.date))
                Text(Self.format(remaining))
                    .font(Typeface.countdown)
                    .foregroundStyle(p.time)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(p.timeSoft, in: Capsule())
                    .accessibilityLabel("Next tab archives in \(Self.spoken(remaining))")
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? String(format: "%dh %02dm", h, m) : "\(m)m"
    }

    static func spoken(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hours \(minutes % 60) minutes" : "\(minutes) minutes"
    }
}

/// A Pinned or Today row: favicon and title, 15/20. The row on screen sits on paper.
struct TabRow: View {
    let tab: BrowserTab
    let binding: SpaceBinding

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipe: CGFloat = 0

    var body: some View {
        let shownIn = store.paneIndex(showing: tab.id)
        let isActive = shownIn != nil
        let isFocused = shownIn == store.focusedPaneIndex
        Button {
            store.select(tab.id)
        } label: {
            HStack(spacing: 10) {
                FaviconView(tab: tab, size: 20)
                Text(tab.displayTitle)
                    .font(isActive ? Typeface.rowActive : Typeface.row)
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.isPair, let shownIn {
                    Text(shownIn == 0 ? "Left" : "Right")
                        .font(Typeface.sectionLabel)
                        .foregroundStyle(binding.ink(p))
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(p.raised)
                        .opacity(isFocused ? 1 : 0.6)
                        .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.08), radius: 1, y: 1)
                        .shadow(color: binding.ink(p).opacity(p.isDark ? 0 : 0.10), radius: 6, y: 4)
                }
            }
            .overlay(alignment: .leading) {
                if isActive { ActiveMark(binding: binding, isFocused: isFocused).padding(.leading, 3) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .offset(x: swipe)
        .opacity(1 - min(0.6, Double(-swipe) / 200))
        .simultaneousGesture(closeSwipe)
        .contextMenu { TabMenu(tab: tab) }
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityAction(named: "Close") { store.close(tab.id) }
    }

    /// Swipe a row left to close it.
    private var closeSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                swipe = min(0, value.translation.width)
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                if horizontal, value.translation.width < -90 {
                    withAnimation(Motion.spring(reduce: reduceMotion)) { store.close(tab.id) }
                } else {
                    withAnimation(Motion.spring(reduce: reduceMotion)) { swipe = 0 }
                }
            }
    }
}

/// Long-press a tab: pin, move, pair, close.
struct TabMenu: View {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store

    var body: some View {
        switch tab.tier {
        case .today:
            Button("Pin to \(store.activeSpace.name)", systemImage: "pin") { store.setTier(.pinned, for: tab.id) }
            Button("Move to Essentials", systemImage: "square.grid.2x2") { store.setTier(.essential, for: tab.id) }
        case .pinned:
            Button("Unpin", systemImage: "pin.slash") { store.setTier(.today, for: tab.id) }
            Button("Move to Essentials", systemImage: "square.grid.2x2") { store.setTier(.essential, for: tab.id) }
        case .essential:
            Button("Move to Pinned in \(store.activeSpace.name)", systemImage: "pin") {
                store.setTier(.pinned, for: tab.id)
            }
        }

        if tab.tier != .essential {
            let others = store.spaces.filter { $0.id != tab.spaceID }
            if !others.isEmpty {
                Menu("Move to space", systemImage: "arrow.right.square") {
                    ForEach(others) { space in
                        Button("\(space.emoji) \(space.name)") { store.move(tab.id, toSpace: space.id) }
                    }
                }
            }
        }

        Divider()
        if store.isPair {
            Button("Open on the left", systemImage: "rectangle.lefthalf.inset.filled") { store.select(tab.id, inPane: 0) }
            Button("Open on the right", systemImage: "rectangle.righthalf.inset.filled") { store.select(tab.id, inPane: 1) }
        } else if store.focusedPane.tabID != tab.id {
            Button("Open in a Pair", systemImage: "rectangle.split.2x1") { store.openPair(with: tab.id) }
        }

        Divider()
        Button("Close tab", systemImage: "xmark", role: .destructive) { store.close(tab.id) }
    }
}
