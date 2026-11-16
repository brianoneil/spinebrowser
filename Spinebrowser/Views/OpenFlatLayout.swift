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
            let hasFold = Self.hasFold(in: geo)
            // iPad: the cloth runs under the status bar and the window controls; the page sits
            // below the app's own bar. The Duo's system column needs none of this.
            let ownBar = Platform.drawsOwnToolbar
            let corner = geo.containerCornerInsets.topLeading
            // Under the window controls the Space header sits a row below them, not a full corner below.
            let spineTop: CGFloat = ownBar ? max(insets.top + PadToolbar.top, corner.height - 16) : 0

            ZStack(alignment: .topLeading) {
                p.desk

                HStack(spacing: 0) {
                    spine(state: state, width: spineWidth, showsSidebar: showsSidebar)
                        .environment(\.spineTopInset, spineTop)
                    PageArea(
                        spineWidth: spineWidth,
                        joined: !showsSidebar && spineWidth > 0 && !showsPair,
                        showsPair: showsPair,
                        isOpenDisplay: isOpenDisplay,
                        isBent: Self.isBent(in: geo),
                        creaseX: hasFold ? Self.creaseX(in: geo) : nil
                    )
                    .padding(.top, ownBar ? insets.top + PadToolbar.band : 0)
                    .padding(.bottom, ownBar ? 14 : 0)
                }
                .padding(.trailing, insets.trailing)
                // Upright, the system bar runs across the top and owns taps there. Flat it's 0.
                .padding(.top, ownBar ? 0 : insets.top)

                if ownBar {
                    PadToolbar(leading: max(spineWidth + 10, corner.width + 8), showsPair: isOpenDisplay)
                        .padding(.top, insets.top + PadToolbar.top)
                }

                edgeHandle(state: state, resting: resting, spineWidth: spineWidth, canResize: isOpenDisplay && !store.isPair)

                if !showsSidebar {
                    sidebarOverlay
                        .environment(\.spineTopInset, spineTop)
                        .padding(.top, ownBar ? 0 : insets.top)
                }
            }
            .environment(\.hasFold, hasFold)
            .onChange(of: geo.size.width >= Metrics.sidebarMinimumWidth, initial: true) { _, roomy in
                // On iPad a window under 1000pt starts in Spines; widen it and the Sidebar comes back.
                if ownBar { store.fitSpine(roomForSidebar: roomy) }
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

    /// The Duo reports its crease, active or not. Anywhere else there's no fold.
    private static func hasFold(in geo: GeometryProxy) -> Bool {
        !geo.reservedRegions(kind: .division, options: [.includeInactive]).isEmpty
    }

    /// The division region is only active while the device is partly folded.
    private static func isBent(in geo: GeometryProxy) -> Bool {
        !geo.reservedRegions(kind: .division).isEmpty
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
    let isOpenDisplay: Bool
    /// Partly folded. The divider locks to the fold.
    let isBent: Bool
    /// The crease's x in the layout's coordinate space. Nil without a fold: the middle of the page
    /// row stands in for it.
    let creaseX: CGFloat?

    @Environment(BrowserStore.self) private var store
    /// The divider's position while a finger moves it. The store only hears where it comes to rest.
    @State private var liveDivider: CGFloat?

    private static let trailing: CGFloat = 8
    /// Neither window of the Pair gets narrower than this.
    private static let minimumWindow: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            // This view starts where the Spine ends, so the crease moves left by the Spine's width.
            let foldX = creaseX.map { $0 - spineWidth }
            Group {
                if showsPair {
                    pair(width: geo.size.width, foldX: foldX)
                } else {
                    single(width: geo.size.width, foldX: foldX)
                }
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: The Pair

    private func pair(width: CGFloat, foldX crease: CGFloat?) -> some View {
        let gutter = Metrics.pairGutter
        let lead: CGFloat = spineWidth > 0 ? 8 : 10
        let end = width - Self.trailing
        // The detent: the fold on the Duo, the even split everywhere else.
        let foldX = crease ?? (lead + end) / 2
        let range = (lead + Self.minimumWindow + gutter / 2)...max(lead + Self.minimumWindow + gutter / 2, end - Self.minimumWindow - gutter / 2)
        let rested = store.pairSplit.map { lead + CGFloat($0) * (end - lead) } ?? foldX
        // The gutter sits on the crease, so the crease hides in it. Bent, it can't leave.
        let dividerX = isBent ? foldX : min(range.upperBound, max(range.lowerBound, liveDivider ?? rested))
        let leftWidth = dividerX - gutter / 2 - lead
        return HStack(spacing: gutter) {
            PageCard(paneIndex: 0).frame(width: leftWidth)
            PageCard(paneIndex: 1)
        }
        .padding(.leading, lead)
        .padding(.trailing, Self.trailing)
        .overlay {
            if !isBent {
                PairDivider(x: dividerX, foldX: foldX, range: range) { live in
                    liveDivider = live
                } onRest: { position in
                    liveDivider = nil
                    store.setPairSplit(position.map { Double(($0 - lead) / (end - lead)) })
                }
            }
        }
    }

    // MARK: One page

    private func single(width: CGFloat, foldX crease: CGFloat?) -> some View {
        let lead: CGFloat = joined ? 0 : 10
        let foldX = crease ?? (lead + width - Self.trailing) / 2
        return PageCard(paneIndex: store.focusedPaneIndex, joined: joined)
            .overlay(alignment: .leading) {
                // A tab carried over the page can start a Pair on either side of the fold.
                if isOpenDisplay, case let .tab(tabID) = store.drag, store.focusedPane.tabID != tabID {
                    // Each target insets its zone 12pt, so the two meet in a gap centred on the fold.
                    HStack(spacing: 0) {
                        TabDropTarget(label: "Open on the left") { store.drop(tab: $0, onSide: 0) }
                            .frame(width: max(0, foldX - lead))
                        TabDropTarget(label: "Open on the right") { store.drop(tab: $0, onSide: 1) }
                    }
                }
            }
            .padding(.leading, lead)
            .padding(.trailing, Self.trailing)
    }
}
