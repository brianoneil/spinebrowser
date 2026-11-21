import Foundation
import Observation
import SwiftUI

/// What every window shares: spaces, tabs, Pairs, the archive, settings and the live web views.
/// Each window keeps its own place among them in a `BrowserStore`.
///
/// A web page can only be on screen in one place, so a tab shows in one window at a time.
/// When a window takes a tab that another window shows, the other window lets it go.
@MainActor
@Observable
final class Library {
    private(set) var spaces: [Space] = []
    private(set) var tabs: [BrowserTab] = []
    private(set) var archive: [ArchivedTab] = []
    /// Two tabs that travel as one. Shared, so a Pair kept in one window waits in every Spine.
    private(set) var pairs: [TabPair] = []
    /// Nil turns auto-archive off.
    private(set) var archiveAfterHours: Double? = 12
    private(set) var settings = BrowserSettings()
    var runtime: [UUID: TabRuntime] = [:]
    /// Bumps when every web view is thrown away, so the hosts on screen build fresh ones.
    private(set) var webGeneration = 0
    /// What a finger is carrying right now. Shared, so a tab carried across to another window
    /// still lights that window's drop zones.
    private(set) var drag: DragCargo?
    /// The tabs each open window shows, by window.
    private(set) var shownByWindow: [UUID: [UUID]] = [:]
    /// Tabs closed this session, most recent last, so ⇧⌘T can bring them back.
    private(set) var recentlyClosed: [ArchivedTab] = []
    /// Pages visited, per Space. Kept in its own file.
    private(set) var history = HistoryPersistence.load()
    /// Tabs whose page has an article to read, by the address it was found on.
    private(set) var readerable: [UUID: URL] = [:]
    /// Tabs showing Reader. Runtime only.
    private(set) var reader: [UUID: ReaderSession] = [:]
    /// Tabs on their way to the archive. Their rows tilt onto the shelf as they go.
    private(set) var shelving: Set<UUID> = []
    /// The last tabs to shelve, by space, so the Spine can say how many just went.
    private(set) var lastShelved: (spaceIDs: Set<UUID>, count: Int, at: Date)?

    @ObservationIgnored private var windows: [UUID: WeakWindow] = [:]
    /// Window states kept on disk, by window. A window that comes back picks up its own.
    @ObservationIgnored private var savedWindows: [UUID: WindowSnapshot] = [:]
    /// State saved before windows were kept apart, or a fresh install's. The first window takes it.
    @ObservationIgnored private var unclaimedWindow: WindowSnapshot?
    @ObservationIgnored private(set) var lastActiveWindowID: UUID?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var historySaveTask: Task<Void, Never>?
    /// Tabs told to load an address, whose first page counts as a visit. A tab that reloads
    /// its saved page at launch isn't in here, so a relaunch doesn't count as visiting every tab.
    @ObservationIgnored private var expectsVisit: Set<UUID> = []
    @ObservationIgnored private(set) lazy var engine = WebEngine(library: self)
    let favicons = FaviconStore()

    init() {
        if let snapshot = Persistence.load() {
            apply(snapshot)
        } else {
            seed()
        }
        sweepArchive()
    }

    // MARK: Lookups

    func tab(id: UUID) -> BrowserTab? { tabs.first { $0.id == id } }
    func space(id: UUID?) -> Space? { spaces.first { $0.id == id } }

    var essentials: [BrowserTab] { tabs.filter { $0.tier == .essential } }
    func pinned(in spaceID: UUID) -> [BrowserTab] { tabs.filter { $0.tier == .pinned && $0.spaceID == spaceID } }
    func today(in spaceID: UUID) -> [BrowserTab] { tabs.filter { $0.tier == .today && $0.spaceID == spaceID } }

    func currentURL(for tab: BrowserTab) -> URL? { runtime[tab.id]?.currentURL ?? tab.url }

    func pair(id: UUID?) -> TabPair? { pairs.first { $0.id == id } }
    func pair(containing tabID: UUID) -> TabPair? { pairs.first { $0.tabIDs.contains(tabID) } }

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

    /// Every tab on screen in any window, and in windows that are closed for now but will come back.
    /// None of them count down to the archive or give their memory back.
    var shownTabIDs: Set<UUID> {
        var shown = Set(liveWindows.flatMap { $0.shownTabIDs })
        for (id, saved) in savedWindows where windows[id]?.store == nil {
            shown.formUnion(saved.panes.compactMap(\.tabID))
        }
        if let unclaimedWindow { shown.formUnion(unclaimedWindow.panes.compactMap(\.tabID)) }
        return shown
    }

    func isShown(_ tabID: UUID) -> Bool {
        shownByWindow.values.contains { $0.contains(tabID) } || shownTabIDs.contains(tabID)
    }

    // MARK: Windows

    private var liveWindows: [BrowserStore] { windows.values.compactMap(\.store) }

    func window(id: UUID) -> BrowserStore? { windows[id]?.store }

    /// The window showing this tab, if one does.
    func window(showing tabID: UUID) -> BrowserStore? {
        liveWindows.first { $0.shownTabIDs.contains(tabID) }
    }

    /// The window to act in when nothing names one: the last one touched.
    var activeWindow: BrowserStore? {
        lastActiveWindowID.flatMap(window(id:)) ?? liveWindows.first
    }

    /// Builds the store for a window: the one it had, the state from before windows, or a new one.
    func makeWindow(id: UUID) -> BrowserStore {
        if let existing = window(id: id) { return existing }
        let state: WindowSnapshot
        if let saved = savedWindows[id] {
            state = saved
        } else if let legacy = unclaimedWindow {
            state = legacy
            unclaimedWindow = nil
        } else {
            state = freshWindowState()
        }
        let store = BrowserStore(library: self, id: id, state: state)
        windows = windows.filter { $0.value.store != nil }
        windows[id] = WeakWindow(store: store)
        // A tab another window already shows stays there; this one falls back.
        let elsewhere = Set(liveWindows.filter { $0.id != id }.flatMap(\.shownTabIDs))
        store.release(elsewhere.intersection(store.shownTabIDs))
        store.isRegistered = true
        shownByWindow[id] = store.shownTabIDs
        pruneShown()
        if state.isFresh { store.startFresh() }
        lastActiveWindowID = lastActiveWindowID ?? id
        return store
    }

    /// A new window opens in the Space the last one was using, with a fresh tab.
    private func freshWindowState() -> WindowSnapshot {
        let spaceID = activeWindow?.focusedPane.spaceID ?? spaces[0].id
        return WindowSnapshot(
            panes: [Pane(tabID: nil, spaceID: spaceID)], focusedPaneIndex: 0, spineState: .sidebar,
            lastTabBySpace: [:], shownPairID: nil, isFresh: true
        )
    }

    func windowBecameActive(_ id: UUID) {
        lastActiveWindowID = id
    }

    /// A window now shows these tabs. Any other window showing one of them lets it go.
    func window(_ window: BrowserStore, shows tabIDs: [UUID]) {
        let fresh = Set(tabIDs).subtracting(shownByWindow[window.id] ?? [])
        if shownByWindow[window.id] != tabIDs { shownByWindow[window.id] = tabIDs }
        guard !fresh.isEmpty else { return }
        for other in liveWindows where other.id != window.id {
            other.release(fresh)
        }
    }

    /// Closed windows drop out of what's shown, so their tabs count down again.
    private func pruneShown() {
        let open = Set(windows.filter { $0.value.store != nil }.keys)
        let stale = shownByWindow.keys.filter { !open.contains($0) }
        stale.forEach { shownByWindow[$0] = nil }
    }

    /// After a shared change, each window checks that what it shows still exists.
    private func reconcileWindows() {
        liveWindows.forEach { $0.reconcile() }
    }

    // MARK: Tabs

    func touch(_ tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].lastActiveAt = .now
    }

    /// A new Today tab, most recent first.
    @discardableResult
    func insertTab(url: URL?, title: String = "", spaceID: UUID) -> BrowserTab {
        let tab = BrowserTab(url: url, title: title, tier: .today, spaceID: spaceID)
        tabs.insert(tab, at: tabs.firstIndex { $0.tier == .today } ?? tabs.count)
        if url != nil { expectsVisit.insert(tab.id) }
        scheduleSave()
        return tab
    }

    func setURL(_ url: URL, for tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }), tabs[i].url == nil else { return }
        tabs[i].url = url
        expectsVisit.insert(tabID)
        scheduleSave()
    }

    func setTileHex(_ hex: UInt32?, for tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].tileHex = hex
        scheduleSave()
    }

    /// Closing a tab in a Pair takes the Pair apart; a window showing it keeps the partner alone.
    func close(_ tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        if let url = tab.url {
            recentlyClosed.append(ArchivedTab(url: url, title: tab.displayTitle, spaceID: tab.spaceID, tileHex: tab.tileHex))
            if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        }
        pairs.removeAll { $0.tabIDs.contains(tabID) }
        engine.discard(tabID)
        runtime[tabID] = nil
        forgetReader(tabID)
        tabs.removeAll { $0.id == tabID }
        reconcileWindows()
        scheduleSave()
    }

    // MARK: Reader

    /// Whether Reader can open on this tab: it's open already, or its page has an article.
    func canRead(_ tabID: UUID) -> Bool {
        if reader[tabID] != nil { return true }
        guard let found = readerable[tabID] else { return false }
        return Self.samePage(found, runtime[tabID]?.currentURL)
    }

    func setReaderable(_ readable: Bool, for tabID: UUID, url: URL) {
        if readable {
            if readerable[tabID] != url { readerable[tabID] = url }
        } else if readerable[tabID] != nil {
            readerable[tabID] = nil
        }
    }

    /// Pulls the article out of the tab's live page and sets it in type. The page stays loaded
    /// underneath, so leaving Reader puts you back exactly where you were.
    func openReader(_ tabID: UUID) {
        guard reader[tabID] == nil, let view = engine.loadedView(tabID) else { return }
        reader[tabID] = ReaderSession(url: view.url)
        Task { @MainActor [weak self] in
            let article = await ReaderExtractor.extract(from: view)
            guard let self, self.reader[tabID] != nil else { return }
            if let article {
                self.reader[tabID]?.article = article
            } else {
                self.reader[tabID]?.failed = true
            }
        }
    }

    func closeReader(_ tabID: UUID) {
        reader[tabID] = nil
    }

    /// The reader page reports where you are as you read or turn.
    func readerMoved(_ tabID: UUID, progress: Double, page: Int, pages: Int) {
        guard var session = reader[tabID] else { return }
        session.progress = progress
        session.page = page
        session.pages = pages
        if session != reader[tabID] { reader[tabID] = session }
    }

    private func forgetReader(_ tabID: UUID) {
        reader[tabID] = nil
        readerable[tabID] = nil
    }

    /// The same page, give or take a #fragment.
    static func samePage(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        var x = URLComponents(url: a, resolvingAgainstBaseURL: false)
        var y = URLComponents(url: b, resolvingAgainstBaseURL: false)
        x?.fragment = nil
        y?.fragment = nil
        return x?.url == y?.url
    }

    func setTier(_ tier: TabTier, for tabID: UUID, spaceID fallbackSpace: UUID) {
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
            tab.spaceID = tab.spaceID ?? fallbackSpace
            let at = (tabs.lastIndex { $0.tier == .pinned }).map { $0 + 1 }
                ?? (tabs.lastIndex { $0.tier == .essential }).map { $0 + 1 } ?? 0
            tabs.insert(tab, at: at)
        case .today:
            tab.spaceID = tab.spaceID ?? fallbackSpace
            let at = tabs.firstIndex { $0.tier == .today } ?? tabs.count
            tabs.insert(tab, at: at)
        }
        scheduleSave()
    }

    func move(_ tabID: UUID, toSpace spaceID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }), tabs[i].tier != .essential else { return }
        tabs[i].spaceID = spaceID
        liveWindows.forEach { $0.tabMoved(tabID, to: spaceID) }
        scheduleSave()
    }

    // MARK: Spaces

    static let maximumSpaces = 8

    /// A new space, in the first binding no other space wears. Nil once there are eight.
    func addSpace(name: String, emoji: String, binding: SpaceBinding? = nil) -> Space? {
        guard spaces.count < Self.maximumSpaces else { return nil }
        let worn = Set(spaces.map(\.binding))
        let cloth = binding ?? SpaceBinding.allCases.first { !worn.contains($0) } ?? .graphite
        let space = Space(name: name, emoji: emoji, binding: cloth)
        spaces.append(space)
        scheduleSave()
        return space
    }

    func updateSpace(_ spaceID: UUID, _ change: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        var next = spaces[i]
        change(&next)
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.name.isEmpty { next.name = spaces[i].name }
        guard next != spaces[i] else { return }
        spaces[i] = next
        scheduleSave()
    }

    /// Deleting a space shelves its tabs, so nothing in it is lost: the archive keeps them.
    /// Windows in it move to the space before it.
    func deleteSpace(_ spaceID: UUID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let fallback = spaces[index == 0 ? 1 : index - 1].id
        for window in liveWindows where window.focusedPane.spaceID == spaceID || window.panes.contains(where: { $0.spaceID == spaceID }) {
            window.switchSpace(to: fallback)
        }
        tabs.filter { $0.spaceID == spaceID }.forEach(shelve)
        spaces.remove(at: index)
        reconcileWindows()
        scheduleSave()
    }

    /// Something kept on Essentials or Pinned from a link. It won't load until it's opened,
    /// so the site is asked for its icon now.
    func keep(_ url: URL, as tier: TabTier, spaceID: UUID) {
        guard ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host() else { return }
        let keptSpace = tier == .essential ? nil : spaceID
        guard !tabs.contains(where: { $0.tier == tier && $0.spaceID == keptSpace && $0.url == url }) else { return }
        let tab = BrowserTab(url: url, title: "", tier: .today, spaceID: spaceID)
        tabs.append(tab)
        setTier(tier, for: tab.id, spaceID: spaceID)
        let root = URL(string: "https://\(host)")
        let candidates = ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: root)?.absoluteURL }
        favicons.fetch(pageHost: host, aliases: [], candidates: candidates)
    }

    // MARK: Pairs

    func addPair(_ pair: TabPair) {
        // A tab belongs to one Pair at a time.
        pairs.removeAll { $0.tabIDs.contains(where: pair.tabIDs.contains) }
        pairs.append(pair)
        reconcileWindows()
        scheduleSave()
    }

    func removePair(_ pairID: UUID) {
        guard pair(id: pairID) != nil else { return }
        pairs.removeAll { $0.id == pairID }
        reconcileWindows()
        scheduleSave()
    }

    /// A tab leaving the Pair it was in, to join another.
    func removePair(containing tabID: UUID) {
        guard let pair = pair(containing: tabID) else { return }
        removePair(pair.id)
    }

    func updatePair(_ pairID: UUID, _ change: (inout TabPair) -> Void) {
        guard let i = pairs.firstIndex(where: { $0.id == pairID }) else { return }
        let before = pairs[i]
        change(&pairs[i])
        guard pairs[i] != before else { return }
        scheduleSave()
    }

    /// Trades sides for any Pair. A window showing it trades its windows too.
    func swapSides(of pairID: UUID) {
        if let window = liveWindows.first(where: { $0.shownPairID == pairID }) {
            window.swapPair()
            return
        }
        updatePair(pairID) { pair in
            pair.tabIDs.reverse()
            pair.split = pair.split.map { 1 - $0 }
        }
    }

    // MARK: Drag and drop

    func beginDrag(_ cargo: DragCargo) {
        guard drag != cargo else { return }
        drag = cargo
    }

    /// Ends the drag only if it's still the one that began, so a late callback can't end the next.
    func endDrag(_ cargo: DragCargo? = nil) {
        guard let drag, cargo == nil || cargo == drag else { return }
        self.drag = nil
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
        let shown = shownTabIDs
        return today(in: spaceID)
            .filter { !shown.contains($0.id) }
            .map { $0.lastActiveAt.addingTimeInterval(interval) }
            .min()
    }

    var nextArchiveDate: Date? {
        spaces.compactMap { nextArchiveDate(in: $0.id) }.min()
    }

    func archiveDate(for tab: BrowserTab) -> Date? {
        guard tab.tier == .today, let interval = archiveInterval, !isShown(tab.id) else { return nil }
        return tab.lastActiveAt.addingTimeInterval(interval)
    }

    func sweepArchive(now: Date = .now) {
        pruneShown()
        guard let interval = archiveInterval else { return }
        let shown = shownTabIDs
        let expired = tabs.filter {
            $0.tier == .today && !shown.contains($0.id) && now.timeIntervalSince($0.lastActiveAt) >= interval
        }
        guard !expired.isEmpty else { return }
        shelveTogether(expired)
    }

    func archiveAllToday(in spaceID: UUID) {
        let shown = shownTabIDs
        shelveTogether(today(in: spaceID).filter { !shown.contains($0.id) })
    }

    /// The signature moment: rows learn they're shelving first, so they leave with the tilt,
    /// then go together half a second later.
    private func shelveTogether(_ leaving: [BrowserTab]) {
        guard !leaving.isEmpty else { return }
        let ids = Set(leaving.map(\.id))
        shelving.formUnion(ids)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self else { return }
            let still = self.tabs.filter { ids.contains($0.id) }
            withAnimation(.timingCurve(0.5, 0, 0.3, 1, duration: 0.5)) {
                still.forEach(self.shelve)
                self.reconcileWindows()
                self.lastShelved = (Set(still.compactMap(\.spaceID)), still.count, .now)
            }
            self.shelving.subtract(ids)
            self.scheduleSave()
        }
    }

    /// A Pair's tabs are shown and touched together, so they come due together. A pinned partner
    /// stays behind as an ordinary tab.
    private func shelve(_ tab: BrowserTab) {
        pairs.removeAll { $0.tabIDs.contains(tab.id) }
        engine.discard(tab.id)
        runtime[tab.id] = nil
        forgetReader(tab.id)
        tabs.removeAll { $0.id == tab.id }
        guard let url = tab.url else { return }
        archive.insert(
            ArchivedTab(url: url, title: tab.displayTitle, spaceID: tab.spaceID, tileHex: tab.tileHex),
            at: 0
        )
    }

    /// The last tab closed, taken back so a window can reopen it.
    func takeRecentlyClosed() -> ArchivedTab? {
        recentlyClosed.popLast()
    }

    /// Takes an item off the shelf. The window restoring it opens it as a tab.
    func takeFromArchive(_ archivedID: UUID) -> ArchivedTab? {
        guard let i = archive.firstIndex(where: { $0.id == archivedID }) else { return nil }
        let item = archive.remove(at: i)
        scheduleSave()
        return item
    }

    /// Zen-style unload: tabs idle past 30 minutes give their memory back and reload on activation.
    func unloadIdleTabs(now: Date = .now) {
        guard settings.unloadsIdleTabs else { return }
        let shown = shownTabIDs
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
            engine.setContentBlocking(next.blocksTrackers, reloading: Array(shownTabIDs))
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
        history.removeAll()
        HistoryPersistence.save(history)
        favicons.clear()
        webGeneration += 1
        saveNow()
    }

    // MARK: Web callbacks

    func webDidUpdate(_ tabID: UUID, title: String?, state: TabRuntime) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let previous = runtime[tabID]?.currentURL
        // A new page brings the pill back so you can see where you landed.
        if previous != state.currentURL {
            setAddressHidden(false, for: tabID)
            // Reader belongs to the page it opened on. Somewhere new, the page shows.
            if let session = reader[tabID], state.currentURL != nil, !Self.samePage(session.url, state.currentURL) {
                reader[tabID] = nil
            }
            if let found = readerable[tabID], !Self.samePage(found, state.currentURL) { readerable[tabID] = nil }
        }
        recordVisit(tabID, from: previous, title: title, state: state)
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

    /// A new address in a tab is a visit when you got there: a link, back or forward, or an
    /// address you gave it. A tab coming back with the page it already had is not.
    private func recordVisit(_ tabID: UUID, from previous: URL?, title: String?, state: TabRuntime) {
        guard let url = state.currentURL, let tab = tab(id: tabID),
              let spaceID = tab.spaceID ?? window(showing: tabID)?.focusedPane.spaceID else { return }
        // The address can land before the page's title does. A title that hasn't changed
        // still belongs to the page before, so it waits for the next update.
        let freshTitle = title.flatMap { $0.isEmpty || $0 == tab.title ? nil : $0 }
        if url != previous, previous != nil || expectsVisit.remove(tabID) != nil {
            history.record(url, title: freshTitle ?? "", spaceID: spaceID, tabID: tabID)
            scheduleHistorySave()
        } else if url == previous, let freshTitle, history.setTitle(freshTitle, for: url, spaceID: spaceID) {
            scheduleHistorySave()
        }
    }

    /// Scrolling a page hides or shows the pill in the window showing it.
    func setAddressHidden(_ hidden: Bool, for tabID: UUID) {
        window(showing: tabID)?.setAddressHidden(hidden, for: tabID)
    }

    /// A page asked for a new window: it opens as a tab beside it, in the window showing that page.
    func pageOpened(_ url: URL, from tabID: UUID?) {
        let window = tabID.flatMap(window(showing:)) ?? activeWindow
        window?.newTab(url: url)
    }

    /// A link to peek at opens in a Glance in the window showing the page it came from.
    func peek(_ url: URL, from tabID: UUID?, origin: CGPoint?) {
        let window = tabID.flatMap(window(showing:)) ?? activeWindow
        window?.openGlance(url, from: tabID, origin: origin)
    }

    func glanceDidUpdate(_ id: UUID, url: URL?, isLoading: Bool, progress: Double) {
        liveWindows.first { $0.glance?.id == id }?.glanceDidUpdate(url: url, isLoading: isLoading, progress: progress)
    }

    func pageDragged(_ began: Bool, from tabID: UUID) {
        if began {
            beginDrag(.web(from: tabID))
        } else {
            endDrag(.web(from: tabID))
        }
    }

    // MARK: Persistence

    func scheduleSave() {
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
        historySaveTask?.cancel()
        HistoryPersistence.save(history)
    }

    private func scheduleHistorySave() {
        historySaveTask?.cancel()
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            HistoryPersistence.save(self.history)
        }
    }

    private func snapshot() -> Snapshot {
        let now = Date.now
        for window in liveWindows {
            var state = window.snapshot()
            state.savedAt = now
            savedWindows[window.id] = state
        }
        // A window left closed for two weeks is gone for good; its tabs count down again.
        let open = Set(liveWindows.map(\.id))
        savedWindows = savedWindows.filter { open.contains($0.key) || now.timeIntervalSince($0.value.savedAt) < 14 * 86_400 }
        // The single-window fields keep the most recent window, so older builds still open.
        let primary = activeWindow?.snapshot() ?? unclaimedWindow ?? savedWindows.values.max { $0.savedAt < $1.savedAt }
            ?? freshWindowState()
        return Snapshot(
            spaces: spaces, tabs: tabs, archive: archive, panes: primary.panes,
            focusedPaneIndex: primary.focusedPaneIndex, spineState: primary.spineState,
            archiveAfterHours: archiveAfterHours, lastTabBySpace: primary.lastTabBySpace,
            settings: settings, pairs: pairs, shownPairID: primary.shownPairID,
            windows: savedWindows
        )
    }

    /// Drops Pairs whose tabs are gone or claimed twice.
    private func validPairs(_ saved: [TabPair]) -> [TabPair] {
        let ids = Set(tabs.map(\.id))
        var claimed = Set<UUID>()
        return saved.filter { pair in
            guard pair.tabIDs.count == 2, pair.tabIDs[0] != pair.tabIDs[1],
                  pair.tabIDs.allSatisfy({ ids.contains($0) && !claimed.contains($0) }) else { return false }
            claimed.formUnion(pair.tabIDs)
            return true
        }
    }

    private func apply(_ snapshot: Snapshot) {
        spaces = snapshot.spaces
        tabs = snapshot.tabs
        archive = snapshot.archive
        archiveAfterHours = snapshot.archiveAfterHours
        settings = snapshot.settings ?? BrowserSettings()
        pairs = validPairs(snapshot.pairs ?? [])
        savedWindows = snapshot.windows ?? [:]
        if savedWindows.isEmpty {
            unclaimedWindow = WindowSnapshot(
                panes: snapshot.panes, focusedPaneIndex: snapshot.focusedPaneIndex, spineState: snapshot.spineState,
                lastTabBySpace: snapshot.lastTabBySpace, shownPairID: snapshot.shownPairID
            )
        }
        if spaces.isEmpty || (savedWindows.isEmpty && snapshot.panes.isEmpty) { seed() }
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
        savedWindows = [:]
        unclaimedWindow = WindowSnapshot(
            panes: [Pane(tabID: kinfolk.id, spaceID: personal.id)], focusedPaneIndex: 0, spineState: .sidebar,
            lastTabBySpace: [personal.id: kinfolk.id], shownPairID: nil
        )
    }
}

private struct WeakWindow {
    weak var store: BrowserStore?
}

/// One window's place in the library: which tabs it shows, its Spine, its Pair.
struct WindowSnapshot: Codable {
    var panes: [Pane]
    var focusedPaneIndex: Int
    var spineState: SpineState
    var lastTabBySpace: [UUID: UUID]
    var shownPairID: UUID?
    var savedAt = Date()
    /// A window opened just now, which starts on a new tab with the command bar up. Never saved true.
    var isFresh = false

    private enum CodingKeys: String, CodingKey {
        case panes, focusedPaneIndex, spineState, lastTabBySpace, shownPairID, savedAt
    }

    init(panes: [Pane], focusedPaneIndex: Int, spineState: SpineState, lastTabBySpace: [UUID: UUID],
         shownPairID: UUID?, isFresh: Bool = false) {
        self.panes = panes
        self.focusedPaneIndex = focusedPaneIndex
        self.spineState = spineState
        self.lastTabBySpace = lastTabBySpace
        self.shownPairID = shownPairID
        self.isFresh = isFresh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panes = try c.decode([Pane].self, forKey: .panes)
        focusedPaneIndex = try c.decode(Int.self, forKey: .focusedPaneIndex)
        spineState = try c.decode(SpineState.self, forKey: .spineState)
        lastTabBySpace = try c.decode([UUID: UUID].self, forKey: .lastTabBySpace)
        shownPairID = try c.decodeIfPresent(UUID.self, forKey: .shownPairID)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(panes, forKey: .panes)
        try c.encode(focusedPaneIndex, forKey: .focusedPaneIndex)
        try c.encode(spineState, forKey: .spineState)
        try c.encode(lastTabBySpace, forKey: .lastTabBySpace)
        try c.encodeIfPresent(shownPairID, forKey: .shownPairID)
        try c.encode(savedAt, forKey: .savedAt)
    }
}

struct Snapshot: Codable {
    var spaces: [Space]
    var tabs: [BrowserTab]
    var archive: [ArchivedTab]
    /// The most recent window's state, kept so a build from before windows still opens.
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
    /// Every window's state, by window. Optional so state saved before windows still loads.
    var windows: [UUID: WindowSnapshot]?
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
