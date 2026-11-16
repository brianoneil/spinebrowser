import SwiftUI

// MARK: Drop zone

/// Where a drag can land: soft accent paper with a dashed edge. It brightens under the finger.
struct DropZone: View {
    let label: String
    var isTargeted = false
    /// The compact form sits inside a window's 44pt bar.
    var compact = false

    @Environment(\.palette) private var p

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 6))
            : AnyLayout(VStackLayout(spacing: 6))
        layout {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: compact ? 13 : 20, weight: .semibold))
                .foregroundStyle(p.accent)
            Text(label)
                .font(Typeface.footnoteStrong)
                .foregroundStyle(p.accentStrong)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Over a window the page shows through, so you can see what you're replacing.
        // In the bar the zone has to hide the chip and domain beneath it.
        .background(p.accentSoft.opacity(compact ? 1 : (isTargeted ? 0.84 : 0.6)), in: shape)
        .overlay {
            shape.strokeBorder(
                p.accent.opacity(isTargeted ? 1 : 0.6),
                style: StrokeStyle(lineWidth: 2, dash: [6, 4])
            )
        }
        .scaleEffect(isTargeted ? 1 : 0.985)
        .animation(.snappy(duration: 0.18), value: isTargeted)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Picking up a tab

extension View {
    /// Lets a tab be picked up and dropped on a window. Other apps receive its address.
    func tabDragSource(_ tab: BrowserTab) -> some View {
        modifier(TabDragSource(tab: tab))
    }
}

private struct TabDragSource: ViewModifier {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store

    func body(content: Content) -> some View {
        if let url = store.currentURL(for: tab) {
            content
                .draggable(url)
                .onDragSessionUpdated { session in
                    switch session.phase {
                    case .initial, .active:
                        store.beginDrag(.tab(tab.id))
                    case .ending, .ended, .dataTransferCompleted:
                        store.endDrag(.tab(tab.id))
                    @unknown default:
                        store.endDrag(.tab(tab.id))
                    }
                }
        } else {
            content
        }
    }
}

// MARK: Landing a tab

/// Covers a window while a tab is in flight. Drop to show the tab there.
struct TabDropTarget: View {
    let label: String
    let onDrop: (UUID) -> Void

    @Environment(BrowserStore.self) private var store
    @State private var isTargeted = false

    var body: some View {
        DropZone(label: label, isTargeted: isTargeted)
            .padding(12)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { _, _ in
                // The address is for other apps. Here the store knows which tab is in flight.
                guard case let .tab(tabID) = store.drag else { return false }
                onDrop(tabID)
                return true
            } isTargeted: { isTargeted = $0 }
            .transition(.opacity)
    }
}

// MARK: Keeping a link or tab

extension View {
    /// Makes Essentials or Pinned a place to drop links and tabs. While anything is in flight
    /// the area wears a dashed edge, and brightens under the finger.
    func keepDropTarget(_ tier: TabTier, radius: CGFloat = 14) -> some View {
        modifier(KeepDropTarget(tier: tier, radius: radius))
    }
}

private struct KeepDropTarget: ViewModifier {
    let tier: TabTier
    let radius: CGFloat

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .overlay {
                if store.drag != nil || isTargeted {
                    shape
                        .fill(p.accentSoft.opacity(isTargeted ? 0.55 : 0))
                        .overlay {
                            shape.strokeBorder(
                                p.accent.opacity(isTargeted ? 1 : 0.5),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                            )
                        }
                        .padding(-5)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                store.drop(urls.first, keepingAs: tier)
                return true
            } isTargeted: { isTargeted = $0 }
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .animation(.easeOut(duration: 0.15), value: store.drag)
    }
}

/// Stands in for an empty Pinned while something is in flight, so there's somewhere to drop it.
struct PinPlaceholder: View {
    var compact = false
    @Environment(\.palette) private var p

    var body: some View {
        if compact {
            Image(systemName: "pin")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(p.accent)
                .frame(width: 44, height: 40)
                .accessibilityLabel("Drop here to pin")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "pin").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.accent)
                Text("Drop here to pin").font(Typeface.footnoteStrong).foregroundStyle(p.accentStrong)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
    }
}

// MARK: The divider

/// The Pair's gutter handle. Flat, it drags to resize with a magnetic detent at the fold.
/// Bent, the divider locks to the fold and the grip goes away. Without a fold (iPad) the detent
/// is the even split.
struct PairDivider: View {
    /// The divider's centre, in the page row's coordinates.
    let x: CGFloat
    let foldX: CGFloat
    /// Where the divider may travel, so neither window gets too narrow.
    let range: ClosedRange<CGFloat>
    let onMove: (CGFloat) -> Void
    let onRest: (CGFloat?) -> Void

    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hasFold) private var hasFold
    @State private var dragStart: CGFloat?

    /// How close to the fold a release has to be to snap onto it.
    static let detent: CGFloat = 22

    var body: some View {
        let isDragging = dragStart != nil
        let onFold = abs(x - foldX) < 0.5
        GeometryReader { geo in
            ZStack {
                // The grip. A wide, invisible strip makes it easy to catch.
                Capsule()
                    .fill(isDragging ? p.textSecondary : p.textTertiary)
                    .frame(width: 4, height: 44)
                    .frame(width: 32)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .position(x: x, y: geo.size.height / 2)
                    // Double-tap sends the divider home to the fold: 50/50.
                    .gesture(drag)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { rest(at: foldX) })
                    .accessibilityElement()
                    .accessibilityLabel("Divider")
                    .accessibilityValue(onFold ? (hasFold ? "On the fold" : "Even split") : "Left window \(Int(share(geo) * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        let step = (range.upperBound - range.lowerBound) / 10
                        let next = x + (direction == .increment ? step : -step)
                        rest(at: min(range.upperBound, max(range.lowerBound, next)))
                    }
                    .accessibilityAction(named: hasFold ? "Rest on the fold" : "Split evenly") { rest(at: foldX) }

                // The fold's detent: a bead on the crease, filled when the divider sits on it.
                if isDragging {
                    Circle()
                        .fill(onFold ? p.accent : p.desk)
                        .overlay { Circle().strokeBorder(p.accent, lineWidth: 1.5) }
                        .frame(width: 11, height: 11)
                        .position(x: foldX, y: geo.size.height - 48)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
        }
        .sensoryFeedback(.alignment, trigger: onFold) { _, now in now && isDragging }
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    private func share(_ geo: GeometryProxy) -> Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? Double((x - range.lowerBound) / span) : 0.5
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? x
                if dragStart == nil { dragStart = x }
                let raw = min(range.upperBound, max(range.lowerBound, start + value.translation.width))
                // Magnetic: inside the detent the divider sits on the fold.
                onMove(abs(raw - foldX) < Self.detent ? foldX : raw)
            }
            .onEnded { value in
                let start = dragStart ?? x
                dragStart = nil
                let end = min(range.upperBound, max(range.lowerBound, start + value.translation.width))
                rest(at: end)
            }
    }

    private func rest(at position: CGFloat) {
        withAnimation(Motion.spring(reduce: reduceMotion)) {
            onRest(abs(position - foldX) < Self.detent ? nil : position)
        }
    }
}
