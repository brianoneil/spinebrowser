import SwiftUI

extension FocusedValues {
    /// The window the keyboard is talking to.
    @Entry var browser: BrowserStore?
}

/// The menu bar and its shortcuts. On iPad they show in the menu bar and when you hold ⌘;
/// the same commands carry over to the Mac.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var store

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { store?.newTab() }
                .keyboardShortcut("t")
                .disabled(store == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button(spineLabel) { store?.cycleSpine() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(store == nil)
            Divider()
            Button("Reload Page") { act { $0.engine.reload($1) } }
                .keyboardShortcut("r")
                .disabled(focusedTabID == nil)
            Button("Zoom In") { act { $0.engine.zoom($1, by: 0.1) } }
                .keyboardShortcut("+")
                .disabled(focusedTabID == nil)
            Button("Zoom Out") { act { $0.engine.zoom($1, by: -0.1) } }
                .keyboardShortcut("-")
                .disabled(focusedTabID == nil)
            Button("Actual Size") { act { $0.engine.zoom($1, by: nil) } }
                .keyboardShortcut("0")
                .disabled(focusedTabID == nil)
            Divider()
            Button(store?.focusedReader != nil ? "Hide Reader" : "Show Reader") { store?.toggleReader() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(store?.canRead(store?.focusedPane.tabID) ?? false))
        }

        CommandMenu("History") {
            Button("Back") { store?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(store?.canGoBack ?? false))
            Button("Forward") { act { $0.engine.goForward($1) } }
                .keyboardShortcut("]")
                .disabled(!(store?.focusedRuntime.canGoForward ?? false))
            Divider()
            Button("Show the Archive") { store?.isArchiveOpen = true }
                .keyboardShortcut("y")
                .disabled(store == nil)
        }

        CommandMenu("Tabs") {
            Button("Search or Command") { store?.isCommandBarOpen = true }
                .keyboardShortcut("l")
                .disabled(store == nil)
            Button("Reopen Closed Tab") { store?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(store?.library.recentlyClosed.isEmpty ?? true)
            Button("Close Tab") { store?.closeFocusedTab() }
                .keyboardShortcut("w")
                .disabled(focusedTabID == nil)
            Divider()
            Button("Next Tab") { store?.stepTab(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(store == nil)
            Button("Previous Tab") { store?.stepTab(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(store == nil)
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") { store?.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                    .disabled(store == nil)
            }
            Divider()
            Button(pinLabel) { store?.togglePinFocused() }
                .keyboardShortcut("d")
                .disabled(store?.focusedTab == nil || store?.focusedTab?.tier == .essential)
            Button(store?.isPair == true ? "Close the Pair" : "Open a Pair") { store?.togglePair() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(store == nil)
            Button("Focus the Other Window") { store?.focusOtherPane() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(store?.isPair != true)
            Button("Swap Sides") { store?.swapPair() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(store?.isPair != true)
        }

        CommandMenu("Spaces") {
            if let store {
                ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, space in
                    Button(space.name) { store.switchSpace(to: space.id) }
                        .keyboardShortcut(index < 9 ? KeyEquivalent(Character("\(index + 1)")) : "0", modifiers: .control)
                        .disabled(index >= 9 || store.focusedPane.spaceID == space.id)
                }
            }
        }
    }

    private var focusedTabID: UUID? { store?.focusedPane.tabID }

    /// Runs a page action on the focused window's tab.
    private func act(_ action: (BrowserStore, UUID) -> Void) {
        guard let store, let tabID = focusedTabID else { return }
        action(store, tabID)
    }

    private var spineLabel: String {
        store?.spineState == .hidden ? "Show the Spine" : "Change the Spine"
    }

    private var pinLabel: String {
        store?.focusedTab?.tier == .pinned ? "Unpin Tab" : "Pin Tab"
    }
}
