#if os(macOS)
import AppKit
#else
import UIKit
#endif
import WebKit

/// A tab, as extensions see it. WebKit keeps hold of these, so each tab has one for life.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    let id: UUID
    private weak var store: ExtensionStore?
    private var library: Library? { store?.library }

    init(id: UUID, store: ExtensionStore) {
        self.id = id
        self.store = store
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let window = library?.window(showing: id) ?? library?.activeWindow else { return nil }
        return store?.window(for: window.id)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        library?.tabs.firstIndex { $0.id == id } ?? 0
    }

    /// A tab that hasn't loaded yet has no page to hand over, and extensions shouldn't wake it.
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        library?.engine.loadedView(id)
    }

    func title(for context: WKWebExtensionContext) -> String? {
        library?.tab(id: id)?.displayTitle
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        library?.tab(id: id).flatMap { library?.currentURL(for: $0) }
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        library?.tab(id: id).map { $0.tier != .today } ?? false
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        library?.window(showing: id)?.focusedTab?.id == id
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(library?.runtime[id]?.isLoading ?? false)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        library?.engine.loadedView(id)?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        library?.engine.loadedView(id).map { Double($0.pageZoom) } ?? 1
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        library?.engine.loadedView(id)?.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        library?.engine.load(url, in: id)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin, let view = library?.engine.loadedView(id) {
            view.reloadFromOrigin()
        } else {
            library?.engine.reload(id)
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        library?.engine.goBack(id)
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        library?.engine.goForward(id)
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        (library?.window(showing: id) ?? library?.activeWindow)?.select(id)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let window = library?.window(showing: id) {
            window.close(id)
        } else {
            library?.close(id)
        }
        completionHandler(nil)
    }
}

/// A browser window, as extensions see it. Tabs belong to the whole library, so the window in
/// front answers for every tab no other window is showing.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    let id: UUID
    private weak var store: ExtensionStore?
    private var library: Library? { store?.library }

    init(id: UUID, store: ExtensionStore) {
        self.id = id
        self.store = store
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let library, let store, let window = library.window(id: id) else { return [] }
        let mine = Set(window.shownTabIDs)
        guard library.activeWindow?.id == id else { return window.shownTabIDs.map(store.tab(for:)) }
        let elsewhere = library.shownTabIDs.subtracting(mine)
        return library.tabs.map(\.id).filter { !elsewhere.contains($0) }.map(store.tab(for:))
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        library?.window(id: id)?.focusedTab.flatMap { store?.tab(for: $0.id) }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}

/// Shows an extension's popup: a popover where there's room, a sheet on the cover display.
@MainActor
enum ExtensionPopup {
    static func present(_ action: WKWebExtension.Action) {
        #if os(macOS)
        guard let popover = action.popupPopover, let view = NSApp.keyWindow?.contentView else { return }
        let anchor = NSRect(x: view.bounds.midX - 1, y: view.bounds.maxY - 44, width: 2, height: 2)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        #else
        guard let popup = action.popupViewController else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        if let popover = popup.popoverPresentationController {
            // Under the address pill, where the button that opened it sits.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX - 1, y: top.view.safeAreaInsets.top + 52, width: 2, height: 2)
            popover.permittedArrowDirections = .up
        }
        top.present(popup, animated: true)
        #endif
    }
}
