import SwiftUI
import WebKit

/// A Glance over one region of the page row: the other window of a Pair, the far side of a single
/// page, or the whole page on the cover. A scrim dims the region; the card floats in it.
struct GlanceOverlay: View {
    /// Where the Glance may sit, in this view's coordinates. Nil fills the view.
    var region: CGRect?
    var scrimRadius: CGFloat = Metrics.cardRadius

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let area = region ?? CGRect(origin: .zero, size: geo.size)
            let global = geo.frame(in: .global)
            ZStack(alignment: .topLeading) {
                if let glance = store.glance {
                    RoundedRectangle(cornerRadius: scrimRadius, style: .continuous)
                        .fill(Color(hex: 0x221D18, opacity: p.isDark ? 0.5 : 0.32))
                        .frame(width: area.width, height: area.height)
                        .offset(x: area.minX, y: area.minY)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Self.motion(reduceMotion)) { store.dismissGlance() } }
                        .accessibilityLabel("Dismiss Glance")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)

                    let card = Self.cardFrame(in: area)
                    GlanceCard(glance: glance)
                        .frame(width: card.width, height: card.height)
                        .offset(x: card.minX, y: card.minY)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.92, anchor: anchor(glance.origin, card: card, global: global))
                                    .combined(with: .opacity)
                        )
                        .id(glance.id)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(Self.motion(reduceMotion), value: store.glance?.id)
        }
        .allowsHitTesting(store.glance != nil)
    }

    /// Response 0.32, decelerating into place. Reduce Motion fades instead.
    static func motion(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.86)
    }

    /// Inset 14 at the sides, clear of the window's bar at the top, with room below to see the page.
    static func cardFrame(in area: CGRect) -> CGRect {
        let top: CGFloat = area.height > 520 ? 46 : 14
        let bottom: CGFloat = area.height > 520 ? 63 : 14
        return CGRect(
            x: area.minX + 14, y: area.minY + top,
            width: max(0, area.width - 28), height: max(0, area.height - top - bottom)
        )
    }

    /// The card grows from the pressed link, or from its own middle when there's no press to go by.
    private func anchor(_ origin: CGPoint?, card: CGRect, global: CGRect) -> UnitPoint {
        guard let origin, card.width > 0, card.height > 0 else { return .center }
        let x = (origin.x - global.minX - card.minX) / card.width
        let y = (origin.y - global.minY - card.minY) / card.height
        return UnitPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

/// The peek itself: the site, Keep, close; a live page; a hint at the foot.
struct GlanceCard: View {
    let glance: Glance

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Downward travel while the card is being swiped away.
    @State private var pull: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .gesture(dismissSwipe)
            Rectangle().fill(p.line).frame(height: 1)
            ZStack(alignment: .top) {
                GlanceWebHost(glance: glance, engine: store.engine)
                LoadingHairline(runtime: TabRuntime(isLoading: glance.isLoading, progress: glance.progress))
            }
            Rectangle().fill(p.line).frame(height: 1)
            Text("Swipe down to dismiss · scroll to read")
                .font(Typeface.footnote)
                .foregroundStyle(p.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .contentShape(Rectangle())
                .gesture(dismissSwipe)
                .accessibilityHidden(true)
        }
        .background(p.isDark ? p.raised : p.page)
        .clipShape(shape)
        .overlay {
            if p.isDark { shape.strokeBorder(p.line, lineWidth: 1) }
        }
        .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.38), radius: 30, y: 24)
        .offset(y: pull)
        .opacity(1 - min(0.5, Double(pull) / 400))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Glance, \(host)")
        .accessibilityAction(.escape) { dismiss() }
    }

    private var host: String {
        glance.url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "Glance"
    }

    private var keepLabel: String {
        if store.isPair || store.hasRoomForPair {
            return store.glanceSide == 0 ? "Keep on left" : "Keep on right"
        }
        return "Keep as tab"
    }

    private var header: some View {
        HStack(spacing: 8) {
            FaviconView(host: glance.url.host(), title: host, size: 18)
            Text(host)
                .font(Typeface.footnoteStrong)
                .foregroundStyle(p.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(Motion.spring(reduce: reduceMotion)) { store.keepGlance() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.glanceSide == 0 ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                        .font(.system(size: 11, weight: .semibold))
                    Text(keepLabel)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .fixedSize()
                .foregroundStyle(p.onAccent)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(p.accent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .contextMenu {
                Button("Keep as a tab", systemImage: "plus.square.on.square") {
                    withAnimation(Motion.spring(reduce: reduceMotion)) { store.keepGlance(asPair: false) }
                }
                Button("Copy link", systemImage: "link") {
                    UIPasteboard.general.url = store.engine.glanceURL(glance.id) ?? glance.url
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -6)
            .accessibilityLabel("Close Glance")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
    }

    /// Swipe the header or the foot down and the Glance is gone. The page in between scrolls.
    private var dismissSwipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in pull = max(0, value.translation.height) }
            .onEnded { value in
                if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                    dismiss()
                } else {
                    withAnimation(Motion.spring(reduce: reduceMotion)) { pull = 0 }
                }
            }
    }

    private func dismiss() {
        withAnimation(GlanceOverlay.motion(reduceMotion)) { store.dismissGlance() }
    }
}

/// Parents the Glance's live page, which the engine owns until it's kept or let go.
private struct GlanceWebHost: UIViewRepresentable {
    let glance: Glance
    let engine: WebEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let view = engine.glanceView(for: glance)
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}
