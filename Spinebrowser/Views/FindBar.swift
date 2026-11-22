#if os(macOS)
import SwiftUI

/// The Mac's Find on page: a small field over the focused page, with next, previous and close.
struct FindBar: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find on page", text: Binding(
                get: { store.findText },
                set: { store.findText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 190)
            .focused($isFocused)
            .onSubmit { store.findNext() }

            Button { store.findPrevious() } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Find previous")

            Button { store.findNext() } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Find next")

            Button { store.isFindOpen = false } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close find")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(p.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(p.line, lineWidth: 1)
        }
        .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.15), radius: 10, y: 6)
        .onAppear { isFocused = true }
        .onExitCommand { store.isFindOpen = false }
        .padding(.top, PadToolbar.band + 8)
        .padding(.trailing, 18)
    }
}
#endif
