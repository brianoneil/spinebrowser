import Observation
import UIKit

/// Site icons, fetched from the site itself (never a third-party icon service) and cached on disk.
@MainActor
@Observable
final class FaviconStore {
    private var images: [String: UIImage] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []

    private static func key(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    private static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("favicons", isDirectory: true)
    }

    func image(for host: String?) -> UIImage? {
        guard let host else { return nil }
        let key = Self.key(host)
        if let image = images[key] { return image }
        guard !missing.contains(key) else { return nil }
        // Disk lookup happens once per host; the result lands via observation.
        missing.insert(key)
        Task { [weak self] in
            guard let file = Self.directory?.appendingPathComponent(key + ".png"),
                  let data = try? Data(contentsOf: file),
                  let image = UIImage(data: data) else { return }
            self?.images[key] = image
        }
        return nil
    }

    func fetch(hosts: [String], candidates: [URL]) {
        let keys = Array(Set(hosts.map(Self.key)))
        guard let primary = keys.first, !inFlight.contains(primary) else { return }
        guard keys.contains(where: { images[$0] == nil }) else { return }
        inFlight.insert(primary)
        Task { [weak self] in
            defer { self?.inFlight.remove(primary) }
            for url in candidates {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data), image.size.width >= 16 else { continue }
                for key in keys {
                    self?.images[key] = image
                    if let directory = Self.directory, let png = image.pngData() {
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try? png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
                    }
                }
                return
            }
        }
    }
}
