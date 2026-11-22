# Chrome extensions

Spinebrowser runs Chrome extensions straight from the Chrome Web Store. This is a working prototype on the Duo, iPad and Mac, on the `chrome-extensions` branch.

## The idea

A Chrome extension and a Safari web extension are the same thing on disk: a manifest, some scripts, some pages. WebKit ships an engine for them, `WKWebExtensionController`, and it answers to `chrome.*` as well as `browser.*`. So we don't write an extension runtime. We feed WebKit's.

That leaves three jobs for us:

1. **Get the extension.** The Chrome Web Store hands out a CRX for any extension id. A CRX is a ZIP behind a signature header. We take the header off and give WebKit the ZIP.
2. **Describe the browser.** Extensions ask about windows and tabs. We answer with thin adapters over `Library` and `BrowserStore`, and tell WebKit when a tab opens, closes, comes forward or changes page.
3. **Show what it asks for.** The extension's button, its popup, the tabs it opens, the yes at install.

## How it's built

| File | Job |
|---|---|
| `Extensions/ChromeWebStore.swift` | Reads an extension id from a store address, builds the download address, unwraps CRX2 and CRX3. |
| `Extensions/ExtensionStore.swift` | Owns the one `WKWebExtensionController`. Installs, loads, switches off and removes extensions. Is the controller's delegate. |
| `Extensions/ExtensionBridge.swift` | `ExtensionTab` and `ExtensionWindow`, what WebKit sees of ours. Presents popups. |
| `Views/ExtensionsMenu.swift` | The puzzle piece in the address pill. |
| `Views/SettingsView.swift` | The Extensions section. |

Every page shares one `WKWebViewConfiguration`, and that configuration now carries the controller. That's the whole hook for content scripts: WebKit injects them into any page it knows about. An extension's own pages (options, a welcome page) need that extension's configuration, so `WebEngine` picks it when a tab's address belongs to an extension.

Extensions start with the browser, not with the first page, so a window that opens on a blank tab still has its workers running.

Archives live in `Application Support/Extensions/<id>.zip`, beside `installed.json`. The Chrome id is the extension's `uniqueIdentifier`, so its storage survives a relaunch.

## Using it

- Open an extension's page on the Chrome Web Store. The store's own button, dead anywhere that isn't Chrome, reads **Add to Spine** and works. A script on the store page wakes it and hands the click to the browser. It matches the English label, so other languages fall back to the next way in.
- Or use the puzzle piece in the address, which turns verdigris on a store page. Tap it, then **Add this extension**.
- With extensions running, the puzzle piece lists them, badge and all. Tap one for its popup: a sheet on the Duo's cover, a popover from the button on iPad and Mac.
- Settings ▸ Extensions switches each one on or off. Touch and hold to remove; right-click on the Mac.

## What we checked

On the Duo simulator.

With the sample in `docs/extension-sample` (Manifest V3):

- A content script lands on every page.
- The page messages the service worker and gets an answer, with `sender.tab` filled in.
- `chrome.storage.local` holds across a relaunch.
- `chrome.action.setBadgeText` reaches the menu.
- The popup opens, `chrome.tabs.query` finds the tab in front, `chrome.scripting.executeScript` changes the page.

With Dark Reader, installed from the store through the puzzle piece:

- It installs, opens its welcome page in a new tab (`chrome.tabs.create`), and darkens Wikipedia.
- Its popup works and knows the current site.
- Switched off, new pages load light.

On the iPad simulator, with both: content scripts run, storage holds across a relaunch, the menu lists both, and Dark Reader's popup opens as a popover from the puzzle piece.

On the Mac, through debug probes, because this machine can't record its screen: Dark Reader installs from the store, survives a relaunch, darkens Wikipedia, shows its button, and its popover opens at full size. The puzzle piece sits in the bar beside the address. Nobody has clicked through the Mac's menu or the install prompt by hand yet.

To install without the UI, launch a debug build with `-SPINE_INSTALL_EXTENSION <id or path to a zip>`. Ids and paths can be comma-separated. On the Mac it's an environment variable of the same name, and the sandbox only reads paths inside the app's container. Two more, Mac-minded: `SPINE_EXTENSION_PROBE` runs JavaScript in the page in front and logs the answer, and `SPINE_PRESS_EXTENSION` presses an extension's button and logs whether its popup showed.

## What it doesn't do yet

- **It's WebKit's API surface, not Chromium's.** Blocking `webRequest`, `debugger`, `sidePanel`, `offscreen`, `identity` and native messaging aren't there. Extensions that lean on them load and then limp. Content blockers built on `declarativeNetRequest` are the ones to bet on.
- **No signature check.** We trust HTTPS to Google and throw the CRX signature away. Verifying CRX3 is the first thing to add before this ships.
- **No updates.** An extension stays at the version you added.
- **One yes covers everything.** Install grants what the manifest asks. No per-site control, no later prompts.
- **Switching off isn't instant.** Scripts already in a page stay until it reloads.
- **Clear browsing data skips extension storage.**
- **The popup is the system's sheet.** Nothing here is drawn in Paper yet: the menu, the sheet and the Settings rows borrow existing parts.
- **App Review.** Extensions are code we download. WebKit runs it, which is the carve-out other browsers use, but it needs a read of the guidelines before submission.
