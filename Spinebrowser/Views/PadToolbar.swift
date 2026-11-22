import SwiftUI

extension EnvironmentValues {
    /// True on a device with a fold. Everywhere else the middle of the page stands in for it.
    @Entry var hasFold = false
    /// Extra room at the top of the Spine, for the status bar and window controls it runs under.
    @Entry var spineTopInset: CGFloat = 0
}

/// The iPad's bar: the Spine toggle and back/forward lead; Reader, Share, Pair and New tab trail.
/// It acts on the focused window, like the Duo's system column.
struct PadToolbar: View {
    /// Room on the leading side taken by the Spine or the window controls.
    let leading: CGFloat
    /// The open layout. Narrow windows leave out the Pair, and the Spine button pulls in the overlay.
    let showsPair: Bool

    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Touch-sized on iPad; the Mac's pointer takes a smaller button.
    static let height: CGFloat = Platform.isMac ? 36 : 44
    /// From the top of the window's safe area to the bar.
    static let top: CGFloat = Platform.isMac ? 10 : 6
    /// The band the bar takes above the page: its offset, its height and a gap.
    static let band: CGFloat = Platform.isMac ? 56 : 46
    static let iconSize: CGFloat = Platform.isMac ? 14 : 17
    static let gap: CGFloat = Platform.isMac ? 8 : 10

    var body: some View {
        let spring = Motion.spring(reduce: reduceMotion)
        let runtime = store.focusedRuntime
        let focusedID = store.focusedPane.tabID
        let canRead = store.canRead(focusedID)
        let isReading = store.readerSession(for: focusedID) != nil
        // On the Mac both button groups take the same width, so the address between them sits on
        // the page's centre. The wider group sets it: four buttons, or three in a narrow window.
        let hasExtensions = ExtensionsMenu.hasSomething(for: store.focusedTab, in: store)
        let buttons: CGFloat = (showsPair ? 4 : 3) + (hasExtensions ? 1 : 0)
        let side: CGFloat? = Platform.isMac
            ? Self.height * buttons + Self.gap * (buttons - 1)
            : nil
        HStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
            GlassCircle(label: "Spine", symbol: "sidebar.left", help: "Change the Spine’s width (⌃⌘S)") {
                withAnimation(spring) {
                    // A narrow window only has the overlay; the open layout cycles the Spine's widths.
                    if showsPair { store.cycleSpine() } else { store.isSidebarOverlayOpen.toggle() }
                }
            }
            HStack(spacing: 0) {
                BarIcon(label: "Back", symbol: "chevron.left", help: "Back (⌘[)", isEnabled: store.canGoBack) {
                    store.goBack()
                }
                BarIcon(label: "Forward", symbol: "chevron.right", help: "Forward (⌘])", isEnabled: runtime.canGoForward) {
                    if let focusedID { store.engine.goForward(focusedID) }
                }
            }
            .padding(.horizontal, 2)
            .frame(height: Self.height)
            .glassEffect(.regular.interactive(), in: Capsule())
            }
            .frame(width: side, alignment: .leading)

            Spacer(minLength: 0)

            // The Mac keeps the address in the bar. In the Pair each window's own bar names it.
            if Platform.isMac, !store.isPair, let tab = store.focusedTab, tab.url != nil {
                URLPill(tab: tab)
                Spacer(minLength: 0)
            }

            HStack(spacing: Self.gap) {
            // Reader is offered only where Readability finds an article, as in the pill.
            if canRead {
                GlassCircle(label: isReading ? "Hide Reader" : "Show Reader",
                            symbol: isReading ? "doc.plaintext.fill" : "doc.plaintext",
                            help: isReading ? "Hide Reader (⇧⌘R)" : "Show Reader (⇧⌘R)",
                            isOn: isReading) {
                    withAnimation(spring) { store.toggleReader(focusedID) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            if hasExtensions, let tab = store.focusedTab {
                ExtensionsMenu(tab: tab, inBar: true)
            }
            if let url = store.focusedTab.flatMap({ store.currentURL(for: $0) }) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: PadToolbar.iconSize, weight: .medium))
                        .foregroundStyle(p.text)
                        .frame(width: Self.height, height: Self.height)
                }
                // Without this the Mac draws its own bezel around the link and the button grows.
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .pointerHelp("Share this page")
                .accessibilityLabel("Share")
            } else {
                // Nothing to share yet; the button stays put so the bar doesn't shift.
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: PadToolbar.iconSize, weight: .medium))
                    .foregroundStyle(p.textTertiary)
                    .frame(width: Self.height, height: Self.height)
                    .glassEffect(.regular, in: Circle())
                    .accessibilityLabel("Share")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityRemoveTraits(.isImage)
            }
            if showsPair {
                GlassCircle(label: store.isPair ? "Close the Pair" : "Open a Pair", symbol: "rectangle.split.2x1",
                            help: store.isPair ? "Close the Pair (⌥⌘P)" : "Open a Pair (⌥⌘P)") {
                    withAnimation(spring) { store.togglePair() }
                }
            }
            // The one verdigris button.
            Button {
                withAnimation(spring) { _ = store.newTab() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: Self.iconSize + 1, weight: .semibold))
                    .foregroundStyle(p.onAccent)
                    .frame(width: Self.height, height: Self.height)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(p.accent).interactive(), in: Circle())
            .pointerHelp("New tab (⌘T)")
            .accessibilityLabel("New tab")
            }
            .frame(width: side, alignment: .trailing)
        }
        .padding(.leading, leading)
        .padding(.trailing, Platform.isMac ? 16 : 10)
        .frame(height: Self.height)
        .animation(spring, value: canRead)
    }
}

private struct GlassCircle: View {
    let label: String
    let symbol: String
    var help = ""
    /// A mode that's on (Reader while reading) takes the accent, as the pill does.
    var isOn = false
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PadToolbar.iconSize, weight: .medium))
                .foregroundStyle(isOn ? p.accent : p.text)
                .frame(width: PadToolbar.height, height: PadToolbar.height)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .pointerHelp(help)
        .accessibilityLabel(label)
    }
}

private struct BarIcon: View {
    let label: String
    let symbol: String
    var help = ""
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PadToolbar.iconSize, weight: .medium))
                .foregroundStyle(isEnabled ? p.text : p.textTertiary)
                .frame(width: PadToolbar.height, height: PadToolbar.height)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerHelp(help)
        .accessibilityLabel(label)
    }
}
