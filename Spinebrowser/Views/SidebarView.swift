import SwiftUI

/// The Spine at 280pt: space header and bindings, Essentials, Pinned, Today with its copper
/// countdown, and Search or command. The home for organizing.
struct SidebarView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spineTopInset) private var spineTopInset

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
        .padding(.top, SpineMetrics.sidebarTop + spineTopInset)
        .padding(.leading, SpineMetrics.leading)
        .padding(.trailing, SpineMetrics.trailing)
        .padding(.bottom, SpineMetrics.bottom)
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
                    let index = store.spaces.firstIndex { $0.id == other.id } ?? 9
                    SpaceDot(space: other, isActive: other.id == space.id, ground: space.binding.tint(p),
                             activeSize: SpineMetrics.spaceDot)
                        .pointerHelp(index < 9 ? "\(other.name) (⌃\(index + 1))" : other.name)
                        .onTapGesture {
                            withAnimation(Motion.spring(reduce: reduceMotion)) { store.switchSpace(to: other.id) }
                        }
                        .contextMenu { SpaceMenu(space: other) }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(spaceSwipe)
        .contextMenu { SpaceMenu(space: space) }
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
        let gap = SpineMetrics.essentialGap
        let radius = SpineMetrics.essentialRadius
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: 4)
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(store.essentials) { tab in
                let isShown = store.paneIndex(showing: tab.id) != nil
                Button {
                    store.select(tab.id)
                } label: {
                    FaviconView(tab: tab, size: 22)
                        .frame(maxWidth: .infinity)
                        .frame(height: SpineMetrics.essentialHeight)
                        .background(p.raised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .overlay {
                            if isShown {
                                RoundedRectangle(cornerRadius: radius, style: .continuous)
                                    .strokeBorder(binding.ink(p), lineWidth: 1.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .pointerLift()
                .pointerHelp(tab.displayTitle)
                .accessibilityLabel(tab.displayTitle)
                .tabDragSource(tab)
                .contextMenu { TabMenu(tab: tab) }
            }
        }
        .keepDropTarget(.essential, radius: 18)
        .gesture(spaceSwipe)
    }

    // MARK: Pinned and Today

    @ViewBuilder
    private func pinned(_ space: Space) -> some View {
        let entries = store.spineEntries(in: space.id).pinned
        if !entries.isEmpty || store.drag != nil {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Pinned", color: space.binding.secondary(p))
                    .padding(.horizontal, SpineMetrics.rowInset)
                    .padding(.bottom, 6)
                if entries.isEmpty { PinPlaceholder() }
                ForEach(entries) { row($0, binding: space.binding) }
            }
            .keepDropTarget(.pinned, radius: 12)
        }
    }

    private func today(_ space: Space) -> some View {
        let entries = store.spineEntries(in: space.id).today
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(text: "Today", color: space.binding.secondary(p))
                Spacer()
                JustShelved(spaceID: space.id)
                ArchiveCountdown(spaceID: space.id)
            }
            .padding(.leading, SpineMetrics.rowInset)
            .padding(.trailing, 6)
            .padding(.bottom, 6)
            .frame(minHeight: 28)

            if entries.isEmpty {
                Text("Nothing open today.")
                    .font(Typeface.footnote)
                    .foregroundStyle(space.binding.secondary(p))
                    .padding(.horizontal, SpineMetrics.rowInset)
                    .padding(.vertical, SpineMetrics.rowVertical)
            }
            ForEach(entries) { row($0, binding: space.binding) }
        }
    }

    @ViewBuilder
    private func row(_ entry: SpineEntry, binding: SpaceBinding) -> some View {
        Group {
            switch entry {
            case .tab(let tab): TabRow(tab: tab, binding: binding)
            case .pair(let pair): PairRow(pair: pair, binding: binding)
            }
        }
        .transition(.spineRow(shelving: store.isShelving(entry), reduceMotion: reduceMotion))
    }

    // MARK: Command

    private func commandField(_ binding: SpaceBinding) -> some View {
        Button {
            store.isSidebarOverlayOpen = false
            store.isCommandBarOpen = true
        } label: {
            let label = HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Platform.isMac ? 12 : 13, weight: .bold))
                    .foregroundStyle(binding.ink(p))
                Text("Search or command")
                    .font(Platform.isMac ? Typeface.footnote : Typeface.row)
                    .foregroundStyle(Platform.isMac ? binding.secondary(p) : p.textSecondary)
                Spacer(minLength: 0)
            }
            if Platform.isMac {
                // A quiet field on the cloth, the height of a row.
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                label
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(p.raised.opacity(0.55), in: shape)
                    .overlay { shape.strokeBorder(binding.secondary(p).opacity(0.16), lineWidth: 1) }
                    .contentShape(shape)
            } else {
                label
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    .background(p.raised, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .pointerLift()
        .pointerHelp("Search or command (⌘L)")
    }
}

/// Long-press a space: name it, bind it, or start another.
struct SpaceMenu: View {
    let space: Space
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Button("Edit \(space.name)…", systemImage: "paintpalette") { store.editSpace(space.id) }
        if store.spaces.count < Library.maximumSpaces {
            Button("New space", systemImage: "plus.square.on.square") { store.newSpace() }
        }
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

/// Where the tabs went: "2 shelved" in copper for a few seconds after they go. Tap for the archive.
struct JustShelved: View {
    let spaceID: UUID
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let last = store.library.lastShelved, last.spaceIDs.contains(spaceID),
               context.date.timeIntervalSince(last.at) < 5 {
                Button {
                    store.isArchiveOpen = true
                } label: {
                    Label("\(last.count) shelved", systemImage: "archivebox")
                        .font(Typeface.countdown)
                        .foregroundStyle(p.time)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .accessibilityLabel("\(last.count) tabs moved to the archive. Show the archive")
            }
        }
        .animation(.easeOut(duration: 0.3), value: store.library.lastShelved?.at)
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
                    .pointerHelp(Self.shelvesAt(date))
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

    /// The clock time behind the countdown, for the pointer.
    static func shelvesAt(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "The next tab shelves at \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "The next tab shelves tomorrow at \(time)" }
        return "The next tab shelves \(date.formatted(.dateTime.weekday(.wide))) at \(time)"
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
    /// Under the Mac's pointer the row offers its ×.
    @State private var hovering = false

    var body: some View {
        let showsClose = Platform.isMac && hovering
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
                    // The title gives way to the ×, so the two never overlap.
                    .padding(.trailing, showsClose ? 20 : 0)
            }
            .padding(.vertical, SpineMetrics.rowVertical)
            .padding(.horizontal, SpineMetrics.rowInset)
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
        .pointerLift()
        .overlay(alignment: .trailing) {
            if showsClose {
                Button {
                    withAnimation(Motion.spring(reduce: reduceMotion)) { store.close(tab.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(binding.secondary(p))
                        .frame(width: 22, height: 22)
                        .background(binding.ink(p).opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 7)
                .transition(.opacity)
                .pointerHelp("Close tab (⌘W)")
                .accessibilityLabel("Close \(tab.displayTitle)")
            }
        }
        .onHover { over in
            withAnimation(.easeOut(duration: 0.12)) { hovering = over }
        }
        .offset(x: swipe)
        .opacity(1 - min(0.6, Double(-swipe) / 200))
        .simultaneousGesture(closeSwipe)
        .tabDragSource(tab)
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
            Button("Open on the left", systemImage: "rectangle.lefthalf.inset.filled") { store.place(tab.id, inPane: 0) }
            Button("Open on the right", systemImage: "rectangle.righthalf.inset.filled") { store.place(tab.id, inPane: 1) }
        } else if store.focusedPane.tabID != tab.id {
            Button("Open in a Pair", systemImage: "rectangle.split.2x1") { store.openPair(with: tab.id) }
        }

        Divider()
        Button("Close tab", systemImage: "xmark", role: .destructive) { store.close(tab.id) }
    }
}
