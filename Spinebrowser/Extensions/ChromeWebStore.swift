import Foundation

/// Where Chrome extensions come from: the Chrome Web Store hands out a signed CRX per extension id.
enum ChromeWebStore {
    static let home = URL(string: "https://chromewebstore.google.com/category/extensions")!

    static func isStore(_ url: URL?) -> Bool {
        url?.host()?.lowercased() == "chromewebstore.google.com"
    }

    /// The store only opens to desktop browsers, so its pages are asked for as a Mac would.
    /// The layout still fits the window: only the name changes.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// The extension a store page is about. Ids are 32 letters, a to p.
    static func extensionID(in url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents
        let isStore = host == "chromewebstore.google.com"
            || (host == "chrome.google.com" && parts.contains("webstore"))
        guard isStore, parts.contains("detail") else { return nil }
        return parts.last(where: isExtensionID)
    }

    static func isExtensionID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The store's update endpoint, which redirects to the newest CRX. It only learns the id.
    static func packageURL(for id: String) -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "140.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components.url!
    }
}

/// A CRX is a ZIP behind a signature header. WebKit reads ZIPs, so the header comes off.
enum ChromePackage {
    enum Failure: Error { case notAnExtension }

    static func zip(from data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count == 16 else { throw Failure.notAnExtension }
        // Already a plain ZIP.
        if bytes[0] == 0x50, bytes[1] == 0x4B { return data }
        guard bytes[0...3].elementsEqual("Cr24".utf8) else { throw Failure.notAnExtension }
        func word(at offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let start: Int
        switch word(at: 4) {
        case 2: start = 16 + word(at: 8) + word(at: 12)   // public key, then signature
        case 3: start = 12 + word(at: 8)                  // one signed header
        default: throw Failure.notAnExtension
        }
        guard start < data.count else { throw Failure.notAnExtension }
        return data.subdata(in: (data.startIndex + start)..<data.endIndex)
    }
}
