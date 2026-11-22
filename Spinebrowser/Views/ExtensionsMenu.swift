import SwiftUI

/// The puzzle piece in the address pill. It lists the extensions that are running, and on a
/// Chrome Web Store page it offers to add the one on show. With neither, it isn't there.
struct ExtensionsMenu: View {
    /// Whether a tab has anything to show here: an extension running, or one on offer.
    @MainActor
    static func hasSomething(for tab: BrowserTab?, in store: BrowserStore) -> Bool {
        guard let tab else { return false }
        let extensions = store.library.extensions
        if !extensions.buttons(for: tab.id).isEmpty { return true }
        return ChromeWebStore.extensionID(in: store.currentURL(for: tab)).map { !extensions.isInstalled($0) } ?? false
    }

    let tab: BrowserTab
    /// In the iPad's and the Mac's bar it's a glass circle like its neighbours, and it stays put.
    /// In the Duo's pill it's a small mark beside Reader.
    var inBar = false
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @State private var candidate: ExtensionCandidate?
    @State private var isFetching = false
    @State private var didFail = false
    @State private var frame = CGRect.zero

    var body: some View {
        let extensions = store.library.extensions
        let buttons = extensions.buttons(for: tab.id)
        let offered = ChromeWebStore.extensionID(in: store.currentURL(for: tab))
            .flatMap { extensions.isInstalled($0) ? nil : $0 }
        if !buttons.isEmpty || offered != nil {
            Menu {
                if let offered {
                    Button("Add this extension", systemImage: "plus") { fetch(offered) }
                        .disabled(isFetching)
                }
                Section {
                    ForEach(buttons) { button in
                        Button {
                            extensions.press(button.id, in: tab.id, from: frame)
                        } label: {
                            Label {
                                Text(button.badge.isEmpty ? button.label : "\(button.label) · \(button.badge)")
                            } icon: {
                                if let icon = button.icon {
                                    Image(platformImage: icon)
                                } else {
                                    Image(systemName: "puzzlepiece.extension")
                                }
                            }
                        }
                        .disabled(!button.isEnabled)
                    }
                }
                Button("Manage extensions", systemImage: "gearshape") { store.isSettingsOpen = true }
            } label: {
                Group {
                    if isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: offered != nil ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                            .font(.system(size: inBar ? PadToolbar.iconSize : 12, weight: inBar ? .medium : .semibold))
                            .foregroundStyle(offered != nil ? p.accent : inBar ? p.text : p.textSecondary)
                    }
                }
                .frame(width: inBar ? PadToolbar.height : 30, height: inBar ? PadToolbar.height : 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .modifier(BarGlass(isOn: inBar))
            // Where the button sits in its window, so a popup can open from it.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .padding(.trailing, inBar ? 0 : 4)
            .pointerHelp("Extensions")
            .accessibilityLabel("Extensions")
            // The store page's own button was pressed in this tab.
            .onChange(of: extensions.wanted) { _, wanted in
                guard let wanted, wanted.tabID == tab.id else { return }
                extensions.clearWanted()
                if !isFetching, candidate == nil { fetch(wanted.id) }
            }
            .alert("Add \(candidate?.name ?? "extension")?", isPresented: isAsking, presenting: candidate) { found in
                Button("Add") { Task { await extensions.install(found) } }
                Button("Cancel", role: .cancel) {}
            } message: { found in
                Text("\(found.access) It comes from the Chrome Web Store and runs on WebKit, so a few features may not work.")
            }
            .alert("Couldn't add this extension", isPresented: $didFail) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The Chrome Web Store didn't hand it over, or it isn't built for this browser. Try again.")
            }
        }
    }

    private var isAsking: Binding<Bool> {
        Binding { candidate != nil } set: { if !$0 { candidate = nil } }
    }

    private func fetch(_ id: String) {
        isFetching = true
        Task {
            do {
                candidate = try await store.library.extensions.fetch(id)
            } catch {
                didFail = true
            }
            isFetching = false
        }
    }
}

/// The glass circle the bar's buttons sit on.
private struct BarGlass: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
        }
    }
}
