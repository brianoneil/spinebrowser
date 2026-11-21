import SwiftUI

/// One field for addresses, search, tab switching, the archive and commands.
/// It floats over the focused page. Tabs first, then actions, so you switch instead of duplicating.
struct CommandBar: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What you typed. The field may show more: a completion, selected after it.
    @State private var query = ""
    /// Just deleted, so no completion until the next character typed.
    @State private var isDeleting = false
    /// Global y of the keyboard's top edge; infinity while it's away.
    @State private var keyboardTop: CGFloat = .infinity
    @State private var resultsHeight: CGFloat = 0
    /// iOS says a link is on the clipboard. Checking doesn't read it, so no paste alert shows.
    @State private var clipboardHasLink = false

    var body: some View {
        let space = store.activeSpace
        let completion = currentCompletion
        let sections = CommandModel.sections(for: query, in: store, clipboardHasLink: clipboardHasLink, completion: completion)
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
                    field(space, suffix: completion?.suffix ?? "")
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
        .task { await checkClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            Task { await checkClipboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkClipboard() }
        }
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

    private var currentCompletion: CommandCompletion? {
        isDeleting ? nil : CommandModel.completion(for: query, in: store)
    }

    private func field(_ space: Space, suffix: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(space.binding.ink(p))
            CompletingTextField(
                placeholder: "Search or command", text: $query, isDeleting: $isDeleting, suffix: suffix,
                textColor: p.text, tint: p.accent, highlight: space.binding.tint(p)
            ) {
                let typed = !query.trimmingCharacters(in: .whitespaces).isEmpty
                let sections = CommandModel.sections(
                    for: query, in: store, clipboardHasLink: clipboardHasLink, completion: currentCompletion
                )
                if typed, let top = sections.first?.results.first {
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

    private func checkClipboard() async {
        let board = UIPasteboard.general
        if board.hasURLs {
            clipboardHasLink = true
        } else if board.hasStrings {
            let found = try? await board.detectedPatterns(for: [\.probableWebURL])
            clipboardHasLink = found?.contains(\.probableWebURL) ?? false
        } else {
            clipboardHasLink = false
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
                        // An address is the destination itself, so it reads a size up from the rows around it.
                        .font(result.isDestination ? .headline : isTop ? Typeface.rowActive : Typeface.row)
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                        .truncationMode(result.isDestination ? .middle : .tail)
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
        .accessibilityLabel(result.spokenTitle ?? result.title)
    }

    @ViewBuilder
    private var icon: some View {
        if result.isDestination {
            // A bare arrow, quieter than the address it points at.
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 24, height: 24)
        } else {
            glyph
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch result.kind {
        case .tab(let tab):
            FaviconView(tab: tab, size: 24)
        case .visit(let visit):
            FaviconView(visit: visit, size: 24)
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

/// The rest of an address the field fills in, and where Return then goes.
struct CommandCompletion {
    let suffix: String
    let result: CommandResult
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct CommandSection: Identifiable {
    let title: String
    let results: [CommandResult]
    var id: String { title }
}

struct CommandResult: Identifiable {
    enum Kind {
        case tab(BrowserTab)
        case open(URL)
        case visit(Visit)
        case pasteAndGo
        case archived(ArchivedTab)
        case pin(UUID), unpin(UUID)
        case moveToSpace(UUID, UUID)
        case togglePair
        case archiveToday
        case showArchive
        case showSettings
        case newTab
        case spine(SpineState)
        case reader(UUID)
        case editSpace
        case newSpace
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    var trailing: String?
    var symbol = "arrow.right"
    /// An address you typed: the row shows an arrow and the address, nothing else.
    var isDestination = false
    /// What VoiceOver reads when the title alone doesn't say what the row does.
    var spokenTitle: String?

    var isArchive: Bool {
        if case .archived = kind { return true }
        return false
    }
}

@MainActor
enum CommandModel {
    static func sections(
        for rawQuery: String, in store: BrowserStore, clipboardHasLink: Bool = false, completion: CommandCompletion? = nil
    ) -> [CommandSection] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        var sections: [CommandSection] = []

        // The address the field finished leads, or else the address as typed: Return goes
        // where the field says.
        let top = query.isEmpty ? nil : completion?.result ?? goTo(query, in: store)
        let topTabID: UUID? = if case .tab(let tab) = top?.kind { tab.id } else { nil }
        let tabs = openTabs(matching: query, in: store).filter { result in
            guard case .tab(let tab) = result.kind else { return true }
            return tab.id != topTabID
        }
        let actions = actions(matching: query, in: store)
        let tabSection = tabs.isEmpty ? nil : CommandSection(title: "Open tabs", results: tabs)
        let actionSection = actions.isEmpty ? nil : CommandSection(title: "Actions", results: actions)

        if query.isEmpty {
            if clipboardHasLink {
                let paste = CommandResult(
                    id: "paste", kind: .pasteAndGo, title: "Go to copied link\(side(in: store))", symbol: "doc.on.clipboard"
                )
                sections.append(CommandSection(title: "Clipboard", results: [paste]))
            }
            if let tabSection { sections.append(tabSection) }
            let frequent = frequentSites(in: store, besides: tabs)
            if !frequent.isEmpty { sections.append(CommandSection(title: "Frequent", results: frequent)) }
            let recent = recentVisits(in: store, besides: frequent)
            if !recent.isEmpty { sections.append(CommandSection(title: "Recent", results: recent)) }
            if let actionSection { sections.append(actionSection) }
            return sections
        }

        if let top { sections.append(CommandSection(title: "Top hit", results: [top])) }

        // Tabs lead, so you switch instead of duplicating, unless a command is a clearly better hit:
        // "set" should run Settings, not a tab whose letters happen to line up.
        if commandLeads(query, tabs: tabs, actions: actions) {
            sections += [actionSection, tabSection].compactMap { $0 }
        } else {
            sections += [tabSection, actionSection].compactMap { $0 }
        }

        let archivedItems = store.archive
            .compactMap { item in score(query, item.title + " " + (item.host ?? "")).map { ($0, item) } }
            .sorted { $0.0 > $1.0 }
            .prefix(3)
            .map(\.1)

        // History skips what's already a tap away: open tabs, the top hit, archive matches.
        var shown = openURLs(in: store).union(archivedItems.compactMap { History.key(for: $0.url) })
        if case .open(let url) = top?.kind, let page = History.key(for: url) { shown.insert(page) }
        let history = historyMatches(query, in: store, besides: shown)
        if !history.isEmpty { sections.append(CommandSection(title: "History", results: history)) }

        let archived = archivedItems.map { item in
            CommandResult(
                id: "archive-\(item.id)", kind: .archived(item), title: item.title,
                subtitle: "Archived \(item.archivedAt.formatted(.relative(presentation: .named)))"
            )
        }
        if !archived.isEmpty { sections.append(CommandSection(title: "Archive", results: archived)) }
        return sections
    }

    /// Names the window a result lands in, when there are two.
    private static func side(in store: BrowserStore) -> String {
        store.isPair ? (store.focusedPaneIndex == 0 ? " on the left" : " on the right") : ""
    }

    private static func goTo(_ query: String, in store: BrowserStore) -> CommandResult? {
        guard let url = NavigationInput.explicitURL(query) else { return nil }
        let side = side(in: store)
        // In a Pair the window it lands in moves to the subtitle, so the address stands alone.
        return CommandResult(
            id: "go", kind: .open(url), title: query,
            subtitle: side.isEmpty ? nil : (store.focusedPaneIndex == 0 ? "Left window" : "Right window"),
            isDestination: true, spokenTitle: "Go to \(query)\(side)"
        )
    }

    /// Finishes an address you've started from the places you've been: "nyt" → nytimes.com,
    /// "nytimes.com/se" → a section you read. An open tab wins, so you switch instead of
    /// opening a second copy. Otherwise a site counts once it's a habit (two visits) or fresh
    /// (visited today or within the hour). A command whose name starts with what you typed
    /// beats history: "set" still runs Settings.
    static func completion(for raw: String, in store: BrowserStore, now: Date = .now) -> CommandCompletion? {
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        // Match past a scheme or www. you typed, but keep them in what the field shows.
        var typed = raw.lowercased()
        for scheme in ["https://", "http://"] where typed.hasPrefix(scheme) { typed.removeFirst(scheme.count) }
        if typed.hasPrefix("www.") { typed.removeFirst(4) }
        guard !typed.isEmpty else { return nil }
        let wantsPath = typed.contains("/")
        let searchHost = searchEngineHost

        /// The ways an address can be typed: "wik" finds en.wikipedia.org because any part of
        /// the host can start it, short of the TLD. Paths only once you've typed a slash.
        func forms(host: String, url: URL) -> [String] {
            let labels = host.split(separator: ".")
            let hosts = labels.indices.dropLast().map { labels[$0...].joined(separator: ".") }
            guard wantsPath else { return hosts }
            var path = url.path()
            if let query = url.query() { path += "?" + query }
            return path.count > 1 ? hosts.map { $0 + path } : []
        }
        /// The first form that runs on past what you typed; the field shows the rest.
        func rest(of forms: [String]) -> String? {
            forms.first { $0.count > typed.count && $0.lowercased().hasPrefix(typed) }.map { String($0.dropFirst(typed.count)) }
        }
        func bareHost(_ url: URL) -> String? {
            url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }.flatMap { $0 == searchHost ? nil : $0 }
        }

        let spaceID = store.focusedPane.spaceID
        let side = side(in: store)
        let window = side.isEmpty ? nil : (store.focusedPaneIndex == 0 ? "Left window" : "Right window")

        // Open tabs in this Space and Essentials, the one you used last first.
        let tabMatch = store.tabs
            .filter { $0.id != store.focusedPane.tabID && ($0.spaceID == nil || $0.spaceID == spaceID) }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .lazy
            .compactMap { tab -> (String, BrowserTab)? in
                guard let url = store.library.currentURL(for: tab), let host = bareHost(url) else { return nil }
                return rest(of: forms(host: host, url: url)).map { ($0, tab) }
            }
            .first
        if let (suffix, tab) = tabMatch {
            let result = CommandResult(
                id: "complete-tab-\(tab.id)", kind: .tab(tab), title: tab.displayTitle,
                subtitle: place(of: tab, in: store), trailing: "Switch"
            )
            return CommandCompletion(suffix: suffix, result: result)
        }

        let commandStartsWithIt = commands(in: store).contains { $0.title.lowercased().hasPrefix(typed) }
        guard !commandStartsWithIt else { return nil }

        let bySite = Dictionary(grouping: store.library.history.visits(in: spaceID)) { $0.host ?? "" }
        var best: (rank: Double, suffix: String, url: URL, title: String?)?
        for (_, pages) in bySite {
            guard let host = pages.first.flatMap({ bareHost($0.url) }) else { continue }
            let isHabit = pages.reduce(0) { $0 + $1.visitCount } >= 2
            let isFresh = pages.contains { Calendar.current.isDateInToday($0.lastVisitedAt) || now.timeIntervalSince($0.lastVisitedAt) < 3_600 }
            guard isHabit || isFresh else { continue }
            if wantsPath {
                for page in pages {
                    let rank = page.frecency(now: now)
                    guard rank > best?.rank ?? -1, let suffix = rest(of: forms(host: host, url: page.url)) else { continue }
                    best = (rank, suffix, page.url, page.displayTitle)
                }
            } else {
                let rank = pages.reduce(0) { $0 + $1.frecency(now: now) }
                guard rank > best?.rank ?? -1, let suffix = rest(of: forms(host: host, url: pages[0].url)),
                      var root = URLComponents(url: pages[0].url, resolvingAgainstBaseURL: false) else { continue }
                // A host completes to the site's front door, which is what the field shows.
                root.path = "/"
                root.query = nil
                root.fragment = nil
                guard let url = root.url else { continue }
                let home = pages.first { History.key(for: $0.url) == History.key(for: url) }
                best = (rank, suffix, url, home?.displayTitle)
            }
        }
        guard let best else { return nil }
        let shown = raw + best.suffix
        let result = CommandResult(
            id: "complete", kind: .open(best.url), title: shown,
            subtitle: [best.title, window].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            isDestination: true, spokenTitle: "Go to \(shown)\(side)"
        )
        return CommandCompletion(suffix: best.suffix, result: result)
    }

    /// The search engine's host. It never completes or counts as Frequent: every search would
    /// otherwise make it your top site.
    private static var searchEngineHost: String? {
        NavigationInput.destination(for: "spine search")?.host().map {
            $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
        }
    }

    private static func frequentCandidates(in store: BrowserStore) -> [Visit] {
        store.library.history.frequentSites(
            in: store.focusedPane.spaceID, excludingHosts: Set([searchEngineHost].compactMap { $0 })
        )
    }

    /// Sites you keep coming back to. One that's already open switches to its tab instead.
    private static func frequentSites(in store: BrowserStore, besides listed: [CommandResult]) -> [CommandResult] {
        let focused = store.focusedTab
        let listedTabs = Set(listed.compactMap { result -> UUID? in
            if case .tab(let tab) = result.kind { return tab.id }
            return nil
        })
        let spaceID = store.focusedPane.spaceID
        var results: [CommandResult] = []
        for site in frequentCandidates(in: store) {
            guard results.count < 4 else { break }
            guard let host = site.host, host != focused?.host else { continue }
            let open = store.tabs.first {
                $0.id != focused?.id && $0.host == host && ($0.spaceID == nil || $0.spaceID == spaceID)
            }
            if let open {
                if listedTabs.contains(open.id) { continue }
                results.append(CommandResult(
                    id: "frequent-\(site.id)", kind: .tab(open), title: open.displayTitle, subtitle: host, trailing: "Switch"
                ))
            } else {
                results.append(CommandResult(
                    id: "frequent-\(site.id)", kind: .visit(site), title: site.displayTitle, subtitle: host
                ))
            }
        }
        return results
    }

    /// Pages you were on lately that aren't open now and aren't one of your frequent sites.
    private static func recentVisits(in store: BrowserStore, besides frequent: [CommandResult]) -> [CommandResult] {
        let open = openURLs(in: store)
        let frequentHosts = Set(frequent.compactMap { result -> String? in
            switch result.kind {
            case .visit(let visit): visit.host
            case .tab(let tab): tab.host
            default: nil
            }
        })
        return store.library.history.recent(in: store.focusedPane.spaceID)
            .filter { !open.contains($0.url) && !frequentHosts.contains($0.host ?? "") }
            .prefix(3)
            .map { visit in
                CommandResult(
                    id: "recent-\(visit.id)", kind: .visit(visit), title: visit.displayTitle,
                    subtitle: "\(visit.host ?? "") · \(visit.lastVisitedAt.formatted(.relative(presentation: .named)))"
                )
            }
    }

    /// Visited pages whose title or address holds what you typed, the ones you visit most first.
    /// Only whole runs count: history is long, and letters scattered through it match everything.
    private static func historyMatches(_ query: String, in store: BrowserStore, besides shown: Set<URL>) -> [CommandResult] {
        let now = Date.now
        return store.library.history.visits(in: store.focusedPane.spaceID)
            .filter { !shown.contains($0.url) }
            .compactMap { visit -> (rank: Double, visit: Visit)? in
                let text = visit.displayTitle + " " + (visit.host ?? "") + visit.url.path()
                guard let s = score(query, text), s >= strongMatch else { return nil }
                return (visit.frecency(now: now), visit)
            }
            .sorted { $0.rank > $1.rank }
            .prefix(4)
            .map { match in
                CommandResult(
                    id: "history-\(match.visit.id)", kind: .visit(match.visit), title: match.visit.displayTitle,
                    subtitle: match.visit.host
                )
            }
    }

    /// Pages open in a tab right now.
    private static func openURLs(in store: BrowserStore) -> Set<URL> {
        Set(store.tabs.flatMap { tab in
            [tab.url, store.library.currentURL(for: tab)].compactMap { $0.flatMap(History.key(for:)) }
        })
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
            CommandResult(id: "tab-\(tab.id)", kind: .tab(tab), title: tab.displayTitle, subtitle: place(of: tab, in: store), trailing: "Switch")
        }
    }

    /// Where a tab lives: its tier, its Space when it's another one, and its side of the Pair.
    private static func place(of tab: BrowserTab, in store: BrowserStore) -> String {
        var place = tab.tier == .essential ? "Essentials" : tab.tier == .pinned ? "Pinned" : "Today"
        if let space = store.space(id: tab.spaceID), space.id != store.focusedPane.spaceID {
            place += " · \(space.name)"
        }
        if store.isPair, let side = store.paneIndex(showing: tab.id) {
            place += " · in the Pair, \(side == 0 ? "left" : "right") window"
        }
        return place
    }

    private static func actions(matching query: String, in store: BrowserStore) -> [CommandResult] {
        var results: [CommandResult] = []
        // Actions name their target.
        let side = side(in: store)

        if !query.isEmpty {
            // Go-to is the top hit; searching stays here as the fallback.
            if let url = NavigationInput.destination(for: query), NavigationInput.explicitURL(query) == nil {
                results.append(
                    CommandResult(id: "search", kind: .open(url), title: "Search “\(query)”\(side)", symbol: "magnifyingglass")
                )
            }
        }

        let commands = commands(in: store)
        if query.isEmpty {
            results += commands.prefix(4)
        } else {
            let matched = commands
                .compactMap { command in score(query, command.title).map { ($0, command) } }
                .sorted { $0.0 > $1.0 }
                .prefix(3)
            // A command named by what you typed beats searching the web for it.
            let named = matched.filter { $0.0 >= strongMatch }.map(\.1)
            let loose = matched.filter { $0.0 < strongMatch }.map(\.1)
            results = named + results + loose
        }
        return results
    }

    /// Every command that applies right now, in the order an empty bar suggests them.
    private static func commands(in store: BrowserStore) -> [CommandResult] {
        var commands: [CommandResult] = []
        if let tab = store.focusedTab, tab.url != nil, store.canRead(tab.id) {
            let reading = store.readerSession(for: tab.id) != nil
            commands.append(CommandResult(
                id: "reader", kind: .reader(tab.id), title: reading ? "Hide Reader" : "Show Reader", symbol: "doc.plaintext"
            ))
        }
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
        commands.append(CommandResult(id: "settings", kind: .showSettings, title: "Settings", symbol: "slider.horizontal.3"))
        commands.append(CommandResult(
            id: "edit-space", kind: .editSpace, title: "Edit \(store.activeSpace.name)", subtitle: "Name, emoji and binding",
            symbol: "paintpalette"
        ))
        if store.spaces.count < Library.maximumSpaces {
            commands.append(CommandResult(id: "new-space", kind: .newSpace, title: "New space", symbol: "plus.square.on.square"))
        }
        if !store.isPair {
            commands.append(CommandResult(id: "spine-sidebar", kind: .spine(.sidebar), title: "Spine: Sidebar", symbol: "sidebar.left"))
            commands.append(CommandResult(id: "spine-spines", kind: .spine(.spines), title: "Spine: Spines", symbol: "books.vertical"))
            commands.append(CommandResult(id: "spine-rail", kind: .spine(.rail), title: "Spine: Rail", symbol: "square.grid.3x1.below.line.grid.1x2"))
            commands.append(CommandResult(id: "spine-hidden", kind: .spine(.hidden), title: "Spine: Hidden", symbol: "rectangle"))
        }
        return commands
    }

    /// Scores at or above this come from a contiguous match, not letters scattered through a title.
    private static let strongMatch = 1000

    /// True when a command matches what was typed as a whole word run and no open tab does.
    private static func commandLeads(_ query: String, tabs: [CommandResult], actions: [CommandResult]) -> Bool {
        // Go-to and search echo the query in their titles, so only a real command can lead.
        guard !query.isEmpty, let first = actions.first else { return false }
        if case .open = first.kind { return false }
        guard let commandScore = score(query, first.title), commandScore >= strongMatch else { return false }
        let bestTab = tabs.compactMap { result -> Int? in
            guard case .tab(let tab) = result.kind else { return nil }
            return score(query, tab.displayTitle + " " + (tab.host ?? ""))
        }.max() ?? Int.min
        return bestTab < strongMatch
    }

    static func run(_ result: CommandResult, in store: BrowserStore) {
        switch result.kind {
        case .tab(let tab): store.select(tab.id)
        case .open(let url): store.open(url)
        case .visit(let visit): store.open(visit.url)
        case .pasteAndGo:
            // Reading the clipboard is what raises iOS's paste alert, so it waits for the tap.
            let board = UIPasteboard.general
            if let url = [board.url?.absoluteString, board.string].compactMap({ $0.flatMap(NavigationInput.firstLink(in:)) }).first {
                store.open(url)
            }
        case .archived(let item): store.restore(item.id)
        case .pin(let id): store.setTier(.pinned, for: id)
        case .unpin(let id): store.setTier(.today, for: id)
        case .moveToSpace(let id, let space): store.move(id, toSpace: space)
        case .togglePair: store.togglePair()
        case .archiveToday: store.archiveAllToday()
        case .showArchive: store.isArchiveOpen = true
        case .showSettings: store.isSettingsOpen = true
        case .newTab: store.newTab()
        case .spine(let state): store.setSpine(state)
        case .reader(let id): store.toggleReader(id)
        case .editSpace: store.editSpace()
        case .newSpace: store.newSpace()
        }
    }

    /// Fuzzy match: every query character in order. Contiguous and word-start hits rank higher.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let hay = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }
        if let range = candidate.lowercased().range(of: query.lowercased()) {
            // Any unbroken run counts as a strong match; starting the name or a word counts more,
            // and a shorter name wins a tie.
            let atStart = range.lowerBound == candidate.startIndex
            let lower = candidate.lowercased()
            let atWord = !atStart && lower[lower.index(before: range.lowerBound)] == " "
            return 1000 + (atStart ? 200 : atWord ? 100 : 0) + max(0, 100 - hay.count)
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
