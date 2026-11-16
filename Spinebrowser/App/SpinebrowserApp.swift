import RevenueCatUI
import SwiftUI

@main
struct SpinebrowserApp: App {
    @State private var store = BrowserStore()
    @State private var pro = ProStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(pro)
                // Day or Night overrides the system; Match system leaves it alone.
                .preferredColorScheme(store.settings.theme.colorScheme)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.saveNow() }
        }
    }
}

/// Hosts the layout and hands the system column its controls. They are standard bar items,
/// so iOS lays them out: back/forward, share, Pair up top; the Spine toggle and New tab at the foot.
struct RootView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(ProStore.self) private var pro
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var store = store
        @Bindable var pro = pro
        // True black is a Pro feature: the setting stays saved, and applies only while Pro is active.
        let palette = Palette(
            isDark: colorScheme == .dark,
            trueBlack: store.settings.trueBlackAtNight && pro.isPro
        )
        let spring = Motion.spring(reduce: reduceMotion)
        let runtime = store.focusedRuntime
        let focusedID = store.focusedPane.tabID

        NavigationStack {
            GeometryReader { safe in
                OpenFlatLayout(insets: safe.safeAreaInsets)
                    .ignoresSafeArea()
            }
            .background(palette.desk.ignoresSafeArea())
            // Settings take the whole display; the Spine and the page step aside.
            .navigationDestination(isPresented: $store.isSettingsOpen) { SettingsView() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left") {
                        if let focusedID { store.engine.goBack(focusedID) }
                    }
                    .disabled(!runtime.canGoBack)
                    .tint(palette.text)
                    Button("Forward", systemImage: "chevron.right") {
                        if let focusedID { store.engine.goForward(focusedID) }
                    }
                    .disabled(!runtime.canGoForward)
                    .tint(palette.text)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if let url = store.focusedTab.flatMap({ store.currentURL(for: $0) }) {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                            .tint(palette.text)
                    } else {
                        Button("Share", systemImage: "square.and.arrow.up") {}.disabled(true)
                    }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(store.isPair ? "Close the Pair" : "Open a Pair", systemImage: "rectangle.split.2x1") {
                        withAnimation(spring) { store.togglePair() }
                    }
                    .tint(palette.text)
                }

                ToolbarItem(placement: .bottomBar) {
                    Button("Spine", systemImage: "sidebar.left") {
                        withAnimation(spring) { store.cycleSpine() }
                    }
                    .tint(palette.text)
                }
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    // The one verdigris button.
                    Button("New tab", systemImage: "plus") {
                        withAnimation(spring) { _ = store.newTab() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                }
            }
        }
        .environment(\.palette, palette)
        .tint(palette.accent)
        .sheet(isPresented: $store.isArchiveOpen) {
            ArchiveView()
                .environment(store)
                .environment(\.palette, palette)
        }
        // The paywall's layout and products come from the RevenueCat dashboard.
        .sheet(isPresented: $pro.isPaywallOpen) {
            PaywallView(displayCloseButton: true)
                .onPurchaseCompleted { pro.received($0) }
                .onRestoreCompleted { pro.received($0) }
        }
        .presentCustomerCenter(isPresented: $pro.isCustomerCenterOpen)
        .task {
            // Housekeeping: shelve expired Today tabs, give idle tabs' memory back.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                withAnimation(spring) { store.sweepArchive() }
                store.unloadIdleTabs()
            }
        }
    }
}
