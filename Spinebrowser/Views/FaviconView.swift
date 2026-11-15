import SwiftUI

/// A site's icon, or a letter tile until the real one loads.
struct FaviconView: View {
    let host: String?
    let title: String
    var tileHex: UInt32?
    var glyph: String?
    var size: CGFloat = 20

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    init(tab: BrowserTab, size: CGFloat = 20) {
        host = tab.host
        title = tab.displayTitle
        tileHex = tab.tileHex
        glyph = tab.glyph
        self.size = size
    }

    init(archived: ArchivedTab, size: CGFloat = 20) {
        host = archived.host
        title = archived.title
        tileHex = archived.tileHex
        glyph = nil
        self.size = size
    }

    private static let fallbackTiles: [UInt32] = [
        0xC9452E, 0x2B2B2B, 0x8E2C2C, 0x6B6660, 0x2F5D4A, 0x1A73E8, 0x4A154B, 0x1E7D4F, 0xB3832B, 0x5E4A8A, 0x3F6C96,
    ]

    private var tile: UInt32 {
        if let tileHex { return tileHex }
        let seed = (host ?? title).unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Self.fallbackTiles[Int(seed % UInt32(Self.fallbackTiles.count))]
    }

    private var letter: String {
        if let glyph { return glyph }
        let source = title.isEmpty ? (host ?? "") : title
        return source.first.map { String($0).uppercased() } ?? "·"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let image = store.favicons.image(for: host) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                // Near-black tiles vanish on night cloth, so they flip to paper.
                let isNearBlack = (tile >> 16) & 0xFF < 0x40 && (tile >> 8) & 0xFF < 0x40 && tile & 0xFF < 0x40
                let flipped = p.isDark && isNearBlack
                ZStack {
                    Color(hex: flipped ? 0xEAE7E2 : tile)
                    Text(letter)
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(Color(hex: flipped ? 0x1E1A16 : 0xFEFDFA))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
