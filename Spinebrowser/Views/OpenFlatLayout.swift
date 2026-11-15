import SwiftUI

/// The open display, flat: cloth on the left (the Spine), paper in the middle (pages),
/// the system column on the right. The crease is ignored while flat.
struct OpenFlatLayout: View {
    /// Safe-area insets read outside this view; the trailing inset is the system column.
    let insets: EdgeInsets

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live Spine width while its edge is being dragged between detents.
    @State private var dragWidth: CGFloat?
    /// How far the overlay Sidebar has been pulled in from the left edge.
    @State private var overlayPull: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let isOpenDisplay = geo.size.width >= Metrics.openMinimumWidth
            // On the cover the Spine only exists as an overlay.
            let state: SpineState = isOpenDisplay ? store.spineState : .hidden
            let resting = Self.width(for: state)
            let spineWidth = dragWidth ?? resting
            let showsSidebar = dragWidth.map { $0 > 168 } ?? (state == .sidebar)
            let showsPair = store.isPair && isOpenDisplay
            let spring = Motion.spring(reduce: reduceMotion)

            ZStack(alignment: .topLeading) {
                p.desk

                HStack(spacing: 0) {
                    spine(state: state, width: spineWidth, showsSidebar: showsSidebar)
                    PageArea(
                        spineWidth: spineWidth,
                        joined: !showsSidebar && spineWidth > 0 && !showsPair,
                        showsPair: showsPair,
                        creaseX: Self.creaseX(in: geo)
                    )
                }
                .padding(.trailing, insets.trailing)
                // Upright, the system bar runs across the top and owns taps there. Flat it's 0.
                .padding(.top, insets.top)

                edgeHandle(state: state, resting: resting, spineWidth: spineWidth, canResize: isOpenDisplay && !store.isPair)

                if !showsSidebar {
                    sidebarOverlay.padding(.top, insets.top)
                }
            }
            .animation(spring, value: store.spineState)
            .animation(spring, value: store.isPair)
            .animation(spring, value: store.isSidebarOverlayOpen)
            .animation(spring, value: store.isCommandBarOpen)
        }
    }

    static func width(for state: SpineState) -> CGFloat {
        switch state {
        case .sidebar: Metrics.sidebarWidth
        case .spines, .rail: Metrics.stripWidth
        case .hidden: 0
        }
    }

    /// Read the crease from the system's reserved regions; never guess it.
    private static func creaseX(in geo: GeometryProxy) -> CGFloat {
        let division = geo.reservedRegions(kind: .division, options: [.includeInactive]).first
        return division?.frame.midX ?? geo.size.width / 2
    }

    // MARK: Spine

    private func spine(state: SpineState, width: CGFloat, showsSidebar: Bool) -> some View {
        ZStack(alignment: .leading) {
            if showsSidebar {
                SidebarView().transition(.opacity)
            } else if width > 0 {
                StripView(mode: state == .rail ? .rail : store.preferredStrip).transition(.opacity)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    /// Drag the Spine's right edge to snap between detents: 0 → 56 → 280.
    /// Hidden, the same edge pulls the Sidebar over the page.
    private func edgeHandle(state: SpineState, resting: CGFloat, spineWidth: CGFloat, canResize: Bool) -> some View {
        let pullsOverlay = state == .hidden || !canResize
        return Color.clear
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: max(0, spineWidth - 6))
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        if pullsOverlay {
                            overlayPull = min(Metrics.sidebarWidth, max(0, value.translation.width))
                        } else {
                            dragWidth = min(Metrics.sidebarWidth, max(0, resting + value.translation.width))
                        }
                    }
                    .onEnded { value in
                        let spring = Motion.spring(reduce: reduceMotion)
                        if pullsOverlay {
                            withAnimation(spring) {
                                store.isSidebarOverlayOpen = value.predictedEndTranslation.width > 110
                                overlayPull = nil
                            }
                            return
                        }
                        let projected = resting + value.predictedEndTranslation.width
                        let detents: [(CGFloat, SpineState)] = [
                            (0, .hidden), (Metrics.stripWidth, store.preferredStrip), (Metrics.sidebarWidth, .sidebar),
                        ]
                        let target = detents.min { abs($0.0 - projected) < abs($1.0 - projected) }?.1 ?? state
                        withAnimation(spring) {
                            store.setSpine(target)
                            dragWidth = nil
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    /// The full Sidebar sliding over the page with a scrim. It slides away after a pick.
    private var sidebarOverlay: some View {
        let extent = overlayPull ?? (store.isSidebarOverlayOpen ? Metrics.sidebarWidth : 0)
        let progress = extent / Metrics.sidebarWidth
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 0,
            bottomTrailingRadius: Metrics.cardRadius, topTrailingRadius: Metrics.cardRadius, style: .continuous
        )
        return ZStack(alignment: .leading) {
            p.scrim
                .opacity(progress)
                .contentShape(Rectangle())
                .onTapGesture { store.isSidebarOverlayOpen = false }
                .allowsHitTesting(progress > 0.5)
                .accessibilityHidden(progress < 0.5)

            SidebarView()
                .clipShape(shape)
                .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.16 * progress), radius: 20, x: 8)
                .offset(x: extent - Metrics.sidebarWidth - (progress == 0 ? 40 : 0))
                .gesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            guard value.translation.width < 0 else { return }
                            overlayPull = max(0, Metrics.sidebarWidth + value.translation.width)
                        }
                        .onEnded { value in
                            withAnimation(Motion.spring(reduce: reduceMotion)) {
                                if value.predictedEndTranslation.width < -90 { store.isSidebarOverlayOpen = false }
                                overlayPull = nil
                            }
                        }
                )
                .accessibilityHidden(progress == 0)
        }
    }
}

/// Paper between the Spine and the system column: one page, or the Pair split on the crease.
private struct PageArea: View {
    let spineWidth: CGFloat
    let joined: Bool
    let showsPair: Bool
    /// The crease's x in the layout's coordinate space.
    let creaseX: CGFloat

    @Environment(BrowserStore.self) private var store

    var body: some View {
        Group {
            if showsPair {
                // The 12pt gutter sits on the crease, so the crease hides in it.
                let lead: CGFloat = spineWidth > 0 ? 8 : 10
                let leftWidth = max(160, creaseX - Metrics.pairGutter / 2 - spineWidth - lead)
                HStack(spacing: Metrics.pairGutter) {
                    PageCard(paneIndex: 0).frame(width: leftWidth)
                    PageCard(paneIndex: 1)
                }
                .padding(.leading, lead)
            } else {
                PageCard(paneIndex: store.focusedPaneIndex, joined: joined)
                    .padding(.leading, joined ? 0 : 10)
            }
        }
        .padding(.vertical, 10)
        .padding(.trailing, 8)
    }
}
