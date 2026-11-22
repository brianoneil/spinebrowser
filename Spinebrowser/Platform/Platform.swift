import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What each platform brings to the same browser.
enum Platform {
    #if os(macOS)
    static let isMac = true
    /// No system column on the Mac either: the window draws its own bar.
    static let drawsOwnToolbar = true
    static let deviceName = "Mac"
    #else
    static let isMac = false
    static let drawsOwnToolbar = UIDevice.current.userInterfaceIdiom == .pad
    static let deviceName = drawsOwnToolbar ? "iPad" : "phone"
    #endif

    /// The app came back to the front. The command bar rechecks the clipboard.
    static var appDidBecomeActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    /// The clipboard changed. iOS posts this; macOS has no equivalent and polling on activation
    /// is enough there.
    static var pasteboardChanged: Notification.Name {
        #if os(iOS)
        UIPasteboard.changedNotification
        #else
        Notification.Name("SpinePasteboardChanged")
        #endif
    }

    /// The software keyboard moved. Only iOS has one.
    static var keyboardWillChangeFrame: Notification.Name {
        #if os(iOS)
        UIResponder.keyboardWillChangeFrameNotification
        #else
        Notification.Name("SpineKeyboardWillChangeFrame")
        #endif
    }

    static var keyboardWillHide: Notification.Name {
        #if os(iOS)
        UIResponder.keyboardWillHideNotification
        #else
        Notification.Name("SpineKeyboardWillHide")
        #endif
    }

    /// Where the software keyboard's top edge is, if the platform has one.
    static func keyboardTop(from note: Notification) -> CGFloat? {
        #if os(iOS)
        (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.minY
        #else
        nil
        #endif
    }

    /// A link the web view can't show goes to whatever app owns its scheme.
    static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #endif
    }
}

#if os(macOS)
typealias PlatformImage = NSImage

extension NSImage {
    /// The PNG the favicon cache writes to disk.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// The system clipboard, without the iOS paste alert on every read.
enum Clipboard {
    static var url: URL? {
        #if os(macOS)
        let board = NSPasteboard.general
        let objects = board.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL]
        if let link = objects?.compactMap({ $0 as URL }).first(where: {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "")
        }) { return link }
        if let text = board.string(forType: .string),
           let link = NavigationInput.firstLink(in: text) { return link }
        return nil
        #else
        UIPasteboard.general.url
        #endif
    }

    /// Whether the clipboard holds a link, without reading its contents where the platform allows it.
    static func hasLink() async -> Bool {
        #if os(macOS)
        url != nil
        #else
        let board = UIPasteboard.general
        if board.hasURLs { return true }
        if board.hasStrings {
            let found = try? await board.detectedPatterns(for: [\.probableWebURL])
            return found?.contains(\.probableWebURL) ?? false
        }
        return false
        #endif
    }

    /// The first web link in the clipboard: a bare address or one inside a sentence.
    static func firstLink() -> URL? {
        #if os(macOS)
        url
        #else
        let board = UIPasteboard.general
        if let text = board.url?.absoluteString,
           let link = NavigationInput.firstLink(in: text) { return link }
        if let text = board.string,
           let link = NavigationInput.firstLink(in: text) { return link }
        return nil
        #endif
    }

    static func copy(_ url: URL) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        #else
        UIPasteboard.general.url = url
        #endif
    }
}

/// The pointer's version of a tab's lift on touch. iOS gets the system highlight; the Mac gets a
/// small scale and brightening of its own.
private struct PointerLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .brightness(hovering ? 0.025 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
        #else
        content.hoverEffect(.highlight)
        #endif
    }
}

#if os(macOS)
/// Gives the hidden-title-bar window a floor and keeps its cloth draggable.
struct MacWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.minSize = NSSize(width: 480, height: 600)
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

extension View {
    func pointerLift() -> some View { modifier(PointerLift()) }

    /// iOS-only text-field tuning, compiled out on the Mac.
    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    func doneSubmitLabel() -> some View {
        #if os(iOS)
        submitLabel(.done)
        #else
        self
        #endif
    }

    func hideNavigationBackButton() -> some View {
        #if os(iOS)
        navigationBarBackButtonHidden()
        #else
        self
        #endif
    }

    func compactPopover() -> some View {
        #if os(iOS)
        presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }
}
