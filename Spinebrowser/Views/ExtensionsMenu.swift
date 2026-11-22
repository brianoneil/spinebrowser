import SwiftUI

/// The puzzle piece in the address pill. It lists the extensions that are running, and on a
/// Chrome Web Store page it offers to add the one on show. With neither, it isn't there.
struct ExtensionsMenu: View {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @State private var candidate: ExtensionCandidate?
    @State private var isFetching = false
    @State private var didFail = false

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
                            extensions.press(button.id, in: tab.id)
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
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(offered != nil ? p.accent : p.textSecondary)
                    }
                }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Extensions")
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
