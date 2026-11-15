import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// "The reading room": stone (desk), paper (pages, sheets), plus the three meaningful colors.
/// Values come from the Paper file's tokens; day and night are both first-class.
struct Palette: Equatable {
    var isDark = false
    /// The OLED option: at night the desk drops to true black.
    var trueBlack = false

    private func pick(_ day: UInt32, _ night: UInt32) -> Color {
        Color(hex: isDark ? night : day)
    }

    var desk: Color { pick(0xF6F3ED, trueBlack ? 0x000000 : 0x14110E) }
    var page: Color { pick(0xFEFDFA, 0x1E1A16) }
    /// Night depth comes from lighter surfaces, never shadows.
    var raised: Color { pick(0xFEFDFA, 0x292420) }
    var sunken: Color { pick(0xECE9E2, 0x0E0C09) }

    var text: Color { pick(0x221D18, 0xEAE7E2) }
    var textSecondary: Color { pick(0x605A54, 0xA8A49E) }
    var textTertiary: Color { pick(0x8A8580, 0x78746E) }
    var line: Color { pick(0xDEDAD3, 0x342F2B) }

    /// Verdigris: action, focus, selection.
    var accent: Color { pick(0x217969, 0x75BBAB) }
    var accentStrong: Color { pick(0x075A4D, 0x9AD1C4) }
    var accentSoft: Color { pick(0xD7F0E9, 0x19342E) }
    var onAccent: Color { pick(0xFEFDFA, 0x0C1916) }

    /// Copper: time (Today countdown, archive).
    var time: Color { pick(0x8B4A1D, 0xDA9B6A) }
    var timeSoft: Color { pick(0xF9E5D6, 0x35261A) }

    /// Madder: destructive and insecure, always with a word.
    var danger: Color { pick(0xAD3C33, 0xE68677) }

    var scrim: Color { Color(hex: isDark ? 0x000000 : 0x221D18, opacity: isDark ? 0.45 : 0.28) }
}

extension EnvironmentValues {
    @Entry var palette = Palette()
}

/// The seven bookcloth hues. A space's binding tints the Spine, the Pair bars and its inks.
enum SpaceBinding: String, Codable, CaseIterable, Identifiable {
    case verdigris, lapis, moss, ochre, madder, damson, graphite

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    private struct Tones {
        let tint: UInt32, deep: UInt32, ink: UInt32, sec: UInt32
    }

    private var day: Tones {
        switch self {
        case .verdigris: Tones(tint: 0xD5F1E9, deep: 0xBFE8DE, ink: 0x006B5B, sec: 0x335850)
        case .lapis: Tones(tint: 0xDBECFD, deep: 0xC8E1FB, ink: 0x305E8B, sec: 0x3D5268)
        case .moss: Tones(tint: 0xE1EEDA, deep: 0xD2E5C8, ink: 0x446630, sec: 0x45563C)
        case .ochre: Tones(tint: 0xF5E8D4, deep: 0xEFDBBD, ink: 0x765412, sec: 0x5E4D33)
        case .madder: Tones(tint: 0xFDE2DF, deep: 0xFBD3CF, ink: 0x864541, sec: 0x664643)
        case .damson: Tones(tint: 0xF9E2EE, deep: 0xF5D3E5, ink: 0x7E4566, sec: 0x624655)
        case .graphite: Tones(tint: 0xEFE8E1, deep: 0xE4DDD6, ink: 0x605A54, sec: 0x554F49)
        }
    }

    private var night: Tones {
        switch self {
        case .verdigris: Tones(tint: 0x102520, deep: 0x041C17, ink: 0x79C5B4, sec: 0x94AEA8)
        case .lapis: Tones(tint: 0x16222D, deep: 0x0B1825, ink: 0x8DB9E6, sec: 0x9AAABA)
        case .moss: Tones(tint: 0x1B2416, deep: 0x111A0B, ink: 0x9EC08D, sec: 0xA0AC99)
        case .ochre: Tones(tint: 0x281F11, deep: 0x1F1505, ink: 0xD1AE79, sec: 0xB2A693)
        case .madder: Tones(tint: 0x2D1B1A, deep: 0x241110, ink: 0xE3A19B, sec: 0xBAA19E)
        case .damson: Tones(tint: 0x2A1B23, deep: 0x22111A, ink: 0xDAA0C0, sec: 0xB6A1AC)
        case .graphite: Tones(tint: 0x251F1B, deep: 0x1B1611, ink: 0xBAB3AC, sec: 0xADA6A0)
        }
    }

    private func tones(_ p: Palette) -> Tones { p.isDark ? night : day }

    func tint(_ p: Palette) -> Color { Color(hex: tones(p).tint) }
    func deep(_ p: Palette) -> Color { Color(hex: tones(p).deep) }
    func ink(_ p: Palette) -> Color { Color(hex: tones(p).ink) }
    /// Secondary text on cloth uses the binding's own ink, never gray.
    func secondary(_ p: Palette) -> Color { Color(hex: tones(p).sec) }
}

enum Metrics {
    static let sidebarWidth: CGFloat = 280
    static let stripWidth: CGFloat = 56
    static let cardRadius: CGFloat = 22
    static let pairGutter: CGFloat = 12
    /// Below this the window is a cover-sized (compact) layout, not the open display.
    static let openMinimumWidth: CGFloat = 600
}

enum Motion {
    /// Decelerates, never bounces. Reduce Motion collapses the spring to a short ease.
    static func spring(reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8)
    }
}

/// SF Pro runs the interface on Apple text styles; New York tells the story.
enum Typeface {
    static let spaceTitle = Font.system(.title2, design: .serif).weight(.semibold)
    static let row = Font.subheadline
    static let rowActive = Font.subheadline.weight(.semibold)
    static let footnote = Font.footnote
    static let footnoteStrong = Font.footnote.weight(.semibold)
    static let sectionLabel = Font.caption2.weight(.semibold)
    static let countdown = Font.caption2.weight(.semibold).monospacedDigit()
}

struct SectionLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(Typeface.sectionLabel)
            .tracking(0.66)
            .foregroundStyle(color)
    }
}
