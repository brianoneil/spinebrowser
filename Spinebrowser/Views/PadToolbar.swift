import SwiftUI

/// Where the controls live. The Duo has a system column, which iOS fills from standard bar items.
/// An iPad has none, so the app draws one row of glass buttons on the desk, above the page.
enum Platform {
    static let drawsOwnToolbar = UIDevice.current.userInterfaceIdiom == .pad
    /// How copy names the device: "phone" on the Duo, "iPad" on an iPad.
    static let deviceName = drawsOwnToolbar ? "iPad" : "phone"
}

extension EnvironmentValues {
    /// True on a device with a fold. Everywhere else the middle of the page stands in for it.
    @Entry var hasFold = false
    /// Extra room at the top of the Spine, for the status bar and window controls it runs under.
    @Entry var spineTopInset: CGFloat = 0
}

/// The iPad's bar: the Spine toggle and back/forward lead; Share, Pair and New tab trail.
/// It acts on the focused window, like the Duo's system column.
struct PadToolbar: View {
    /// Room on the leading side taken by the Spine or the window controls.
    let leading: CGFloat
    /// The open layout. Narrow windows leave out the Pair, and the Spine button pulls in the overlay.
    let showsPair: Bool

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 44
    /// From the top of the window's safe area to the bar.
    static let top: CGFloat = 6
    /// The band the bar takes above the page: its offset, its height and a gap.
    static let band: CGFloat = 46

    var body: some View {
        let spring = Motion.spring(reduce: reduceMotion)
        let runtime = store.focusedRuntime
        let focusedID = store.focusedPane.tabID
        HStack(spacing: 10) {
            GlassCircle(label: "Spine", symbol: "sidebar.left") {
                withAnimation(spring) {
                    // A narrow window only has the overlay; the open layout cycles the Spine's widths.
                    if showsPair { store.cycleSpine() } else { store.isSidebarOverlayOpen.toggle() }
                }
            }
            HStack(spacing: 0) {
                BarIcon(label: "Back", symbol: "chevron.left", isEnabled: runtime.canGoBack) {
                    if let focusedID { store.engine.goBack(focusedID) }
                }
                BarIcon(label: "Forward", symbol: "chevron.right", isEnabled: runtime.canGoForward) {
                    if let focusedID { store.engine.goForward(focusedID) }
                }
            }
            .padding(.horizontal, 2)
            .frame(height: Self.height)
            .glassEffect(.regular.interactive(), in: Capsule())

            Spacer(minLength: 0)

            if let url = store.focusedTab.flatMap({ store.currentURL(for: $0) }) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(p.text)
                        .frame(width: Self.height, height: Self.height)
                }
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Share")
            } else {
                // Nothing to share yet; the button stays put so the bar doesn't shift.
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(p.textTertiary)
                    .frame(width: Self.height, height: Self.height)
                    .glassEffect(.regular, in: Circle())
                    .accessibilityLabel("Share")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityRemoveTraits(.isImage)
            }
            if showsPair {
                GlassCircle(label: store.isPair ? "Close the Pair" : "Open a Pair", symbol: "rectangle.split.2x1") {
                    withAnimation(spring) { store.togglePair() }
                }
            }
            // The one verdigris button.
            Button {
                withAnimation(spring) { _ = store.newTab() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(p.onAccent)
                    .frame(width: Self.height, height: Self.height)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(p.accent).interactive(), in: Circle())
            .accessibilityLabel("New tab")
        }
        .padding(.leading, leading)
        .padding(.trailing, 10)
        .frame(height: Self.height)
    }
}

private struct GlassCircle: View {
    let label: String
    let symbol: String
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(p.text)
                .frame(width: PadToolbar.height, height: PadToolbar.height)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}

private struct BarIcon: View {
    let label: String
    let symbol: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isEnabled ? p.text : p.textTertiary)
                .frame(width: 44, height: PadToolbar.height)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
