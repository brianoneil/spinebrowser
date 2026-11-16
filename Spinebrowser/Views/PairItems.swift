import SwiftUI

/// A Pair in the Sidebar: one row, its two tabs side by side as they sit on screen.
/// Tap either half to bring back the Pair with that window focused.
struct PairRow: View {
    let pair: TabPair
    let binding: SpaceBinding

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        let isShown = store.shownPairID == pair.id
        HStack(spacing: 0) {
            half(0, isShown: isShown)
            Rectangle()
                .fill(p.isDark ? p.line : binding.secondary(p).opacity(0.25))
                .frame(width: 1, height: 20)
                .accessibilityHidden(true)
            half(1, isShown: isShown)
        }
        .background {
            if isShown {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(p.raised)
                    .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.08), radius: 1, y: 1)
                    .shadow(color: binding.ink(p).opacity(p.isDark ? 0 : 0.10), radius: 6, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(binding.secondary(p).opacity(p.isDark ? 0.3 : 0.2), lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            if isShown { ActiveMark(binding: binding).padding(.leading, 3) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu { PairMenu(pair: pair) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pair")
    }

    @ViewBuilder
    private func half(_ side: Int, isShown: Bool) -> some View {
        if let tab = store.tab(id: pair.tabIDs[side]) {
            let isFocused = isShown && store.focusedPaneIndex == side
            Button {
                store.select(tab.id)
            } label: {
                HStack(spacing: 8) {
                    FaviconView(tab: tab, size: 18)
                    Text(tab.displayTitle)
                        .font(isFocused ? Typeface.rowActive : Typeface.row)
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("\(tab.displayTitle), \(side == 0 ? "left" : "right")")
            .accessibilityAddTraits(isShown ? .isSelected : [])
        }
    }
}

/// A Pair in the Spines or the Rail: its two icons stacked in one item, left on top.
struct PairStripItem: View {
    let pair: TabPair
    let binding: SpaceBinding

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        let isShown = store.shownPairID == pair.id
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 12, bottomLeadingRadius: 12,
            bottomTrailingRadius: isShown ? 0 : 12, topTrailingRadius: isShown ? 0 : 12,
            style: .continuous
        )
        VStack(spacing: 0) {
            member(0, isShown: isShown)
            Rectangle()
                .fill(binding.secondary(p).opacity(0.3))
                .frame(width: 16, height: 1)
                .accessibilityHidden(true)
            member(1, isShown: isShown)
        }
        .frame(width: isShown ? 50 : 44)
        .background(isShown ? p.page : binding.tint(p), in: shape)
        .frame(width: 50, alignment: .leading)
        .contextMenu { PairMenu(pair: pair) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pair")
    }

    @ViewBuilder
    private func member(_ side: Int, isShown: Bool) -> some View {
        if let tab = store.tab(id: pair.tabIDs[side]) {
            let isFocused = isShown && store.focusedPaneIndex == side
            Button {
                store.select(tab.id)
            } label: {
                FaviconView(tab: tab, size: 20)
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .overlay(alignment: .leading) {
                if isShown { ActiveMark(binding: binding, isFocused: isFocused).padding(.leading, 3) }
            }
            .accessibilityLabel("\(tab.displayTitle), \(side == 0 ? "left" : "right")")
            .accessibilityAddTraits(isShown ? .isSelected : [])
        }
    }
}

/// Long-press a Pair: swap, separate, close.
struct PairMenu: View {
    let pair: TabPair
    @Environment(BrowserStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button("Swap sides", systemImage: "arrow.left.arrow.right") {
            withAnimation(Motion.spring(reduce: reduceMotion)) { store.swapSides(of: pair.id) }
        }
        Button("Separate tabs", systemImage: "rectangle.split.2x1.slash") {
            withAnimation(Motion.spring(reduce: reduceMotion)) { store.separate(pair.id) }
        }
        Divider()
        Button("Close both tabs", systemImage: "xmark", role: .destructive) {
            withAnimation(Motion.spring(reduce: reduceMotion)) { store.close(pair: pair.id) }
        }
    }
}
