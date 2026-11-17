import Foundation
import Observation

/// One window's place in the library: its panes, its Spine, its Pair, its open sheets.
/// Spaces, tabs and Pairs themselves live in the shared `Library`; views read them through here,
/// so no tab state lives in a view and no view needs to know which window it's in.
@MainActor
@Observable
final class BrowserStore {
    let id: UUID
    let library: Library

    private(set) var panes: [Pane] = [] {
        didSet {
            // A window coming back doesn't claim its tabs until the library knows it, so it yields
            // to the window already showing them.
            guard isRegistered, panes.map(\.tabID) != oldValue.map(\.tabID) else { return }
            library.window(self, shows: shownTabIDs)
        }
    }
    /// Set once the library has settled what this window may show.
    @ObservationIgnored var isRegistered = false
    private(set) var focusedPaneIndex = 0
    private(set) var spineState: SpineState = .sidebar
    /// The Pair on screen. Set exactly when two windows show, and their tabs match it.
    private(set) var shownPairID: UUID?

    var isCommandBarOpen = false
    var isSidebarOverlayOpen = false
    var isArchiveOpen = false
    var isSettingsOpen = false
    /// The URL pill recedes while you read down a page, or when left alone, and comes back on summon.
    private(set) var isAddressHidden = false {
        didSet { isAddressHidden ? addressFade?.cancel() : scheduleAddressFade() }
    }

    @ObservationIgnored private var lastTabBySpace: [UUID: UUID] = [:]
    @ObservationIgnored private var lastStrip: SpineState = .spines
    @ObservationIgnored private var spineBeforePair: SpineState?
    /// The Sidebar a window narrower than the Sidebar needs gave up, to come back when it widens.
    @ObservationIgnored private var spineBeforeNarrow: SpineState?
    @ObservationIgnored private var addressFade: Task<Void, Never>?
    /// A fresh window raises the command bar once it settles. A link arriving first calls it off.
    @ObservationIgnored private var freshPrompt: Task<Void, Never>?

    init(library: Library, id: UUID, state: WindowSnapshot) {
        self.library = library
        self.id = id
        apply(state)
        scheduleAddressFade()
    }

    // MARK: Shared state, read through the window

    var spaces: [Space] { library.spaces }
    var tabs: [BrowserTab] { library.tabs }
    var archive: [ArchivedTab] { library.archive }
    var pairs: [TabPair] { library.pairs }
    var settings: BrowserSettings { library.settings }
    var archiveAfterHours: Double? { library.archiveAfterHours }
    var runtime: [UUID: TabRuntime] { library.runtime }
    var webGeneration: Int { library.webGeneration }
    var drag: DragCargo? { library.drag }
    var engine: WebEngine { library.engine }
    var favicons: FaviconStore { library.favicons }

    func tab(id: UUID) -> BrowserTab? { library.tab(id: id) }
    func space(id: UUID?) -> Space? { library.space(id: id) }
    var essentials: [BrowserTab] { library.essentials }
    func pinned(in spaceID: UUID) -> [BrowserTab] { library.pinned(in: spaceID) }
    func today(in spaceID: UUID) -> [BrowserTab] { library.today(in: spaceID) }
    func currentURL(for tab: BrowserTab) -> URL? { library.currentURL(for: tab) }
    func pair(id: UUID?) -> TabPair? { library.pair(id: id) }
    func pair(containing tabID: UUID) -> TabPair? { library.pair(containing: tabID) }
    func spineEntries(in spaceID: UUID) -> (pinned: [SpineEntry], today: [SpineEntry]) {
        library.spineEntries(in: spaceID)
    }

    // MARK: Lookups

    var isPair: Bool { panes.count == 2 }
    var focusedPane: Pane { panes[min(focusedPaneIndex, panes.count - 1)] }
    var activeSpace: Space { space(id: focusedPane.spaceID) ?? spaces[0] }
    var focusedTab: BrowserTab? { focusedPane.tabID.flatMap(tab(id:)) }
    var focusedRuntime: TabRuntime { focusedPane.tabID.flatMap { runtime[$0] } ?? TabRuntime() }
    var shownTabIDs: [UUID] { panes.compactMap(\.tabID) }

    /// Which pane shows this tab, if any.
    func paneIndex(showing tabID: UUID) -> Int? { panes.firstIndex { $0.tabID == tabID } }

    var shownPair: TabPair? { pair(id: shownPairID) }
    /// Where the divider of the Pair on screen rests, as a share of the page row. Nil is the middle,
    /// which on the Duo is the fold.
    var pairSplit: Double? { shownPair?.split }

    // MARK: Selection

    /// Shows a tab. A tab in a Pair brings its Pair; any other tab leaves the Pair on screen,
    /// which waits in the Spine as it was. A tab another window shows moves here.
    func select(_ tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        if let pair = pair(containing: tabID) {
            if shownPairID == pair.id {
                focusedPaneIndex = pair.tabIDs.firstIndex(of: tabID) ?? focusedPaneIndex
            } else {
                shownTabIDs.forEach(library.touch)
                show(pair, focusing: tabID)
            }
        } else if isPair {
            shownTabIDs.forEach(library.touch)
            showSingle(tabID, spaceID: tab.spaceID ?? focusedPane.spaceID)
        } else {
            if let leaving = panes[0].tabID, leaving != tabID { library.touch(leaving) }
            var pane = panes[0]
            pane.tabID = tabID
            if let spaceID = tab.spaceID { pane.spaceID = spaceID }
            panes[0] = pane
        }
        library.touch(tabID)
        if let spaceID = tab.spaceID { lastTabBySpace[spaceID] = tabID }
        isSidebarOverlayOpen = false
        isAddressHidden = false
        library.windowBecameActive(id)
        library.scheduleSave()
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
        if let previous = pair(containing: tabID) { library.removePair(previous.id) }
        library.touch(shown.tabIDs[index])
        library.updatePair(shown.id) { $0.tabIDs[index] = tabID }
        var pane = panes[index]
        pane.tabID = tabID
        if let spaceID = tab.spaceID { pane.spaceID = spaceID }
        panes[index] = pane
        focusedPaneIndex = index
        library.touch(tabID)
        if let spaceID = tab.spaceID { lastTabBySpace[spaceID] = tabID }
        isSidebarOverlayOpen = false
        library.scheduleSave()
    }

    /// Two windows, one per tab of the Pair.
    private func show(_ pair: TabPair, focusing tabID: UUID?) {
        let wasPair = isPair
        let fallbackSpace = focusedPane.spaceID
        shownPairID = pair.id
        focusedPaneIndex = tabID.flatMap { pair.tabIDs.firstIndex(of: $0) } ?? 1
        panes = pair.tabIDs.map { Pane(tabID: $0, spaceID: tab(id: $0)?.spaceID ?? fallbackSpace) }
        pair.tabIDs.forEach(library.touch)
        if !wasPair, spineState == .sidebar || spineState == .spines {
            // The Spine drops to the Rail so both pages have room.
            spineBeforePair = spineState
            spineState = .rail
        }
    }

    /// One window. Whatever Pair was on screen stays in the Spine.
    private func showSingle(_ tabID: UUID?, spaceID: UUID) {
        let wasPair = isPair
        shownPairID = nil
        focusedPaneIndex = 0
        panes = [Pane(tabID: tabID, spaceID: spaceID)]
        guard wasPair else { return }
        isSidebarOverlayOpen = false
        isAddressHidden = false
        if let restore = spineBeforePair {
            spineState = restore
            spineBeforePair = nil
        }
    }

    func focus(pane index: Int) {
        library.windowBecameActive(id)
        guard panes.indices.contains(index), focusedPaneIndex != index else { return }
        focusedPaneIndex = index
        library.scheduleSave()
    }

    /// Moves focus to the other window of the Pair.
    func focusOtherPane() {
        guard isPair else { return }
        focus(pane: 1 - focusedPaneIndex)
    }

    // MARK: Other windows

    /// Another window took these tabs. Whatever showed them here falls back to the most recent tab
    /// that isn't on screen anywhere.
    func release(_ taken: Set<UUID>) {
        guard shownTabIDs.contains(where: taken.contains) else { return }
        if isPair {
            showSingle(nil, spaceID: focusedPane.spaceID)
        } else {
            var pane = panes[0]
            pane.tabID = nil
            panes[0] = pane
        }
        if let next = promotedTab(for: 0) { select(next.id) }
    }

    /// After a shared change, makes sure what this window shows still exists: a closed tab gives way,
    /// a Pair taken apart leaves the focused window's tab.
    func reconcile() {
        if let pairID = shownPairID {
            if let pair = pair(id: pairID), pair.tabIDs.allSatisfy({ tab(id: $0) != nil }) {
                if pair.tabIDs != shownTabIDs {
                    panes = pair.tabIDs.map { tabID in
                        panes.first { $0.tabID == tabID } ?? Pane(tabID: tabID, spaceID: tab(id: tabID)?.spaceID ?? focusedPane.spaceID)
                    }
                }
            } else {
                let survivors = panes.filter { $0.tabID.flatMap(tab(id:)) != nil }
                let kept = survivors.first { $0.id == focusedPane.id } ?? survivors.first
                showSingle(kept?.tabID, spaceID: kept?.spaceID ?? focusedPane.spaceID)
            }
        }
        if !isPair, let tabID = panes[0].tabID, tab(id: tabID) == nil {
            var pane = panes[0]
            pane.tabID = nil
            panes[0] = pane
            if let next = promotedTab(for: 0) { select(next.id) }
        }
        lastTabBySpace = lastTabBySpace.filter { tab(id: $0.value) != nil }
    }

    /// A tab moved to another space. The Pair keeps its tab, in the new space; a single page gives way.
    func tabMoved(_ tabID: UUID, to spaceID: UUID) {
        guard let index = paneIndex(showing: tabID) else { return }
        if isPair {
            panes[index].spaceID = spaceID
        } else {
            var pane = panes[0]
            pane.tabID = nil
            panes[0] = pane
            if let next = promotedTab(for: 0) { select(next.id) }
        }
    }

    // MARK: Spaces

    /// Changing space leaves the Pair on screen and picks up where that space was left, Pair and all.
    func switchSpace(to spaceID: UUID) {
        guard space(id: spaceID) != nil, focusedPane.spaceID != spaceID else { return }
        shownTabIDs.forEach(library.touch)
        let remembered = lastTabBySpace[spaceID].flatMap(tab(id:))
        let candidate = remembered ?? today(in: spaceID).first ?? pinned(in: spaceID).first
        if isPair {
            showSingle(nil, spaceID: spaceID)
        } else {
            panes[0] = Pane(tabID: nil, spaceID: spaceID)
        }
        if let candidate { select(candidate.id) }
        library.scheduleSave()
    }

    func stepSpace(by delta: Int) {
        guard let current = spaces.firstIndex(where: { $0.id == focusedPane.spaceID }) else { return }
        let next = current + delta
        guard spaces.indices.contains(next) else { return }
        switchSpace(to: spaces[next].id)
    }

    /// The space at this place in the order, counting from zero.
    func switchSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        switchSpace(to: spaces[index].id)
    }

    // MARK: Tabs

    /// A new tab shows on its own, leaving any Pair on screen. Given a window of the Pair, it goes
    /// into the Pair there instead.
    @discardableResult
    func newTab(url: URL? = nil, title: String = "", inPane requested: Int? = nil) -> BrowserTab {
        let index = min(requested ?? focusedPaneIndex, panes.count - 1)
        let tab = library.insertTab(url: url, title: title, spaceID: panes[index].spaceID)
        if let requested, isPair {
            place(tab.id, inPane: requested)
        } else {
            select(tab.id)
        }
        if url == nil { isCommandBarOpen = true }
        return tab
    }

    /// A window opened just now starts on a new tab, ready to type.
    func startFresh() {
        newTab()
        // The keyboard waits for the window to finish opening, rather than rise mid-animation.
        isCommandBarOpen = false
        freshPrompt = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.isCommandBarOpen = true
        }
    }

    /// A link handed over by another app. It gets a tab of its own, so the page you were on stays.
    /// A blank tab still waiting for an address takes it instead of being left behind empty.
    func openIncoming(_ url: URL) {
        freshPrompt?.cancel()
        freshPrompt = nil
        isCommandBarOpen = false
        if let tab = focusedTab, currentURL(for: tab) == nil {
            open(url)
        } else {
            newTab(url: url)
        }
    }

    /// Loads typed input in the focused tab, or in a fresh tab when nothing is focused.
    func navigate(_ text: String) {
        guard let url = NavigationInput.destination(for: text) else { return }
        open(url)
    }

    func open(_ url: URL) {
        if let tab = focusedTab {
            library.setURL(url, for: tab.id)
            engine.load(url, in: tab.id)
            library.touch(tab.id)
            library.scheduleSave()
        } else {
            newTab(url: url)
        }
    }

    /// Closing a tab in a Pair takes the Pair apart and leaves its partner on screen alone.
    /// Closing a tab on its own promotes the space's most recent tab.
    func close(_ tabID: UUID) {
        if let spaceID = tab(id: tabID)?.spaceID, lastTabBySpace[spaceID] == tabID { lastTabBySpace[spaceID] = nil }
        library.close(tabID)
    }

    /// Closes the tab in the focused window.
    func closeFocusedTab() {
        guard let tabID = focusedPane.tabID else { return }
        close(tabID)
    }

    /// Closes both tabs of a Pair.
    func close(pair pairID: UUID) {
        guard let pair = pair(id: pairID) else { return }
        for tabID in pair.tabIDs { close(tabID) }
    }

    /// The pane's most recent tab that no window shows, and whose Pair partner no other window shows.
    private func promotedTab(for paneIndex: Int) -> BrowserTab? {
        let spaceID = panes[paneIndex].spaceID
        let shown = library.shownTabIDs
        return (today(in: spaceID) + pinned(in: spaceID))
            .filter { tab in
                guard !shown.contains(tab.id) else { return false }
                guard let pair = pair(containing: tab.id) else { return true }
                return !pair.tabIDs.contains(where: shown.contains)
            }
            .max { $0.lastActiveAt < $1.lastActiveAt }
    }

    func setTier(_ tier: TabTier, for tabID: UUID) {
        library.setTier(tier, for: tabID, spaceID: focusedPane.spaceID)
    }

    /// Pins the focused tab, or puts a pinned one back in Today.
    func togglePinFocused() {
        guard let tab = focusedTab, tab.tier != .essential else { return }
        setTier(tab.tier == .pinned ? .today : .pinned, for: tab.id)
    }

    func move(_ tabID: UUID, toSpace spaceID: UUID) {
        library.move(tabID, toSpace: spaceID)
    }

    /// The tabs in the order the Spine lists them in this window's space: Essentials, Pinned, Today.
    /// A Pair counts once, by the tab of it this window would show.
    var orderedTabIDs: [UUID] {
        let spaceID = focusedPane.spaceID
        let entries = spineEntries(in: spaceID)
        func ids(_ list: [SpineEntry]) -> [UUID] {
            list.map { entry in
                switch entry {
                case .tab(let tab): tab.id
                case .pair(let pair): pair.tabIDs[0]
                }
            }
        }
        return essentials.map(\.id) + ids(entries.pinned) + ids(entries.today)
    }

    /// ⌘1 to ⌘8 pick a tab by place; ⌘9 always picks the last.
    func selectTab(at index: Int) {
        let ordered = orderedTabIDs
        guard !ordered.isEmpty else { return }
        select(index >= 8 ? ordered[ordered.count - 1] : ordered[min(index, ordered.count - 1)])
    }

    /// ⌃Tab and ⌃⇧Tab walk the Spine's order, wrapping at either end.
    func stepTab(by delta: Int) {
        let ordered = orderedTabIDs
        guard !ordered.isEmpty else { return }
        let current = focusedPane.tabID.flatMap { id in
            ordered.firstIndex(of: id) ?? pair(containing: id).flatMap { ordered.firstIndex(of: $0.tabIDs[0]) }
        } ?? 0
        let next = (current + delta + ordered.count) % ordered.count
        select(ordered[next])
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
        library.scheduleSave()
    }

    /// The Spine button cycles states.
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

    /// A window too narrow for the Sidebar shows Spines instead; widen it and the Sidebar returns.
    /// Neither change is saved, so the window keeps the choice you made.
    func fitSpine(roomForSidebar: Bool) {
        if !roomForSidebar, spineState == .sidebar {
            spineBeforeNarrow = .sidebar
            spineState = .spines
        } else if roomForSidebar, let restore = spineBeforeNarrow {
            spineBeforeNarrow = nil
            if spineState == .spines { spineState = restore }
        }
    }

    // MARK: The Pair

    func togglePair() {
        if isPair { closePair() } else { openPair() }
    }

    /// Pairs the tab on screen with another, which takes the given side. Without one, the space's
    /// most recent tab outside a Pair and off screen everywhere joins, or a fresh tab.
    func openPair(with tabID: UUID? = nil, onSide side: Int = 1) {
        guard !isPair, let current = panes.first else { return }
        let spaceID = current.spaceID
        let anchor = current.tabID ?? library.insertTab(url: nil, spaceID: spaceID).id
        let shown = library.shownTabIDs
        let companion: UUID
        if let tabID, tabID != anchor, tab(id: tabID) != nil {
            companion = tabID
        } else if let other = (today(in: spaceID) + pinned(in: spaceID))
            .filter({ $0.id != anchor && pair(containing: $0.id) == nil && !shown.contains($0.id) })
            .max(by: { $0.lastActiveAt < $1.lastActiveAt }) {
            companion = other.id
        } else {
            companion = library.insertTab(url: nil, spaceID: spaceID).id
        }
        let pair = TabPair(tabIDs: side == 0 ? [companion, anchor] : [anchor, companion])
        library.addPair(pair)
        show(pair, focusing: companion)
        if let spaceID = tab(id: companion)?.spaceID { lastTabBySpace[spaceID] = companion }
        library.scheduleSave()
    }

    /// Takes the Pair on screen apart. The kept window's tab stays on screen; both tabs stay in the Spine.
    func closePair(keeping keep: Int? = nil) {
        guard let shown = shownPair else { return }
        separate(shown.id, keeping: keep ?? focusedPaneIndex)
    }

    /// Takes a Pair apart into two ordinary tabs.
    func separate(_ pairID: UUID, keeping keep: Int? = nil) {
        guard pair(id: pairID) != nil else { return }
        if shownPairID == pairID {
            let kept = panes[min(keep ?? focusedPaneIndex, panes.count - 1)]
            showSingle(kept.tabID, spaceID: kept.spaceID)
        }
        library.removePair(pairID)
    }

    /// Trades sides. The divider keeps its place from each window's point of view.
    func swapPair() {
        guard isPair, let shownPairID else { return }
        library.updatePair(shownPairID) { pair in
            pair.tabIDs.reverse()
            pair.split = pair.split.map { 1 - $0 }
        }
        panes.swapAt(0, 1)
        focusedPaneIndex = 1 - focusedPaneIndex
        library.scheduleSave()
    }

    /// Trades sides for any Pair, on screen in any window or waiting in the Spine.
    func swapSides(of pairID: UUID) {
        library.swapSides(of: pairID)
    }

    /// Nil puts the divider back in the middle. Each Pair remembers its own.
    func setPairSplit(_ split: Double?) {
        guard let shownPairID, pairSplit != split else { return }
        library.updatePair(shownPairID) { $0.split = split }
    }

    // MARK: Drag and drop

    func beginDrag(_ cargo: DragCargo) {
        library.beginDrag(cargo)
        // A tab picked up from the overlay Sidebar needs the windows uncovered to land on.
        if case .tab = cargo { isSidebarOverlayOpen = false }
    }

    func endDrag(_ cargo: DragCargo? = nil) {
        library.endDrag(cargo)
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
            library.keep(url, as: tier, spaceID: focusedPane.spaceID)
        }
    }

    // MARK: Auto-archive

    func setArchiveAfter(hours: Double?) { library.setArchiveAfter(hours: hours) }
    func nextArchiveDate(in spaceID: UUID) -> Date? { library.nextArchiveDate(in: spaceID) }
    var nextArchiveDate: Date? { library.nextArchiveDate }
    func archiveDate(for tab: BrowserTab) -> Date? { library.archiveDate(for: tab) }
    func sweepArchive(now: Date = .now) { library.sweepArchive(now: now) }
    func archiveAllToday() { library.archiveAllToday(in: focusedPane.spaceID) }
    func unloadIdleTabs(now: Date = .now) { library.unloadIdleTabs(now: now) }

    func restore(_ archivedID: UUID) {
        guard let item = library.takeFromArchive(archivedID) else { return }
        if let spaceID = item.spaceID, space(id: spaceID) != nil, focusedPane.spaceID != spaceID {
            switchSpace(to: spaceID)
        }
        let tab = newTab(url: item.url, title: item.title)
        library.setTileHex(item.tileHex, for: tab.id)
        isArchiveOpen = false
    }

    /// ⇧⌘T: the last tab closed comes back in its space.
    func reopenClosedTab() {
        guard let item = library.takeRecentlyClosed() else { return }
        if let spaceID = item.spaceID, space(id: spaceID) != nil, focusedPane.spaceID != spaceID {
            switchSpace(to: spaceID)
        }
        let tab = newTab(url: item.url, title: item.title)
        library.setTileHex(item.tileHex, for: tab.id)
    }

    // MARK: Settings

    func updateSettings(_ change: (inout BrowserSettings) -> Void) { library.updateSettings(change) }
    func clearBrowsingData() async { await library.clearBrowsingData() }
    func saveNow() { library.saveNow() }

    // MARK: Persistence

    func snapshot() -> WindowSnapshot {
        WindowSnapshot(
            panes: panes, focusedPaneIndex: focusedPaneIndex, spineState: spineBeforeNarrow ?? spineState,
            lastTabBySpace: lastTabBySpace, shownPairID: shownPairID
        )
    }

    /// Makes sure the windows on screen match the Pair they claim. State from before Pairs were
    /// kept turns its two windows into a Pair.
    private func apply(_ state: WindowSnapshot) {
        let ids = Set(tabs.map(\.id))
        var restored = state.panes.isEmpty ? [Pane(tabID: nil, spaceID: spaces[0].id)] : state.panes
        restored = restored.map { pane in
            var pane = pane
            if let tabID = pane.tabID, !ids.contains(tabID) { pane.tabID = nil }
            if space(id: pane.spaceID) == nil { pane.spaceID = spaces[0].id }
            return pane
        }
        focusedPaneIndex = min(state.focusedPaneIndex, max(restored.count - 1, 0))
        spineState = state.spineState
        lastTabBySpace = state.lastTabBySpace
        if restored.count == 2 {
            let onScreen = restored.compactMap(\.tabID)
            if let pair = pair(id: state.shownPairID), pair.tabIDs == onScreen {
                shownPairID = pair.id
            } else if onScreen.count == 2, onScreen.allSatisfy({ pair(containing: $0) == nil }) {
                let pair = TabPair(tabIDs: onScreen)
                library.addPair(pair)
                shownPairID = pair.id
            } else {
                restored = [restored[min(focusedPaneIndex, 1)]]
                focusedPaneIndex = 0
                shownPairID = nil
            }
        } else {
            restored = Array(restored.prefix(1))
            shownPairID = nil
        }
        panes = restored
    }
}
