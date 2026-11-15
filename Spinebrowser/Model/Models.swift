import Foundation

enum TabTier: String, Codable {
    /// Global, never archives.
    case essential
    /// Per-space, never archives.
    case pinned
    /// Ephemeral, archives on a timer.
    case today
}

struct BrowserTab: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL?
    var title: String
    var tier: TabTier
    /// Nil for Essentials, which show in every space.
    var spaceID: UUID?
    var createdAt = Date()
    var lastActiveAt = Date()
    /// Letter-tile color used until the site's real icon loads.
    var tileHex: UInt32?
    var glyph: String?

    var host: String? {
        guard let host = url?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return host ?? "New tab"
    }
}

struct Space: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var emoji: String
    var binding: SpaceBinding
}

struct ArchivedTab: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    var spaceID: UUID?
    var archivedAt = Date()
    var tileHex: UInt32?

    var host: String? {
        guard let host = url.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The Spine's four widths on the open display.
enum SpineState: String, Codable {
    case sidebar, spines, rail, hidden
}

/// A window onto a tab. One pane normally; two make the Pair.
struct Pane: Identifiable, Codable, Equatable {
    var id = UUID()
    var tabID: UUID?
    var spaceID: UUID
}

/// The habits you set once. Auto-archive timing lives on the store with the archive it drives.
struct BrowserSettings: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable, Identifiable {
        case system, day, night
        var id: String { rawValue }
    }

    var theme: Theme = .system
    var unloadsIdleTabs = true
    var blocksTrackers = true
    /// At night the desk goes OLED black. Pages and the Spine keep their tone.
    var trueBlackAtNight = false

    init() {}

    // Every key is optional on disk, so a setting added later never wipes the saved state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BrowserSettings()
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? defaults.theme
        unloadsIdleTabs = (try? c.decodeIfPresent(Bool.self, forKey: .unloadsIdleTabs)) ?? defaults.unloadsIdleTabs
        blocksTrackers = (try? c.decodeIfPresent(Bool.self, forKey: .blocksTrackers)) ?? defaults.blocksTrackers
        trueBlackAtNight = (try? c.decodeIfPresent(Bool.self, forKey: .trueBlackAtNight)) ?? defaults.trueBlackAtNight
    }
}

/// Live web state that never persists.
struct TabRuntime: Equatable {
    var currentURL: URL?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var isSecure = true
}

enum NavigationInput {
    /// Turns what the user typed into a destination: a URL when it reads like one, a search otherwise.
    static func destination(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = explicitURL(trimmed) { return url }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    static func explicitURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let looksLikeHost = hostPart.contains(".") && !hostPart.hasPrefix(".") && !hostPart.hasSuffix(".")
        guard looksLikeHost || hostPart.hasPrefix("localhost") else { return nil }
        return URL(string: "https://" + trimmed)
    }
}
