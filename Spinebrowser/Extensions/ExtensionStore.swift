import Foundation
import Observation
import WebKit
import os

/// An extension the browser keeps: its archive on disk and whether it runs.
struct InstalledExtension: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var version: String
    /// What it may touch, in a sentence.
    var access: String
    var isEnabled = true
}

/// An extension fetched and read, waiting for a yes.
struct ExtensionCandidate: Identifiable {
    let id: String
    let name: String
    let version: String
    let access: String
    fileprivate let archive: URL
}

/// One extension's button, as the address pill's menu shows it.
struct ExtensionButton: Identifiable {
    let id: String
    let label: String
    let badge: String
    let icon: PlatformImage?
    let isEnabled: Bool
}

/// Chrome extensions, run by WebKit's own web-extension engine.
///
/// A Chrome extension and a Safari web extension are the same thing on disk: a manifest, scripts
/// and pages. The store fetches the CRX from the Chrome Web Store, takes off its signature header,
/// and hands the ZIP inside to a `WKWebExtensionController` every web view shares. WebKit runs the
/// background worker, injects content scripts and answers `chrome.*`. This class tells it about
/// the browser's windows and tabs and shows what it asks to be shown.
@MainActor
@Observable
final class ExtensionStore: NSObject {
    enum Failure: Error { case unavailable }

    private(set) var installed: [InstalledExtension] = []
    /// Counts up when an extension changes its button, so the menu reads it again.
    private(set) var buttonGeneration = 0

    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored private(set) weak var library: Library?
    @ObservationIgnored private var contexts: [String: WKWebExtensionContext] = [:]
    @ObservationIgnored private var tabs: [UUID: ExtensionTab] = [:]
    @ObservationIgnored private var windows: [UUID: ExtensionWindow] = [:]
    @ObservationIgnored private var activeTabs: [UUID: UUID] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "Spinebrowser", category: "Extensions")

    /// One controller identity for good, so extension storage survives a relaunch.
    private static let controllerID = UUID(uuidString: "5B1E0E00-C4A0-4E87-9E57-5B1E0E7E4510")!

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    private static let index = folder.appendingPathComponent("installed.json")

    private static func archive(_ id: String) -> URL { folder.appendingPathComponent("\(id).zip") }

    init(library: Library) {
        self.library = library
        controller = WKWebExtensionController(configuration: .init(identifier: Self.controllerID))
        super.init()
        controller.delegate = self
        if let data = try? Data(contentsOf: Self.index),
           let saved = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            installed = saved
        }
        Task {
            for entry in installed { await load(entry) }
            #if DEBUG
            await installFromEnvironment()
            #endif
        }
    }

    // MARK: Installing

    /// Fetches an extension from the Chrome Web Store and reads it, without installing it.
    func fetch(_ id: String) async throws -> ExtensionCandidate {
        let (data, response) = try await URLSession.shared.data(from: ChromeWebStore.packageURL(for: id))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unavailable }
        return try await stage(data, id: id)
    }

    private func stage(_ package: Data, id: String) async throws -> ExtensionCandidate {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).zip")
        try ChromePackage.zip(from: package).write(to: archive)
        let found = try await WKWebExtension(resourceBaseURL: archive)
        return ExtensionCandidate(
            id: id,
            name: found.displayName ?? id,
            version: found.displayVersion ?? found.version ?? "",
            access: Self.access(of: found),
            archive: archive
        )
    }

    func install(_ candidate: ExtensionCandidate) async {
        unload(candidate.id)
        let home = Self.archive(candidate.id)
        try? FileManager.default.removeItem(at: home)
        do {
            try FileManager.default.moveItem(at: candidate.archive, to: home)
        } catch {
            log.error("Couldn't keep \(candidate.id): \(error.localizedDescription)")
            return
        }
        let entry = InstalledExtension(id: candidate.id, name: candidate.name, version: candidate.version, access: candidate.access)
        installed.removeAll { $0.id == entry.id }
        installed.append(entry)
        save()
        await load(entry)
    }

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let i = installed.firstIndex(where: { $0.id == id }), installed[i].isEnabled != enabled else { return }
        installed[i].isEnabled = enabled
        save()
        if enabled {
            let entry = installed[i]
            Task { await load(entry) }
        } else {
            unload(id)
        }
    }

    func remove(_ id: String) {
        unload(id)
        installed.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.archive(id))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: Self.index, options: .atomic)
    }

    /// What the extension may read and change, from the sites its manifest names.
    private static func access(of found: WKWebExtension) -> String {
        let patterns = found.allRequestedMatchPatterns
        if patterns.isEmpty { return "Asks for no access to pages." }
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            return "Can read and change pages on every site."
        }
        let hosts = Set(patterns.compactMap(\.host)).sorted()
        if hosts.count == 1 { return "Can read and change pages on \(hosts[0])." }
        return "Can read and change pages on \(hosts.count) sites."
    }

    // MARK: Running

    private func load(_ entry: InstalledExtension) async {
        guard entry.isEnabled, contexts[entry.id] == nil else { return }
        do {
            let found = try await WKWebExtension(resourceBaseURL: Self.archive(entry.id))
            guard contexts[entry.id] == nil, installed.contains(where: { $0.id == entry.id && $0.isEnabled }) else { return }
            let context = WKWebExtensionContext(for: found)
            // The Chrome id names the extension's storage, so it survives updates and relaunches.
            context.uniqueIdentifier = entry.id
            #if DEBUG
            context.isInspectable = true
            #endif
            // Saying yes at install grants what the manifest asked for.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in found.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            contexts[entry.id] = context
            for problem in found.errors + context.errors {
                log.notice("\(entry.name): \(problem.localizedDescription)")
            }
            if found.hasBackgroundContent {
                context.loadBackgroundContent { [log] error in
                    if let error { log.error("\(entry.name) background: \(error.localizedDescription)") }
                }
            }
            log.notice("Loaded \(entry.name) \(entry.version) at \(context.baseURL.absoluteString)")
            buttonGeneration += 1
        } catch {
            log.error("Couldn't load \(entry.name): \(error.localizedDescription)")
        }
    }

    private func unload(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
        buttonGeneration += 1
    }

    /// The configuration an extension's own page needs: its options page, or a page it opens in a tab.
    func configuration(for url: URL?) -> WKWebViewConfiguration? {
        guard let url, !WebEngine.isPage(url) else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: Buttons

    /// The buttons of the extensions that are running, as they stand for this tab.
    func buttons(for tabID: UUID?) -> [ExtensionButton] {
        _ = buttonGeneration
        let tab = tabID.map(tab(for:))
        return installed.compactMap { entry in
            guard let context = contexts[entry.id], let action = context.action(for: tab) else { return nil }
            return ExtensionButton(
                id: entry.id,
                label: action.label.isEmpty ? entry.name : action.label,
                badge: action.badgeText,
                icon: action.icon(for: CGSize(width: 20, height: 20)),
                isEnabled: action.isEnabled
            )
        }
    }

    /// Pressing an extension's button: its popup opens, or it hears a click.
    func press(_ id: String, in tabID: UUID?) {
        guard let context = contexts[id] else { return }
        context.performAction(for: tabID.map(tab(for:)))
    }

    // MARK: What the browser tells extensions

    func tab(for id: UUID) -> ExtensionTab {
        if let known = tabs[id] { return known }
        let made = ExtensionTab(id: id, store: self)
        tabs[id] = made
        return made
    }

    func window(for id: UUID) -> ExtensionWindow {
        if let known = windows[id] { return known }
        let made = ExtensionWindow(id: id, store: self)
        windows[id] = made
        return made
    }

    func tabOpened(_ id: UUID) {
        guard !contexts.isEmpty else { return }
        controller.didOpenTab(tab(for: id))
    }

    func tabClosed(_ id: UUID) {
        guard let closed = tabs.removeValue(forKey: id) else { return }
        controller.didCloseTab(closed, windowIsClosing: false)
    }

    /// The tab a window has in front changed.
    func window(_ windowID: UUID, focuses tabID: UUID?) {
        guard activeTabs[windowID] != tabID else { return }
        let previous = activeTabs[windowID]
        activeTabs[windowID] = tabID
        guard !contexts.isEmpty, let tabID else { return }
        controller.didActivateTab(tab(for: tabID), previousActiveTab: previous.flatMap { tabs[$0] })
        buttonGeneration += 1
    }

    func windowFocused(_ id: UUID) {
        guard !contexts.isEmpty else { return }
        controller.didFocusWindow(window(for: id))
    }

    func tabChanged(_ id: UUID, _ properties: WKWebExtension.TabChangedProperties) {
        guard !contexts.isEmpty, !properties.isEmpty, let known = tabs[id] else { return }
        controller.didChangeTabProperties(properties, for: known)
    }

    fileprivate func buttonChanged() { buttonGeneration += 1 }

    #if DEBUG
    /// Test-only: SPINE_INSTALL_EXTENSION holds Chrome Web Store ids or archive paths, comma-separated.
    /// Each installs at launch without asking, so a headless session can check one runs.
    private func installFromEnvironment() async {
        // The environment on the Mac, a launch argument (-SPINE_INSTALL_EXTENSION <ids>) in the Simulator.
        guard let wanted = ProcessInfo.processInfo.environment["SPINE_INSTALL_EXTENSION"]
            ?? UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["SPINE_INSTALL_EXTENSION"] as? String
        else { return }
        for item in wanted.split(separator: ",").map(String.init) {
            do {
                let candidate: ExtensionCandidate
                if ChromeWebStore.isExtensionID(item) {
                    candidate = try await fetch(item)
                } else {
                    let file = URL(fileURLWithPath: item)
                    candidate = try await stage(Data(contentsOf: file), id: file.deletingPathExtension().lastPathComponent)
                }
                await install(candidate)
            } catch {
                log.error("Couldn't install \(item): \(String(describing: error))")
            }
        }
    }
    #endif
}

// MARK: - What extensions ask of the browser

extension ExtensionStore: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let library else { return [] }
        // The focused window leads.
        let focused = library.activeWindow?.id
        return library.openWindows
            .sorted { a, _ in a.id == focused }
            .map { window(for: $0.id) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        library?.activeWindow.map { window(for: $0.id) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let asked = (configuration.window as? ExtensionWindow).flatMap { library?.window(id: $0.id) }
        guard let window = asked ?? library?.activeWindow else { return completionHandler(nil, nil) }
        let made = window.newTab(url: configuration.url)
        if configuration.url != nil { window.isCommandBarOpen = false }
        completionHandler(tab(for: made.id), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL { library?.activeWindow?.newTab(url: url) }
        completionHandler(nil)
    }

    // Installing an extension is the yes. What it asks for later, within its manifest, it gets.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        buttonChanged()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        ExtensionPopup.present(action)
        completionHandler(nil)
    }
}
