import Foundation
import Observation

/// Single source of truth for spaces, tabs, panes and the Spine. Views render onto it;
/// no tab state lives in a view.
@MainActor
@Observable
final class BrowserStore {
    private(set) var spaces: [Space] = []
    private(set) var tabs: [BrowserTab] = []
    private(set) var archive: [ArchivedTab] = []
    private(set) var panes: [Pane] = []
    private(set) var focusedPaneIndex = 0
    private(set) var spineState: SpineState = .sidebar
    /// Nil turns auto-archive off.
    private(set) var archiveAfterHours: Double? = 12
    private(set) var settings = BrowserSettings()

    var runtime: [UUID: TabRuntime] = [:]
    var isCommandBarOpen = false
    var isSidebarOverlayOpen = false
    var isArchiveOpen = false
    var isSettingsOpen = false
    /// Bumps when every web view is thrown away, so the hosts on screen build fresh ones.
    private(set) var webGeneration = 0
    /// What a finger is carrying right now, so the windows can show where it lands.
    private(set) var drag: DragCargo?
    /// Two tabs that travel as one. Each waits in the Spine until either of its tabs is picked.
    private(set) var pairs: [TabPair] = []
    /// The Pair on screen. Set exactly when two windows show, and their tabs match it.
    private(set) var shownPairID: UUID?
    /// The URL pill recedes while you read down a page, or when left alone, and comes back on summon.
    private(set) var isAddressHidden = false {
        didSet { isAddressHidden ? addressFade?.cancel() : scheduleAddressFade() }
    }

    @ObservationIgnored private var lastTabBySpace: [UUID: UUID] = [:]
    @ObservationIgnored private var lastStrip: SpineState = .spines
    @ObservationIgnored private var spineBeforePair: SpineState?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var addressFade: Task<Void, Never>?
    @ObservationIgnored private(set) lazy var engine = WebEngine(store: self)
    let favicons = FaviconStore()

    init() {
        if let snapshot = Persistence.load() {
            apply(snapshot)
        } else {
            seed()
        }
        sweepArchive()
        scheduleAddressFade()
    }

    // MARK: Lookups

    func tab(id: UUID) -> BrowserTab? { tabs.first { $0.id == id } }
    func space(id: UUID?) -> Space? { spaces.first { $0.id == id } }

    var isPair: Bool { panes.count == 2 }
    var focusedPane: Pane { panes[min(focusedPaneIndex, panes.count - 1)] }
    var activeSpace: Space { space(id: focusedPane.spaceID) ?? spaces[0] }
    var focusedTab: BrowserTab? { focusedPane.tabID.flatMap(tab(id:)) }
    var focusedRuntime: TabRuntime { focusedPane.tabID.flatMap { runtime[$0] } ?? TabRuntime() }

    var essentials: [BrowserTab] { tabs.filter { $0.tier == .essential } }
    func pinned(in spaceID: UUID) -> [BrowserTab] { tabs.filter { $0.tier == .pinned && $0.spaceID == spaceID } }
    func today(in spaceID: UUID) -> [BrowserTab] { tabs.filter { $0.tier == .today && $0.spaceID == spaceID } }

    /// Which pane shows this tab, if any.
    func paneIndex(showing tabID: UUID) -> Int? { panes.firstIndex { $0.tabID == tabID } }

    func currentURL(for tab: BrowserTab) -> URL? { runtime[tab.id]?.currentURL ?? tab.url }

    func pair(id: UUID?) -> TabPair? { pairs.first { $0.id == id } }
    func pair(containing tabID: UUID) -> TabPair? { pairs.first { $0.tabIDs.contains(tabID) } }
    var shownPair: TabPair? { pair(id: shownPairID) }
    /// Where the divider of the Pair on screen rests, as a share of the page row. Nil is the fold.
    var pairSplit: Double? { shownPair?.split }

    /// A space's Pinned and Today, with each Pair standing in once for its tabs, where its first tab sits.
    func spineEntries(in spaceID: UUID) -> (pinned: [SpineEntry], today: [SpineEntry]) {
        var seen = Set<UUID>()
        func entries(_ list: [BrowserTab]) -> [SpineEntry] {
            list.compactMap { tab in
                guard let pair = pair(containing: tab.id) else { return .tab(tab) }
                return seen.insert(pair.id).inserted ? .pair(pair) : nil
            }
        }
        let pinned = entries(pinned(in: spaceID))
        return (pinned, entries(today(in: spaceID)))
    }

    // MARK: Selection

    /// Shows a tab. A tab in a Pair brings its Pair; any other tab leaves the Pair on screen,
    /// which waits in the Spine as it was.
    func select(_ tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        if let pair = pair(containing: tabID) {
            if shownPairID == pair.id {
                focusedPaneIndex = pair.tabIDs.firstIndex(of: tabID) ?? focusedPaneIndex
            } else {
                panes.compactMap(\.tabID).forEach(touch)
                show(pair, focusing: tabID)
            }
        } else if isPair {
            panes.compactMap(\.tabID).forEach(touch)
            showSingle(tabID, spaceID: tab.spaceID ?? focusedPane.spaceID)
        } else {
            if let leaving = panes[0].tabID, leaving != tabID { touch(leaving) }
            panes[0].tabID = tabID
            if let spaceID = tab.spaceID { panes[0].spaceID = spaceID }
        }
        touch(tabID)
        if let spaceID = tab.spaceID { lastTabBySpace[spaceID] = tabID }
        isSidebarOverlayOpen = false
        isAddressHidden = false
        scheduleSave()
    }

    /// Puts a tab in one window of the Pair on screen. The tab it replaces steps out of the Pair
    /// and stays in the Spine. With no Pair on screen this is a plain select.
    func place(_ tabID: UUID, inPane index: Int) {
        guard let shown = shownPair, shown.tabIDs.indices.contains(index), let tab = tab(id: tabID) else {
            select(tabID)
            return
        }
        if shown.tabIDs[index] == tabID {
            focus(pane: index)
            return
        }
        if shown.tabIDs.contains(tabID) {
            // It's the window across: the two trade sides.
            swapPair()
            focusedPaneIndex = index
            return
        }
        // A tab can only belong to one Pair, so the one it came from comes apart.
        if let previous = pair(containing: tabID) { pairs.removeAll { $0.id == previous.id } }
        touch(shown.tabIDs[index])
        updateShownPair { $0.tabIDs[index] = tabID }
        panes[index].tabID = tabID
        if let spaceID = tab.spaceID { panes[index].spaceID = spaceID }
        focusedPaneIndex = index
        touch(tabID)
        if let spaceID = tab.spaceID { lastTabBySpace[spaceID] = tabID }
        isSidebarOverlayOpen = false
        scheduleSave()
    }

    /// Two windows, one per tab of the Pair.
    private func show(_ pair: TabPair, focusing tabID: UUID?) {
        let wasPair = isPair
        let fallbackSpace = focusedPane.spaceID
        panes = pair.tabIDs.map { Pane(tabID: $0, spaceID: tab(id: $0)?.spaceID ?? fallbackSpace) }
        shownPairID = pair.id
        focusedPaneIndex = tabID.flatMap { pair.tabIDs.firstIndex(of: $0) } ?? 1
        pair.tabIDs.forEach(touch)
        if !wasPair, spineState == .sidebar || spineState == .spines {
            // The Spine drops to the Rail so both pages have room.
            spineBeforePair = spineState
            spineState = .rail
        }
    }

    /// One window. Whatever Pair was on screen stays in the Spine.
    private func showSingle(_ tabID: UUID?, spaceID: UUID) {
        let wasPair = isPair
        panes = [Pane(tabID: tabID, spaceID: spaceID)]
        shownPairID = nil
        focusedPaneIndex = 0
        guard wasPair else { return }
        isSidebarOverlayOpen = false
        isAddressHidden = false
        if let restore = spineBeforePair {
            spineState = restore
            spineBeforePair = nil
        }
    }

    private func updateShownPair(_ change: (inout TabPair) -> Void) {
        guard let i = pairs.firstIndex(where: { $0.id == shownPairID }) else { return }
        change(&pairs[i])
    }

    func focus(pane index: Int) {
        guard panes.indices.contains(index), focusedPaneIndex != index else { return }
        focusedPaneIndex = index
        scheduleSave()
    }

    private func touch(_ tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].lastActiveAt = .now
    }

    // MARK: Spaces

    /// Changing space leaves the Pair on screen and picks up where that space was left, Pair and all.
    func switchSpace(to spaceID: UUID) {
        guard space(id: spaceID) != nil, focusedPane.spaceID != spaceID else { return }
        panes.compactMap(\.tabID).forEach(touch)
        let remembered = lastTabBySpace[spaceID].flatMap(tab(id:))
        let candidate = remembered ?? today(in: spaceID).first ?? pinned(in: spaceID).first
        if isPair {
            showSingle(nil, spaceID: spaceID)
        } else {
            panes[0] = Pane(tabID: nil, spaceID: spaceID)
        }
        if let candidate { select(candidate.id) }
        scheduleSave()
    }

    func stepSpace(by delta: Int) {
        guard let current = spaces.firstIndex(where: { $0.id == focusedPane.spaceID }) else { return }
        let next = current + delta
        guard spaces.indices.contains(next) else { return }
        switchSpace(to: spaces[next].id)
    }

    // MARK: Tabs

    /// A new tab shows on its own, leaving any Pair on screen. Given a window of the Pair, it goes
    /// into the Pair there instead.
    @discardableResult
    func newTab(url: URL? = nil, title: String = "", inPane requested: Int? = nil) -> BrowserTab {
        let index = min(requested ?? focusedPaneIndex, panes.count - 1)
        let tab = BrowserTab(url: url, title: title, tier: .today, spaceID: panes[index].spaceID)
        // Most recent first.
        let insertAt = tabs.firstIndex { $0.tier == .today } ?? tabs.count
        tabs.insert(tab, at: insertAt)
        if let requested, isPair {
            place(tab.id, inPane: requested)
        } else {
            select(tab.id)
        }
        if url == nil { isCommandBarOpen = true }
        return tab
    }

    /// Loads typed input in the focused tab, or in a fresh tab when nothing is focused.
    func navigate(_ text: String) {
        guard let url = NavigationInput.destination(for: text) else { return }
        open(url)
    }

    func open(_ url: URL) {
        if let tab = focusedTab {
            if tab.url == nil, let i = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[i].url = url
            }
            engine.load(url, in: tab.id)
            touch(tab.id)
            scheduleSave()
        } else {
            newTab(url: url)
        }
    }

    /// Closing a tab in a Pair takes the Pair apart and leaves its partner on screen alone.
    /// Closing a tab on its own promotes the space's most recent tab.
    func close(_ tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        let pair = pair(containing: tabID)
        let wasShownInPair = pair != nil && pair?.id == shownPairID
        if let pair { pairs.removeAll { $0.id == pair.id } }
        engine.discard(tabID)
        runtime[tabID] = nil
        tabs.removeAll { $0.id == tabID }
        if let spaceID = tab.spaceID, lastTabBySpace[spaceID] == tabID { lastTabBySpace[spaceID] = nil }
        if wasShownInPair, let partner = pair?.tabIDs.first(where: { $0 != tabID }) {
            showSingle(partner, spaceID: self.tab(id: partner)?.spaceID ?? focusedPane.spaceID)
        } else if !isPair, panes[0].tabID == tabID {
            panes[0].tabID = nil
            if let next = promotedTab(for: 0) { select(next.id) }
        }
        scheduleSave()
    }

    /// Closes both tabs of a Pair.
    func close(pair pairID: UUID) {
        guard let pair = pair(id: pairID) else { return }
        for tabID in pair.tabIDs { close(tabID) }
    }

    /// Closing a tab promotes the pane's most recent tab.
    private func promotedTab(for paneIndex: Int) -> BrowserTab? {
        let spaceID = panes[paneIndex].spaceID
        let shown = Set(panes.compactMap(\.tabID))
        return (today(in: spaceID) + pinned(in: spaceID))
            .filter { !shown.contains($0.id) }
            .max { $0.lastActiveAt < $1.lastActiveAt }
    }

    func setTier(_ tier: TabTier, for tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var tab = tabs.remove(at: i)
        tab.tier = tier
        tab.lastActiveAt = .now
        switch tier {
        case .essential:
            tab.spaceID = nil
            let at = (tabs.lastIndex { $0.tier == .essential }).map { $0 + 1 } ?? 0
            tabs.insert(tab, at: at)
        case .pinned:
            tab.spaceID = tab.spaceID ?? focusedPane.spaceID
            let at = (tabs.lastIndex { $0.tier == .pinned }).map { $0 + 1 }
                ?? (tabs.lastIndex { $0.tier == .essential }).map { $0 + 1 } ?? 0
            tabs.insert(tab, at: at)
        case .today:
            tab.spaceID = tab.spaceID ?? focusedPane.spaceID
            let at = tabs.firstIndex { $0.tier == .today } ?? tabs.count
            tabs.insert(tab, at: at)
        }
        scheduleSave()
    }

    func move(_ tabID: UUID, toSpace spaceID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }), tabs[i].tier != .essential else { return }
        tabs[i].spaceID = spaceID
        if isPair, let index = paneIndex(showing: tabID) {
            // The Pair keeps its tab; that window just takes the new space.
            panes[index].spaceID = spaceID
        } else if !isPair, panes[0].tabID == tabID {
            panes[0].tabID = nil
            if let next = promotedTab(for: 0) { select(next.id) }
        }
        scheduleSave()
    }

    // MARK: The URL pill

    /// Scrolling hides or shows the pill, but only for the page on screen. The Pair has its own bars.
    func setAddressHidden(_ hidden: Bool, for tabID: UUID) {
        guard !isPair, focusedPane.tabID == tabID, isAddressHidden != hidden else { return }
        isAddressHidden = hidden
    }

    func showAddress() {
        isAddressHidden = false
    }

    func hideAddress() {
        isAddressHidden = true
    }

    /// Left alone, the pill steps aside. It waits out a loading page or an open command bar.
    private func scheduleAddressFade() {
        addressFade?.cancel()
        addressFade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            if isCommandBarOpen || focusedRuntime.isLoading || isPair {
                scheduleAddressFade()
            } else {
                isAddressHidden = true
            }
        }
    }

    // MARK: The Spine

    func setSpine(_ state: SpineState) {
        if isPair, state == .sidebar || state == .spines {
            // The Pair keeps the Spine at the Rail; the full Sidebar comes in as an overlay.
            isSidebarOverlayOpen = true
            return
        }
        spineState = state
        if state == .spines || state == .rail { lastStrip = state }
        scheduleSave()
    }

    /// The system-column Spine button cycles states.
    func cycleSpine() {
        if isPair {
            setSpine(spineState == .hidden ? .rail : .hidden)
            return
        }
        switch spineState {
        case .sidebar: setSpine(.spines)
        case .spines: setSpine(.rail)
        case .rail: setSpine(.hidden)
        case .hidden: setSpine(.sidebar)
        }
    }

    var preferredStrip: SpineState { isPair ? .rail : lastStrip }

    // MARK: The Pair

    func togglePair() {
        if isPair { closePair() } else { openPair() }
    }

    /// Pairs the tab on screen with another, which takes the given side. Without one, the space's
    /// most recent tab outside a Pair joins, or a fresh tab.
    func openPair(with tabID: UUID? = nil, onSide side: Int = 1) {
        guard !isPair, let current = panes.first else { return }
        let spaceID = current.spaceID
        let anchor = current.tabID ?? makeBlankTab(in: spaceID)
        let companion: UUID
        if let tabID, tabID != anchor, tab(id: tabID) != nil {
            companion = tabID
        } else if let other = (today(in: spaceID) + pinned(in: spaceID))
            .filter({ $0.id != anchor && pair(containing: $0.id) == nil })
            .max(by: { $0.lastActiveAt < $1.lastActiveAt }) {
            companion = other.id
        } else {
            companion = makeBlankTab(in: spaceID)
        }
        // A tab belongs to one Pair at a time.
        pairs.removeAll { $0.tabIDs.contains(anchor) || $0.tabIDs.contains(companion) }
        let pair = TabPair(tabIDs: side == 0 ? [companion, anchor] : [anchor, companion])
        pairs.append(pair)
        show(pair, focusing: companion)
        if let spaceID = tab(id: companion)?.spaceID { lastTabBySpace[spaceID] = companion }
        scheduleSave()
    }

    private func makeBlankTab(in spaceID: UUID) -> UUID {
        let tab = BrowserTab(url: nil, title: "", tier: .today, spaceID: spaceID)
        tabs.insert(tab, at: tabs.firstIndex { $0.tier == .today } ?? tabs.count)
        return tab.id
    }

    /// Takes the Pair on screen apart. The kept window's tab stays on screen; both tabs stay in the Spine.
    func closePair(keeping keep: Int? = nil) {
        guard let shown = shownPair else { return }
        separate(shown.id, keeping: keep ?? focusedPaneIndex)
    }

    /// Takes a Pair apart into two ordinary tabs.
    func separate(_ pairID: UUID, keeping keep: Int? = nil) {
        guard pair(id: pairID) != nil else { return }
        pairs.removeAll { $0.id == pairID }
        if shownPairID == pairID {
            let kept = panes[min(keep ?? focusedPaneIndex, panes.count - 1)]
            showSingle(kept.tabID, spaceID: kept.spaceID)
        }
        scheduleSave()
    }

    /// Trades sides. The divider keeps its place from each window's point of view.
    func swapPair() {
        guard isPair else { return }
        updateShownPair { pair in
            pair.tabIDs.reverse()
            pair.split = pair.split.map { 1 - $0 }
        }
        panes.swapAt(0, 1)
        focusedPaneIndex = 1 - focusedPaneIndex
        scheduleSave()
    }

    /// Trades sides for any Pair, on screen or waiting in the Spine.
    func swapSides(of pairID: UUID) {
        if pairID == shownPairID {
            swapPair()
            return
        }
        guard let i = pairs.firstIndex(where: { $0.id == pairID }) else { return }
        pairs[i].tabIDs.reverse()
        pairs[i].split = pairs[i].split.map { 1 - $0 }
        scheduleSave()
    }

    /// Nil puts the divider back on the fold. Each Pair remembers its own.
    func setPairSplit(_ split: Double?) {
        guard pairSplit != split else { return }
        updateShownPair { $0.split = split }
        scheduleSave()
    }

    // MARK: Drag and drop

    func beginDrag(_ cargo: DragCargo) {
        guard drag != cargo else { return }
        drag = cargo
        // A tab picked up from the overlay Sidebar needs the windows uncovered to land on.
        if case .tab = cargo { isSidebarOverlayOpen = false }
    }

    /// Ends the drag only if it's still the one that began, so a late callback can't end the next.
    func endDrag(_ cargo: DragCargo? = nil) {
        guard let drag, cargo == nil || cargo == drag else { return }
        self.drag = nil
    }

    /// A tab dropped on a Pair window joins the Pair there. Dropped on the window across, it swaps sides.
    func drop(tab tabID: UUID, onPane index: Int) {
        endDrag()
        guard isPair, panes.indices.contains(index), tab(id: tabID) != nil else { return }
        place(tabID, inPane: index)
    }

    /// A tab dropped on one side of a single page opens a Pair with it on that side.
    func drop(tab tabID: UUID, onSide side: Int) {
        endDrag()
        guard !isPair, focusedPane.tabID != tabID, tab(id: tabID) != nil else { return }
        openPair(with: tabID, onSide: side)
    }

    /// A link dropped on a window's bar opens in a new tab that joins the Pair in that window.
    func drop(link url: URL, onPane index: Int) {
        endDrag()
        guard panes.indices.contains(index), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        newTab(url: url, inPane: index)
    }

    /// Something dropped on Essentials or Pinned stays there. A tab in flight moves to that tier;
    /// a link becomes a new tab kept there. Nothing on screen changes.
    func drop(_ url: URL?, keepingAs tier: TabTier) {
        let cargo = drag
        endDrag()
        if case let .tab(tabID) = cargo {
            guard let tab = tab(id: tabID), tab.tier != tier else { return }
            setTier(tier, for: tabID)
        } else if let url {
            keep(url, as: tier)
        }
    }

    private func keep(_ url: URL, as tier: TabTier) {
        guard ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host() else { return }
        let spaceID = tier == .essential ? nil : focusedPane.spaceID
        // Already kept there: nothing to add.
        guard !tabs.contains(where: { $0.tier == tier && $0.spaceID == spaceID && $0.url == url }) else { return }
        let tab = BrowserTab(url: url, title: "", tier: .today, spaceID: focusedPane.spaceID)
        tabs.append(tab)
        setTier(tier, for: tab.id)
        // It won't load until it's opened, so ask the site for its icon now.
        let root = URL(string: "https://\(host)")
        let candidates = ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: root)?.absoluteURL }
        favicons.fetch(pageHost: host, aliases: [], candidates: candidates)
    }

    // MARK: Auto-archive

    private var archiveInterval: TimeInterval? { archiveAfterHours.map { $0 * 3600 } }

    func setArchiveAfter(hours: Double?) {
        archiveAfterHours = hours
        sweepArchive()
        scheduleSave()
    }

    /// When the next unpinned tab in this space archives. Tabs on screen don't count down.
    func nextArchiveDate(in spaceID: UUID) -> Date? {
        guard let interval = archiveInterval else { return nil }
        let shown = Set(panes.compactMap(\.tabID))
        return today(in: spaceID)
            .filter { !shown.contains($0.id) }
            .map { $0.lastActiveAt.addingTimeInterval(interval) }
            .min()
    }

    /// When the next unpinned tab archives, in any space.
    var nextArchiveDate: Date? {
        spaces.compactMap { nextArchiveDate(in: $0.id) }.min()
    }

    func archiveDate(for tab: BrowserTab) -> Date? {
        guard tab.tier == .today, let interval = archiveInterval, paneIndex(showing: tab.id) == nil else { return nil }
        return tab.lastActiveAt.addingTimeInterval(interval)
    }

    func sweepArchive(now: Date = .now) {
        guard let interval = archiveInterval else { return }
        let shown = Set(panes.compactMap(\.tabID))
        let expired = tabs.filter {
            $0.tier == .today && !shown.contains($0.id) && now.timeIntervalSince($0.lastActiveAt) >= interval
        }
        guard !expired.isEmpty else { return }
        expired.forEach { shelve($0) }
        scheduleSave()
    }

    func archiveAllToday() {
        let shown = Set(panes.compactMap(\.tabID))
        today(in: focusedPane.spaceID).filter { !shown.contains($0.id) }.forEach { shelve($0) }
        scheduleSave()
    }

    /// A Pair's tabs are shown and touched together, so they come due together. A pinned partner
    /// stays behind as an ordinary tab.
    private func shelve(_ tab: BrowserTab) {
        pairs.removeAll { $0.tabIDs.contains(tab.id) }
        engine.discard(tab.id)
        runtime[tab.id] = nil
        tabs.removeAll { $0.id == tab.id }
        guard let url = tab.url else { return }
        archive.insert(
            ArchivedTab(url: url, title: tab.displayTitle, spaceID: tab.spaceID, tileHex: tab.tileHex),
            at: 0
        )
    }

    func restore(_ archivedID: UUID) {
        guard let i = archive.firstIndex(where: { $0.id == archivedID }) else { return }
        let item = archive.remove(at: i)
        if let spaceID = item.spaceID, space(id: spaceID) != nil, focusedPane.spaceID != spaceID {
            switchSpace(to: spaceID)
        }
        let tab = newTab(url: item.url, title: item.title)
        if let t = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[t].tileHex = item.tileHex }
        isArchiveOpen = false
    }

    /// Zen-style unload: tabs idle past 30 minutes give their memory back and reload on activation.
    func unloadIdleTabs(now: Date = .now) {
        guard settings.unloadsIdleTabs else { return }
        let shown = Set(panes.compactMap(\.tabID))
        let idle = tabs.filter { !shown.contains($0.id) && now.timeIntervalSince($0.lastActiveAt) > 30 * 60 }
        idle.forEach { engine.park($0.id) }
    }

    // MARK: Settings

    func updateSettings(_ change: (inout BrowserSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let blockingChanged = next.blocksTrackers != settings.blocksTrackers
        settings = next
        if blockingChanged {
            // Pages on screen reload so the change shows at once; the rest pick it up on their next load.
            engine.setContentBlocking(next.blocksTrackers, reloading: panes.compactMap(\.tabID))
        }
        scheduleSave()
    }

    /// Cookies, site data, caches and the archive go. Open tabs stay and reload fresh, so no
    /// signed-in page lingers and their back history starts over.
    func clearBrowsingData() async {
        await engine.removeWebsiteData()
        engine.discardAll()
        runtime.removeAll()
        archive.removeAll()
        favicons.clear()
        webGeneration += 1
        saveNow()
    }

    // MARK: Web callbacks

    func webDidUpdate(_ tabID: UUID, title: String?, state: TabRuntime) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        // A new page brings the pill back so you can see where you landed.
        if runtime[tabID]?.currentURL != state.currentURL { setAddressHidden(false, for: tabID) }
        if runtime[tabID] != state { runtime[tabID] = state }
        var changed = false
        if let title, !title.isEmpty, tabs[i].title != title {
            tabs[i].title = title
            changed = true
        }
        // Pinned tabs and Essentials keep their home address; Today tabs follow the page.
        if tabs[i].tier == .today, let url = state.currentURL, tabs[i].url != url {
            tabs[i].url = url
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            Persistence.save(self.snapshot())
        }
    }

    func saveNow() {
        saveTask?.cancel()
        Persistence.save(snapshot())
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            spaces: spaces, tabs: tabs, archive: archive, panes: panes,
            focusedPaneIndex: focusedPaneIndex, spineState: spineState,
            archiveAfterHours: archiveAfterHours, lastTabBySpace: lastTabBySpace,
            settings: settings, pairs: pairs, shownPairID: shownPairID
        )
    }

    /// Drops Pairs whose tabs are gone or claimed twice, then makes sure the windows on screen
    /// match the Pair they claim. State from before Pairs were kept turns its two windows into one.
    private func reconcilePairs(saved: [TabPair], shown savedShown: UUID?) {
        let ids = Set(tabs.map(\.id))
        var claimed = Set<UUID>()
        pairs = saved.filter { pair in
            guard pair.tabIDs.count == 2, pair.tabIDs[0] != pair.tabIDs[1],
                  pair.tabIDs.allSatisfy({ ids.contains($0) && !claimed.contains($0) }) else { return false }
            claimed.formUnion(pair.tabIDs)
            return true
        }
        guard panes.count == 2 else {
            panes = Array(panes.prefix(1))
            shownPairID = nil
            return
        }
        let onScreen = panes.compactMap(\.tabID)
        if let pair = pair(id: savedShown), pair.tabIDs == onScreen {
            shownPairID = pair.id
        } else if onScreen.count == 2, onScreen.allSatisfy({ ids.contains($0) && pair(containing: $0) == nil }) {
            let pair = TabPair(tabIDs: onScreen)
            pairs.append(pair)
            shownPairID = pair.id
        } else {
            panes = [panes[min(focusedPaneIndex, 1)]]
            focusedPaneIndex = 0
            shownPairID = nil
        }
    }

    private func apply(_ snapshot: Snapshot) {
        spaces = snapshot.spaces
        tabs = snapshot.tabs
        archive = snapshot.archive
        panes = snapshot.panes
        focusedPaneIndex = min(snapshot.focusedPaneIndex, max(snapshot.panes.count - 1, 0))
        spineState = snapshot.spineState
        archiveAfterHours = snapshot.archiveAfterHours
        lastTabBySpace = snapshot.lastTabBySpace
        settings = snapshot.settings ?? BrowserSettings()
        reconcilePairs(saved: snapshot.pairs ?? [], shown: snapshot.shownPairID)
        if spaces.isEmpty || panes.isEmpty { seed() }
    }

    private func seed() {
        let personal = Space(name: "Personal", emoji: "🪴", binding: .verdigris)
        let work = Space(name: "Work", emoji: "🗂️", binding: .lapis)
        spaces = [personal, work]

        func make(_ title: String, _ address: String, _ tier: TabTier, _ space: Space?, tile: UInt32,
                  glyph: String? = nil, idleHours: Double = 0) -> BrowserTab {
            BrowserTab(
                url: URL(string: address), title: title, tier: tier, spaceID: space?.id,
                lastActiveAt: Date().addingTimeInterval(-idleHours * 3600), tileHex: tile, glyph: glyph
            )
        }

        let kinfolk = make("Kinfolk — Slow rooms", "https://www.kinfolk.com", .today, personal, tile: 0x221D18)
        tabs = [
            make("Mail", "https://mail.google.com", .essential, nil, tile: 0xC5221F, glyph: "M"),
            make("Calendar", "https://calendar.google.com", .essential, nil, tile: 0x1A73E8, glyph: "C"),
            make("Slack", "https://slack.com", .essential, nil, tile: 0x4A154B, glyph: "S"),
            make("Spotify", "https://open.spotify.com", .essential, nil, tile: 0x1E7D4F, glyph: "♪"),
            make("Dwell — Journal", "https://www.dwell.com", .pinned, personal, tile: 0xC9452E),
            make("Are.na — Reading list", "https://www.are.na", .pinned, personal, tile: 0x2B2B2B),
            make("Notion — Studio brief", "https://www.notion.so", .pinned, work, tile: 0x2B2B2B),
            kinfolk,
            make("Vitsœ — 620 Chair", "https://www.vitsoe.com/us/620", .today, personal, tile: 0x8E2C2C, idleHours: 1.2),
            make("Wikipedia — Hinge", "https://en.wikipedia.org/wiki/Hinge", .today, personal, tile: 0x6B6660, idleHours: 2.1),
            make("Noma — Reservations", "https://noma.dk", .today, personal, tile: 0x2F5D4A, idleHours: 2.93),
            make("GitHub", "https://github.com", .today, work, tile: 0x2B2B2B, idleHours: 0.5),
            make("Hacker News", "https://news.ycombinator.com", .today, work, tile: 0xC9452E, idleHours: 3),
        ]
        archive = []
        pairs = []
        shownPairID = nil
        panes = [Pane(tabID: kinfolk.id, spaceID: personal.id)]
        focusedPaneIndex = 0
        spineState = .sidebar
        lastTabBySpace = [personal.id: kinfolk.id]
    }
}

struct Snapshot: Codable {
    var spaces: [Space]
    var tabs: [BrowserTab]
    var archive: [ArchivedTab]
    var panes: [Pane]
    var focusedPaneIndex: Int
    var spineState: SpineState
    var archiveAfterHours: Double?
    var lastTabBySpace: [UUID: UUID]
    /// Optional so state saved before Settings existed still loads.
    var settings: BrowserSettings?
    /// Optional so state saved before Pairs were kept still loads.
    var pairs: [TabPair]?
    var shownPairID: UUID?
}

/// Local-only state: one JSON file in Application Support. No accounts, no telemetry.
enum Persistence {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Spinebrowser", isDirectory: true).appendingPathComponent("state.json")
    }

    static func load() -> Snapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
