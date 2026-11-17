import Foundation

/// A page you've been to in one Space, with the stats that rank it: how often, and how lately.
struct Visit: Codable, Identifiable, Equatable {
    var url: URL
    var title: String
    /// History is per Space. Essentials count toward the Space they were opened in.
    var spaceID: UUID
    var visitCount = 1
    var firstVisitedAt = Date()
    var lastVisitedAt = Date()
    /// The latest visits, oldest first, capped at `History.recentCap`. Frecency weighs these.
    var recentVisits: [Date] = [Date()]

    var id: String { "\(spaceID.uuidString) \(url.absoluteString)" }

    var host: String? {
        guard let host = url.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String { title.isEmpty ? (host ?? url.absoluteString) : title }

    /// Visits weighted by age, scaled up to the full count: a site you open daily beats one
    /// you opened fifty times last year.
    func frecency(now: Date = .now) -> Double {
        guard !recentVisits.isEmpty else { return 0 }
        let weights = recentVisits.map { date -> Double in
            switch now.timeIntervalSince(date) / 86_400 {
            case ..<4: 100
            case ..<14: 70
            case ..<31: 50
            case ..<90: 30
            default: 10
            }
        }
        return weights.reduce(0, +) * Double(visitCount) / Double(recentVisits.count)
    }
}

/// Every page visited, kept on this device only. Feeds Recent, Frequent and the typed
/// suggestions in the command bar.
struct History {
    private(set) var visits: [Visit] = []

    static let recentCap = 10
    private static let entryCap = 3_000
    /// A second address inside this window, in the same tab, is a redirect, not a new visit.
    private static let redirectWindow: TimeInterval = 3

    /// The last visit each tab recorded, so a redirect can take its place. Never saved.
    private var lastRecorded: [UUID: (id: String, at: Date)] = [:]

    init(visits: [Visit] = []) {
        self.visits = visits
    }

    /// Fragments drop so `#section` links don't split one page into many.
    static func key(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else {
            return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    mutating func record(_ url: URL, title: String, spaceID: UUID, tabID: UUID, now: Date = .now) {
        guard let page = Self.key(for: url) else { return }
        let id = Visit(url: page, title: "", spaceID: spaceID).id

        if let last = lastRecorded[tabID], last.id != id, now.timeIntervalSince(last.at) < Self.redirectWindow {
            undo(last.id)
        }
        lastRecorded[tabID] = (id, now)

        if let i = visits.firstIndex(where: { $0.id == id }) {
            var visit = visits.remove(at: i)
            visit.visitCount += 1
            visit.lastVisitedAt = now
            visit.recentVisits = Array((visit.recentVisits + [now]).suffix(Self.recentCap))
            if !title.isEmpty { visit.title = title }
            visits.append(visit)
        } else {
            visits.append(Visit(
                url: page, title: title, spaceID: spaceID,
                firstVisitedAt: now, lastVisitedAt: now, recentVisits: [now]
            ))
        }
        if visits.count > Self.entryCap { visits.removeFirst(visits.count - Self.entryCap) }
    }

    /// Titles arrive after the address, so the newest visit picks its title up late.
    /// True when the title changed.
    @discardableResult
    mutating func setTitle(_ title: String, for url: URL, spaceID: UUID) -> Bool {
        guard !title.isEmpty, let page = Self.key(for: url) else { return false }
        let id = Visit(url: page, title: "", spaceID: spaceID).id
        guard let i = visits.lastIndex(where: { $0.id == id }), visits[i].title != title else { return false }
        visits[i].title = title
        return true
    }

    mutating func removeAll() {
        visits.removeAll()
        lastRecorded.removeAll()
    }

    private mutating func undo(_ id: String) {
        guard let i = visits.firstIndex(where: { $0.id == id }) else { return }
        if visits[i].visitCount <= 1 {
            visits.remove(at: i)
        } else {
            visits[i].visitCount -= 1
            visits[i].recentVisits.removeLast()
            visits[i].lastVisitedAt = visits[i].recentVisits.last ?? visits[i].firstVisitedAt
        }
    }

    // MARK: Queries

    func visits(in spaceID: UUID) -> [Visit] { visits.filter { $0.spaceID == spaceID } }

    /// Most recent first.
    func recent(in spaceID: UUID) -> [Visit] {
        visits(in: spaceID).sorted { $0.lastVisitedAt > $1.lastVisitedAt }
    }

    /// One entry per site, strongest first. Each site opens at its own most-visited page.
    func frequentSites(in spaceID: UUID, excludingHosts excluded: Set<String> = [], now: Date = .now) -> [Visit] {
        let bySite = Dictionary(grouping: visits(in: spaceID).filter { $0.host.map { !excluded.contains($0) } ?? false }) {
            $0.host ?? ""
        }
        return bySite.values
            .compactMap { pages -> (Double, Int, Visit)? in
                guard let best = pages.max(by: { $0.frecency(now: now) < $1.frecency(now: now) }) else { return nil }
                let count = pages.reduce(0) { $0 + $1.visitCount }
                return (pages.reduce(0) { $0 + $1.frecency(now: now) }, count, best)
            }
            // Once isn't a habit.
            .filter { $0.1 >= 2 }
            .sorted { $0.0 > $1.0 }
            .map(\.2)
    }
}

/// History lives in its own file beside the app state, so the state saves that run on every
/// tab change don't rewrite a long history each time.
enum HistoryPersistence {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Spinebrowser", isDirectory: true).appendingPathComponent("history.json")
    }

    static func load() -> History {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let visits = try? JSONDecoder().decode([Visit].self, from: data) else { return History() }
        return History(visits: visits)
    }

    static func save(_ history: History) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(history.visits) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
