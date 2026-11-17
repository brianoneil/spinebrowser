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

    init(visit: Visit, size: CGFloat = 20) {
        host = visit.host
        title = visit.displayTitle
        tileHex = nil
        glyph = nil
        self.size = size
    }

    private var letter: String {
        if let glyph { return glyph }
        // The host's letter, so "Home - Kinfolk" still reads as K.
        let bare = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        let source = bare.isEmpty ? title : bare
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
            } else if let tile = tileHex {
                // A deliberate tile from seed data. Near-black ones vanish on night cloth, so they flip.
                let isNearBlack = (tile >> 16) & 0xFF < 0x40 && (tile >> 8) & 0xFF < 0x40 && tile & 0xFF < 0x40
                let flipped = p.isDark && isNearBlack
                ZStack {
                    Color(hex: flipped ? 0xEAE7E2 : tile)
                    Text(letter)
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(Color(hex: flipped ? 0x1E1A16 : 0xFEFDFA))
                }
            } else {
                // No icon yet: a quiet placeholder that can't pass for some other site's brand.
                ZStack {
                    p.sunken
                    Text(letter)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                .overlay { shape.strokeBorder(p.line, lineWidth: 1) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
