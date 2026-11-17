import RevenueCatUI
import SwiftUI

@main
struct SpinebrowserApp: App {
    @State private var library = Library()
    @State private var pro = ProStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // Each window carries its own id, so it comes back to the tabs it had.
        WindowGroup(for: UUID.self) { $windowID in
            BrowserWindow(windowID: $windowID)
                .environment(library)
                .environment(pro)
                // Day or Night overrides the system; Match system leaves it alone.
                .preferredColorScheme(library.settings.theme.colorScheme)
        }
        .commands { BrowserCommands() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.saveNow() }
        }
    }
}

/// One window: its own place in the shared library.
struct BrowserWindow: View {
    @Binding var windowID: UUID?
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: BrowserStore?

    var body: some View {
        ZStack {
            if let store {
                RootView()
                    .environment(store)
                    .focusedSceneValue(\.browser, store)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { library.windowBecameActive(store.id) }
                    }
            } else {
                Palette(isDark: false, trueBlack: false).desk.ignoresSafeArea()
            }
        }
        .onAppear {
            guard store == nil else { return }
            let id = windowID ?? UUID()
            if windowID == nil { windowID = id }
            store = library.makeWindow(id: id)
        }
    }
}

/// Hosts the layout and its controls: the system column on the Duo, the app's own bar on iPad.
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
        NavigationStack {
            Group {
                if Platform.drawsOwnToolbar {
                    // iPad: no system column, so the layout draws its own bar.
                    layout(palette).toolbar(.hidden, for: .navigationBar)
                } else {
                    layout(palette).toolbar { systemColumn(palette) }
                }
            }
            // Settings take the whole display; the Spine and the page step aside.
            .navigationDestination(isPresented: $store.isSettingsOpen) { SettingsView() }
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
                withAnimation(Motion.spring(reduce: reduceMotion)) { store.sweepArchive() }
                store.unloadIdleTabs()
            }
        }
    }
}

extension RootView {
    private func layout(_ palette: Palette) -> some View {
        GeometryReader { safe in
            OpenFlatLayout(insets: safe.safeAreaInsets)
                .ignoresSafeArea()
        }
        .background(palette.desk.ignoresSafeArea())
    }

    /// The Duo's system column: standard bar items, laid out by iOS. Back/forward, share and Pair
    /// up top; the Spine toggle and New tab at the foot.
    @ToolbarContentBuilder
    private func systemColumn(_ palette: Palette) -> some ToolbarContent {
        let spring = Motion.spring(reduce: reduceMotion)
        let runtime = store.focusedRuntime
        let focusedID = store.focusedPane.tabID
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
