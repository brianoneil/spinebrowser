import SwiftUI

/// One field for addresses, search, tab switching, the archive and commands.
/// It floats over the focused page. Tabs first, then actions, so you switch instead of duplicating.
struct CommandBar: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @FocusState private var isFieldFocused: Bool
    /// Global y of the keyboard's top edge; infinity while it's away.
    @State private var keyboardTop: CGFloat = .infinity
    @State private var resultsHeight: CGFloat = 0

    var body: some View {
        let space = store.activeSpace
        let sections = CommandModel.sections(for: query, in: store)
        // Return runs the top result. With nothing typed there is no top result to run.
        let first = query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sections.first?.results.first
        GeometryReader { geo in
            // Results stop above the keyboard and scroll when they don't fit.
            let top = geo.frame(in: .global).minY
            let visible = min(geo.size.height, keyboardTop - top)
            let resultsMax = max(88, visible - 54 - 57 - 16)
            ZStack(alignment: .top) {
                p.scrim
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityLabel("Dismiss command bar")
                    .accessibilityAddTraits(.isButton)
                    // The panel covers the scrim's centre, so assistive activation needs its own action.
                    .accessibilityAction { dismiss() }

                VStack(spacing: 0) {
                    field(space)
                    if !sections.isEmpty {
                        Rectangle().fill(p.line).frame(height: 1)
                        ScrollView {
                            results(sections, top: first, binding: space.binding)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultsHeight = $0 }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: min(resultsHeight, resultsMax))
                    }
                }
                .background(p.raised, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                .overlay {
                    if p.isDark {
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(p.line, lineWidth: 1)
                    }
                }
                .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.18), radius: 24, y: 12)
                .frame(maxWidth: 480)
                .padding(.horizontal, 16)
                .padding(.top, 54)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { isFieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            withAnimation(.easeOut(duration: 0.25)) { keyboardTop = frame?.minY ?? .infinity }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardTop = .infinity }
        }
    }

    private func results(_ sections: [CommandSection], top: CommandResult?, binding: SpaceBinding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sections) { section in
                SectionLabel(text: section.title, color: p.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                ForEach(section.results) { result in
                    CommandRow(result: result, isTop: result.id == top?.id, binding: binding) {
                        run(result)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private func field(_ space: Space) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(space.binding.ink(p))
            TextField("Search or command", text: $query)
                .font(.body)
                .foregroundStyle(p.text)
                .tint(p.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($isFieldFocused)
                .onSubmit {
                    let typed = !query.trimmingCharacters(in: .whitespaces).isEmpty
                    if typed, let top = CommandModel.sections(for: query, in: store).first?.results.first {
                        run(top)
                    } else {
                        dismiss()
                    }
                }
            // Names where the result will land.
            Text(space.name.uppercased())
                .font(Typeface.sectionLabel)
                .tracking(0.66)
                .foregroundStyle(space.binding.ink(p))
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(space.binding.tint(p), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private func run(_ result: CommandResult) {
        withAnimation(Motion.spring(reduce: reduceMotion)) {
            store.isCommandBarOpen = false
            CommandModel.run(result, in: store)
        }
    }

    private func dismiss() {
        withAnimation(Motion.spring(reduce: reduceMotion)) { store.isCommandBarOpen = false }
    }
}

private struct CommandRow: View {
    let result: CommandResult
    let isTop: Bool
    let binding: SpaceBinding
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 0) {
                    Text(result.title)
                        .font(isTop ? Typeface.rowActive : Typeface.row)
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    if let subtitle = result.subtitle {
                        Text(subtitle)
                            .font(Typeface.footnote)
                            .foregroundStyle(result.isArchive ? p.time : p.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let trailing = result.trailing {
                    Text(trailing).font(Typeface.footnoteStrong).foregroundStyle(binding.ink(p))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                if isTop {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(binding.tint(p))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var icon: some View {
        switch result.kind {
        case .tab(let tab):
            FaviconView(tab: tab, size: 24)
        case .archived(let item):
            FaviconView(archived: item, size: 24)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(p.time)
                        .background(Circle().fill(p.raised).padding(-1.5))
                        .offset(x: 3, y: 3)
                }
        default:
            Image(systemName: result.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.text)
                .frame(width: 24, height: 24)
                .background(p.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Model

struct CommandSection: Identifiable {
    let title: String
    let results: [CommandResult]
    var id: String { title }
}

struct CommandResult: Identifiable {
    enum Kind {
        case tab(BrowserTab)
        case open(URL)
        case archived(ArchivedTab)
        case pin(UUID), unpin(UUID)
        case moveToSpace(UUID, UUID)
        case togglePair
        case archiveToday
        case showArchive
        case newTab
        case spine(SpineState)
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    var trailing: String?
    var symbol = "arrow.right"

    var isArchive: Bool {
        if case .archived = kind { return true }
        return false
    }
}

@MainActor
enum CommandModel {
    static func sections(for rawQuery: String, in store: BrowserStore) -> [CommandSection] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        var sections: [CommandSection] = []

        let tabs = openTabs(matching: query, in: store)
        if !tabs.isEmpty { sections.append(CommandSection(title: "Open tabs", results: tabs)) }

        let actions = actions(matching: query, in: store)
        if !actions.isEmpty { sections.append(CommandSection(title: "Actions", results: actions)) }

        if !query.isEmpty {
            let archived = store.archive
                .compactMap { item in score(query, item.title + " " + (item.host ?? "")).map { ($0, item) } }
                .sorted { $0.0 > $1.0 }
                .prefix(3)
                .map { _, item in
                    CommandResult(
                        id: "archive-\(item.id)", kind: .archived(item), title: item.title,
                        subtitle: "Archived \(item.archivedAt.formatted(.relative(presentation: .named)))"
                    )
                }
            if !archived.isEmpty { sections.append(CommandSection(title: "Archive", results: archived)) }
        }
        return sections
    }

    private static func openTabs(matching query: String, in store: BrowserStore) -> [CommandResult] {
        let focusedID = store.focusedPane.tabID
        let candidates = store.tabs.filter { $0.id != focusedID && $0.url != nil }
        let ranked: [BrowserTab]
        if query.isEmpty {
            ranked = candidates
                .filter { $0.spaceID == nil || $0.spaceID == store.focusedPane.spaceID }
                .sorted { $0.lastActiveAt > $1.lastActiveAt }
        } else {
            ranked = candidates
                .compactMap { tab in score(query, tab.displayTitle + " " + (tab.host ?? "")).map { ($0, tab) } }
                .sorted { $0.0 > $1.0 }
                .map(\.1)
        }
        return ranked.prefix(query.isEmpty ? 3 : 4).map { tab in
            var place = tab.tier == .essential ? "Essentials" : tab.tier == .pinned ? "Pinned" : "Today"
            if let space = store.space(id: tab.spaceID), space.id != store.focusedPane.spaceID {
                place += " · \(space.name)"
            }
            if store.isPair, let side = store.paneIndex(showing: tab.id) {
                place += " · in the Pair, \(side == 0 ? "left" : "right") window"
            }
            return CommandResult(id: "tab-\(tab.id)", kind: .tab(tab), title: tab.displayTitle, subtitle: place, trailing: "Switch")
        }
    }

    private static func actions(matching query: String, in store: BrowserStore) -> [CommandResult] {
        var results: [CommandResult] = []
        // Actions name their target.
        let side = store.isPair ? (store.focusedPaneIndex == 0 ? " on the left" : " on the right") : ""

        if !query.isEmpty {
            if let url = NavigationInput.explicitURL(query) {
                results.append(CommandResult(id: "go", kind: .open(url), title: "Go to \(query)\(side)", symbol: "globe"))
            }
            if let url = NavigationInput.destination(for: query), NavigationInput.explicitURL(query) == nil {
                results.append(
                    CommandResult(id: "search", kind: .open(url), title: "Search “\(query)”\(side)", symbol: "magnifyingglass")
                )
            }
        }

        var commands: [CommandResult] = []
        if let tab = store.focusedTab, tab.url != nil {
            let short = tab.host ?? tab.displayTitle
            switch tab.tier {
            case .today:
                commands.append(CommandResult(
                    id: "pin", kind: .pin(tab.id), title: "Pin \(short) to \(store.activeSpace.name)", symbol: "pin"
                ))
            case .pinned:
                commands.append(CommandResult(id: "unpin", kind: .unpin(tab.id), title: "Unpin \(short)", symbol: "pin.slash"))
            case .essential:
                break
            }
            if tab.tier != .essential {
                for space in store.spaces where space.id != tab.spaceID {
                    commands.append(CommandResult(
                        id: "move-\(space.id)", kind: .moveToSpace(tab.id, space.id),
                        title: "Move \(short) to \(space.name)", symbol: "arrow.right.square"
                    ))
                }
            }
        }
        commands.append(CommandResult(
            id: "pair", kind: .togglePair, title: store.isPair ? "Close the Pair" : "Open a Pair",
            symbol: "rectangle.split.2x1"
        ))
        commands.append(CommandResult(id: "new", kind: .newTab, title: "New tab", symbol: "plus"))
        commands.append(CommandResult(
            id: "archive-today", kind: .archiveToday, title: "Archive all Today tabs", symbol: "archivebox"
        ))
        commands.append(CommandResult(id: "archive", kind: .showArchive, title: "Show the archive", symbol: "clock"))
        if !store.isPair {
            commands.append(CommandResult(id: "spine-sidebar", kind: .spine(.sidebar), title: "Spine: Sidebar", symbol: "sidebar.left"))
            commands.append(CommandResult(id: "spine-spines", kind: .spine(.spines), title: "Spine: Spines", symbol: "books.vertical"))
            commands.append(CommandResult(id: "spine-rail", kind: .spine(.rail), title: "Spine: Rail", symbol: "square.grid.3x1.below.line.grid.1x2"))
            commands.append(CommandResult(id: "spine-hidden", kind: .spine(.hidden), title: "Spine: Hidden", symbol: "rectangle"))
        }

        if query.isEmpty {
            results += commands.prefix(4)
        } else {
            results += commands
                .compactMap { command in score(query, command.title).map { ($0, command) } }
                .sorted { $0.0 > $1.0 }
                .prefix(3)
                .map(\.1)
        }
        return results
    }

    static func run(_ result: CommandResult, in store: BrowserStore) {
        switch result.kind {
        case .tab(let tab): store.select(tab.id)
        case .open(let url): store.open(url)
        case .archived(let item): store.restore(item.id)
        case .pin(let id): store.setTier(.pinned, for: id)
        case .unpin(let id): store.setTier(.today, for: id)
        case .moveToSpace(let id, let space): store.move(id, toSpace: space)
        case .togglePair: store.togglePair()
        case .archiveToday: store.archiveAllToday()
        case .showArchive: store.isArchiveOpen = true
        case .newTab: store.newTab()
        case .spine(let state): store.setSpine(state)
        }
    }

    /// Fuzzy match: every query character in order. Contiguous and word-start hits rank higher.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let hay = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }
        if let range = candidate.lowercased().range(of: query.lowercased()) {
            let atStart = range.lowerBound == candidate.startIndex
            return 1000 + (atStart ? 200 : 0) - hay.count
        }
        var score = 0
        var h = 0
        var previous = -2
        for character in needle {
            guard character != " " else { continue }
            var found = false
            while h < hay.count {
                if hay[h] == character {
                    score += h == previous + 1 ? 8 : 2
                    if h == 0 || hay[h - 1] == " " { score += 6 }
                    previous = h
                    h += 1
                    found = true
                    break
                }
                h += 1
            }
            if !found { return nil }
        }
        return score - hay.count / 4
    }
}
