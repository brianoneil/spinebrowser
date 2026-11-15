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
