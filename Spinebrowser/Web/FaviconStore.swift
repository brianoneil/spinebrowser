import Foundation
import Observation

/// Site icons, fetched from the site itself (never a third-party icon service) and cached on disk.
@MainActor
@Observable
final class FaviconStore {
    private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Hosts whose icon came from their own page this launch. That icon is the authority: an alias
    /// never overwrites it, and the disk copy is refreshed once per launch so a bad one heals.
    @ObservationIgnored private var fresh: Set<String> = []

    private static func key(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    private static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("favicons", isDirectory: true)
    }

    func image(for host: String?) -> PlatformImage? {
        guard let host else { return nil }
        let key = Self.key(host)
        if let image = images[key] { return image }
        guard !missing.contains(key) else { return nil }
        // Disk lookup happens once per host; the result lands via observation.
        missing.insert(key)
        Task { [weak self] in
            guard let file = Self.directory?.appendingPathComponent(key + ".png"),
                  let data = try? Data(contentsOf: file),
                  let image = PlatformImage(data: data) else { return }
            // A fetch may have landed a newer icon while the disk was read.
            guard let self, self.images[key] == nil else { return }
            self.images[key] = image
        }
        return nil
    }

    /// Forgets every icon, on disk too. Sites hand theirs back on the next visit.
    func clear() {
        images.removeAll()
        missing.removeAll()
        fresh.removeAll()
        if let directory = Self.directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Fetches the icon a page declares and files it under the page's host. `aliases` are hosts
    /// whose address led to this page (a redirect); they share the icon unless they have their own.
    func fetch(pageHost: String, aliases: [String], candidates: [URL]) {
        let key = Self.key(pageHost)
        let aliasKeys = Set(aliases.map(Self.key)).subtracting([key])
        let needed = !fresh.contains(key) || aliasKeys.contains { images[$0] == nil }
        guard needed, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { [weak self] in
            defer { self?.inFlight.remove(key) }
            for url in candidates {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = PlatformImage(data: data), image.size.width >= 16 else { continue }
                guard let self else { return }
                self.fresh.insert(key)
                self.store(image, as: key)
                for alias in aliasKeys where !self.fresh.contains(alias) {
                    self.store(image, as: alias)
                }
                return
            }
        }
    }

    private func store(_ image: PlatformImage, as key: String) {
        images[key] = image
        guard let directory = Self.directory, let png = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
    }
}
