# Spinebrowser — MVP Specification

**An Arc/Zen-style browser for the iPhone Duo (dual-screen iPhone).**

Version 0.1 — 2026-11-15
Status: Draft for review

---

## 1. Vision

Arc proved the sidebar-first browser; Zen proved the model survives without The Browser Company. Neither exists on a dual-screen phone. Spinebrowser takes the Arc/Zen vocabulary — Spaces, pinned/ephemeral tabs, command bar, glance-style peeking, split view — and rebuilds it around the iPhone Duo's two displays, where "split view" stops being a layout trick and becomes the physical form factor.

**One-line pitch:** Arc's sidebar on the left screen, the web on the right — and when you want two pages, each screen gets one.

**Working name:** Spinebrowser (the hinge is the spine; the two screens are the pages).

---

## 2. Research basis

This spec synthesizes three research streams (full reports in session history):

### From Arc (The Browser Company)
- Sidebar-first chrome; three-tier tab persistence: **Favorites** (cross-space), **Pinned** (per-space), **Today** (ephemeral).
- **Auto-archiving** of unpinned tabs on a timer (default ~12h) — tabs as temporary working state.
- **Spaces** (themed workspaces) + **Profiles** (per-space identity/cookies).
- **Command Bar** (Spotlight-for-the-browser) as the primary interface.
- **Little Arc / Peek** — lightweight link consumption that doesn't pollute the workspace.
- **Split View** up to 4 panes; **Boosts** (per-site CSS/JS customization); chrome-less, gradient-themed design language.
- Mobile lessons from Arc Search: auto-archiving, built-in ad/tracker blocking, reader mode, bottom-bar ergonomics.

### From Zen Browser
- **Workspaces** ≈ Arc Spaces, with the killer upgrade: workspace ↔ **container binding** (per-workspace cookie jars).
- **Essentials** tier above pinned tabs, visible in every workspace.
- **Glance**: modifier-click (or automatic from Essentials/pinned tabs) opens a floating, fully-browsable link preview; expand-to-tab or split from the overlay.
- **Compact Mode**: auto-hide chrome, reveal on edge-hover.
- Tab **auto-unloading** for memory; floating URL bar as a launcher; per-site **Boosts**.
- Community lessons: users forgave Zen's rough edges for open development; they missed Arc's auto-archiving, polish, and automatic behaviors.

### From dual-screen / foldable UX (Microsoft, Samsung, Google, Apple)
- **Microsoft's five canonical patterns**: extended canvas, list-detail, two-page, dual view, companion pane.
- **The seam is sacred**: never place text, buttons, or dialogs across the hinge; mask media, split controls.
- **Continuity is non-negotiable**: fold/unfold/rotate must never lose state or trigger reloads.
- **Apple precedent**: iPad Safari Split View (two independent windows, draggable tabs/links between them).
- **Dual-pane browsing is the killer feature**: "open link in other pane" is the canonical dual-screen gesture.
- Technical: one `WKWebView` per pane, multi-scene support, posture-aware layouts (book/tabletop).

---

## 3. Product principles

1. **The seam is the feature.** Arc put split view in software; the Duo puts it in hardware. Every Arc feature is re-examined through "what does this become with two screens?"
2. **One screen = one logical unit.** Spanning is an enhancement, never a requirement. The app is fully usable folded (single screen).
3. **Tabs are temporary.** Arc's core insight: unpinned tabs auto-archive. Default ON.
4. **Chrome recedes.** Content is full-bleed; UI appears on summon (tap, edge-swipe, command bar).
5. **Craft is a feature.** Arc's cult following came from micro-affordances, motion, and theming — budget for it from day one.
6. **No AI in MVP.** Arc Search's "Browse for Me" and Dia-style features are explicitly out of scope. (See §10, Future.)

---

## 4. MVP feature set

Priority legend: **P0** = ship blocker, **P1** = ship if on schedule, **P2** = cut first.

### 4.1 Spaces (P0)

Zen-style Workspaces, simplified for phone:

- Named workspaces with emoji icon + color theme (gradient tints the chrome, per Arc/Zen).
- Horizontal swipe on the sidebar (left screen) to switch spaces; switching swaps the tab list instantly, no reloads.
- Default: two spaces ("Personal", "Work") created at onboarding; max 8.
- Per-space: pinned tabs, today tabs, theme. Favorites/Essentials are global (visible in every space).
- **Out of MVP:** profile/container binding (per-space cookie isolation). Deferred — see §10. MVP uses a single cookie jar.

### 4.2 Three-tier tabs (P0)

The Arc/Zen model, adapted:

| Tier | Behavior | UI |
|---|---|---|
| **Essentials** | Global, persist forever, never auto-archive | Top row of the sidebar, icon grid |
| **Pinned** | Per-space, persist across launches, never auto-archive | Sidebar section with favicon + title |
| **Today** | Ephemeral; **auto-archive after 12 hours** (configurable: 6h/12h/24h/off) | Sidebar list, most recent first |

- Archived tabs recoverable from an Archive view (grouped by day, searchable).
- Tab unload: tabs inactive >30 min unload from memory (Zen-style); reload on activation. Pinned tabs lazy-load after app restart. On by default; Settings can turn it off (§4.11).
- Long-press a Today tab → Pin, Move to Essentials, Close, Move to Space.

### 4.3 The Spine (P0) — tabs on the left edge

The tab UI lives on the **left** edge of the open display, opposite the system's right-hand control column. This matches Apple's sidebar placement (280pt) and Safari 27.3's Vertical Tabs. On the open display it has four states:

| State | Width | What it shows | Use |
|---|---|---|---|
| **Sidebar** | 280pt | Space header + binding switcher, Essentials grid, Pinned, Today (with copper countdown), Search or command | Default; organizing, switching spaces |
| **Spines** | 56pt | Chrome-style tabs rotated 90°: favicon upright, title running top-to-bottom like a book spine, vertical scroll, tap to switch. Active spine joins the page; × on the active spine. Pinned spines sit above a rule, Today below, as in Rail | Reading with names visible; ~3 tabs per screen |
| **Rail** | 56pt | Favicons only, stacked; active tab marked | Many tabs; ~3× density of Spines |
| **Hidden** | 0pt | Nothing; swipe in from the left edge and the Sidebar slides over the page as an overlay, then slides away after a pick | Full-bleed reading, video |

- Drag the Spine's right edge to snap between detents: 0 → 56 → 280. Pinch the 56pt strip to toggle Spines ↔ Rail. The system-column Spine button cycles states.
- Spines and Rail share 56pt, so switching between them never reflows the page.
- Active tab highlighted; audio indicator on tabs playing media; tap to switch, swipe to close.
- Closed (cover display), the Spine becomes a shelf — see §4.9.

### 4.4 The Pair (P0) — the headline feature

The open display is one canvas, so split view is in-app: **two browser windows, side by side, at most two**.

- **Independent instances.** Each window has its own history, scroll state, and space (and its own cookies once Profiles ship). For example, Work in Lapis on the left and Personal in Verdigris on the right. Each window's top bar is tinted by its binding.
- **Divider on the fold.** The 12pt gutter sits on the crease (x 475.5), so the crease hides in it. Flat, you can drag the divider to resize, with a magnetic detent at the fold. When the device bends, it locks to 50/50.
- **Spine drops to the Rail (56pt)** to give both pages room. A swipe from the left edge slides the full Sidebar over the Pair, with a scrim. Long-press a tab to open it on the left, open it on the right, or start a new Pair. You can also drag a tab row onto a window.
- **A Pair is kept like one tab.** It sits in the Spine as one row, its two tabs side by side; in Spines and the Rail it's one item with both icons stacked. Pick any other tab and the Pair waits in the list as it was. Tap either half to bring both windows back with that side focused. Only you change a Pair: drop a tab or link on a window, Open on the left or right, Swap sides, Separate tabs, Close both tabs. Closing one of its tabs leaves the other on screen alone. Each Pair remembers its own divider.
- **Drag and drop between windows:** images, text, links, whole tabs. A tab carried over a window shows a drop zone (Open here, or Swap sides when it's already across); over a single page the zone splits on the fold to start a Pair. A link carried out of one page turns the other window's bar into a drop zone, and the page below keeps its own drops so editors still take images and text.
- **Drop to keep.** Essentials and Pinned take drops too. A tab moves to that tier; a link becomes a new tab kept there. Nothing on screen changes.
- **Divider.** Double-tap the grip to send it back to the fold.
- **Focus.** Exactly one window is focused, shown by an outline in its binding's ink. The system column acts on the focused window; tap the other window to move focus.
- **Open on the other side.** Long-press a link and Glance opens over the *other* window, with "Keep on right" to promote it there (see §4.6).
- **Closing:** the focused window takes the cover screen. The Pair stays intact, and you swipe the URL pill to flip between the two windows. On the Shelf, the Pair shows as one card. Opening the device restores both windows to their sides of the crease.
- **Upright:** there's no side-by-side layout. The Pair behaves as it does on the cover (the focused window shows, the other is behind the pill), and rotating back to landscape restores the split.
- **Spanned mode** (single page across the whole canvas) is the default when flat with no Pair.

### 4.5 Command bar (P0)

Arc's Cmd-T, reimagined for touch:

- Floating, centered panel (Zen floating-URL-bar style), summoned by: tap on the collapsed URL pill, swipe-down on a pane's top edge, or hardware keyboard Cmd-L.
- Single field for: URL entry, web search (configurable engine), open-tab search/switching, archive search, and **commands** ("pin tab", "move to space", "split", "archive all today tabs").
- Fuzzy matching across tabs/history; shows which pane a result will open in (defaults to active pane).
- **Ranking.** Open tabs lead, so you switch instead of duplicating. A command whose name contains what you typed as one run ("set" → Settings) outranks tabs that only match letter by letter, and it outranks the web-search fallback. Return runs the top result.

### 4.6 Glance (P1)

Zen's Glance, touch-native:

- Long-press a link → **Peek** (iOS context-preview style, but a live WKWebView, not a snapshot). Release to dismiss; "Open" button promotes to a real tab in the other pane; "Split" button dedicates a pane.
- From Essentials/pinned tabs, off-site links auto-open in Glance (Zen behavior) — pinned apps stay stable.

### 4.7 Reader mode with two-page layout (P1)

- Standard reader extraction (readability-style), dark/light/sepia.
- **Book mode** in dual-portrait: content paginated across both screens, two pages per advance (Microsoft two-page pattern); seam masks images.
- Tabletop posture (half-folded, resting on surface): content on top screen, reading controls/progress on bottom.

### 4.8 Privacy & blocking (P0)

- Built-in tracker/ad blocking (WebKit content-blocker ruleset, ship a maintained list). On by default; Settings can turn it off, and pages on screen reload so the change shows at once.
- Clear browsing data from Settings: cookies, site data, caches, favicons and the archive. Open tabs stay and reload fresh, so no signed-in page lingers.
- Auto-deny cookie-consent banners where possible (Arc Search behavior).
- Per-space history; archive excluded from history suggestions by default.
- No accounts, no telemetry in MVP. Local-only state. (Sync is §10.)

### 4.9 Continuity & posture handling (P0)

- Fold/unfold/rotate: preserve scroll position, tab state, form input, in-flight loads. **Never reload on geometry change.**
- Folded (single screen): sidebar becomes an edge-swipe overlay; panes become a tab switcher; the app is a complete single-screen Arc-style browser, not a degraded mode.
- Half-folded tabletop: content top, controls bottom (Samsung Flex Mode pattern).
- Support both single-scene-spanned and dual-scene models; tabs live in a scene-agnostic shared model.

### 4.10 Theming & craft (P1)

- Per-space accent color + gradient; chrome tints to match (Arc/Zen).
- Theme: Match system (default), Day or Night. **True black at night** drops the night desk to #000 for OLED; pages and the Spine keep their tone. It's the first Spine Pro feature (§4.11). A reader-only OLED option arrives with Reader mode (§4.7).
- Motion: spring animations on sidebar reveal, space switch, glance open. Delight budget: one signature animation (Arc's dancing-thumbnail equivalent) — candidate: tabs "shelving" themselves into the archive.

### 4.11 Settings (P0)

The habits you set once. Settings take the inner display: the Spine and the page step aside, and the system column keeps one control, Back, in the same spot as the browser's Back. Open it from the command bar (type "set", or pick **Settings**).

**Layout.** On the open display the sheet is a two-page spread whose gutter is the crease. Each column is measured from the `.division` reserved region (left column ends 38pt before it, right column starts 26pt after it), so the spread holds unchanged when the Duo bends into a book. Left page: title, Tabs, Privacy, Pro. Right page: Appearance, About and a colophon. The left page runs taller than the open display, so the sheet scrolls; at rest Pro's label and first row show above the fold. Where there's no room for a spread (the cover, open upright) the same sections stack in one scrolling column. Settings stay open through fold and unfold.

| Section | Control | Default | What it does |
|---|---|---|---|
| Tabs | **Archive Today tabs after** 6h · 12h · 24h · Never | 12h | Sets the auto-archive timer (§4.2). A shorter time shelves anything already past it straight away. A copper line under it counts down to the next shelving; Never says Today tabs stay until you close them. |
| Tabs | **Unload idle tabs** | On | Off keeps every tab's web view in memory. |
| Appearance | **Theme** Match system · Day · Night | Match system | Day and Night override the system appearance for the whole app, web content included. |
| Appearance | **True black at night** (Pro) | Off | At night the desk goes #000. Disabled while the theme is Day. Free, the row wears a Pro mark and the switch opens the paywall; a purchase made there turns it on. If Pro lapses, the desk returns to its night tone and the setting stays saved. |
| Privacy | **Block trackers and ads** | On | Adds or removes the bundled rule list on every web view and reloads the pages on screen. The footnote quotes how many domains the list blocks, counted from the bundled file. |
| Privacy | **Clear browsing data…** | — | Madder, behind a confirmation. Clears what §4.8 lists, then says so in place: "Cleared. Sites will ask you to sign in again." |
| Pro | **Get Spine Pro…** · **Restore purchases** | — | Shown to free customers. Get Spine Pro opens the RevenueCat paywall, and its footnote quotes the store's own prices. Restore brings back a purchase made with the same Apple Account and says so in place when it finds none. |
| Pro | **Spine Pro** · **Manage purchase…** | — | Shown to paid customers. Spine Pro reads Active with the renewal or end date, or "Yours for life." Manage purchase opens RevenueCat's Customer Center. |
| About | **Version** · **Your data** | — | Marketing version and build. Your data is on this phone (on iPad, this iPad), with no accounts and no telemetry. |

- Settings persist with the rest of local state. Every setting decodes with a default, so a setting added later never wipes saved tabs.
- Toggles switch on the switch itself, as in iOS Settings. Each segment and swatch is its own accessibility element with a selected trait.
- Design: Paper page **Settings** (day, night, command-bar entry; Pro: free at rest, free scrolled, paid).

### 4.12 iPad

The same browser, minus the fold. Everything above holds on iPad; this is what changes.

- **The app draws its own bar.** iPadOS has no system column, so the controls come inside: one row of glass buttons on the desk, above the page. The Spine toggle and back/forward lead; Share, Pair and New tab trail. The bar acts on the focused window, like the system column. The Duo keeps its system column.
- **The cloth runs to the top.** The Spine sits under the 24pt status bar and, in a window, under the window controls. Its content starts below both. The page sits below the bar.
- **No fold, no crease.** The divider of a Pair rests wherever you leave it, with 240pt for each window. The bead marks the even split instead of the fold: a magnetic detent, filled when the divider sits on it. Double-tap the grip to split evenly. Nothing ever locks.
- **Width decides the layout, not the device.** Under 600pt the window takes the cover's layout: the Spine slides in over the page and a Pair shows its focused side. Under 1000pt the window starts in Spines, so an 11-inch in portrait has room to read. Widen it and the Sidebar comes back. A Pair stays available in portrait.
- **Every window is its own browser.** Each window keeps its own Space, focus, Spine and Pair. Spaces, tabs, Pairs, the archive and settings are shared: pin a tab in one window and it's pinned in both. A window comes back to the tabs it had.
- **One tab, one window.** A page lives in one place at a time. Pick a tab that another window shows and it moves here; that window falls back to its most recent tab that isn't on screen anywhere. A new window starts on a fresh tab in the Space you were using.
- **Keyboard and menu bar.** Every command lives in the menu bar, so iPadOS lists them when you hold ⌘:

| Menu | Command | Shortcut |
|---|---|---|
| File | New Tab · New Window | ⌘T · ⌘N |
| View | Change the Spine · Reload · Zoom In · Zoom Out · Actual Size | ⌃⌘S · ⌘R · ⌘+ · ⌘− · ⌘0 |
| History | Back · Forward · Show the Archive | ⌘[ · ⌘] · ⌘Y |
| Tabs | Search or Command · Reopen Closed Tab · Close Tab | ⌘L · ⇧⌘T · ⌘W |
| Tabs | Next Tab · Previous Tab · Tab 1 to 8 · Last Tab | ⌃Tab · ⌃⇧Tab · ⌘1–⌘8 · ⌘9 |
| Tabs | Pin Tab · Open a Pair · Focus the Other Window · Swap Sides | ⌘D · ⌥⌘P · ⌥⌘→ · ⌥⌘S |
| Spaces | Each Space by name | ⌃1–⌃9 |

  Find on the page is the system's Edit ▸ Find (⌘F). Pair commands stay grey until a Pair is open.
- **Pointer.** Tabs, Pairs and Essentials lift under the pointer, and the pointer melts into them. Touch never sees it.
- **Copy.** Words that name the fold have a no-fold version: the divider reads "Even split", the colophon says "Made for the page", and Settings says "this iPad".
- Design: Paper page **iPad — no fold** (01 landscape with the Sidebar · 02 the Pair without a crease · 03 portrait with Spines · 04 two windows in Stage Manager · 05 keyboard, menu bar and pointer).

### Explicitly out of MVP

- AI features (Browse for Me, summaries, smart archive)
- Boosts / per-site customization
- Easels / Notes / capture
- Profiles / container isolation
- Sync across devices
- Extensions
- macOS version (iPad comes first, §4.12)

---

## 5. Information architecture

```
App
├── Space 1..8 (active space drives both panes)
│   ├── Pinned Tabs []
│   └── Today Tabs []  (auto-archive timer)
├── Essentials []        (global)
├── Archive              (grouped by day)
└── Panes
    ├── Left pane  → active tab id
    └── Right pane → active tab id
```

Tabs are scene-agnostic entities; panes are views onto tabs. Closing a tab in one pane promotes the pane's most-recent tab.

---

## 6. Key flows

**First run (≤90 seconds):**
1. Pick two space themes (Personal/Work presets).
2. "Tabs clean themselves up after 12 hours — pin what you want to keep." (one screen, skippable)
3. Land in dual-pane: left = sidebar, right = welcome page with three gestures to try (open in other pane, command bar, glance).

**Research flow (the demo):**
1. Search in command bar → results on right pane.
2. Long-press a result → "Open on other screen" — wait, results are right; link opens left. Sidebar auto-collapses to an overlay strip; both panes now show content.
3. Compare; drag the left pane's tab into Pinned.
4. Walk away. Tomorrow, unpinned tabs have auto-archived; pinned research remains.

**Fold flow:**
1. User folds to single screen mid-session.
2. Right pane's tab becomes the visible tab; left pane's tab drops into Today (badge indicates "other screen's tab"); sidebar becomes edge-swipe overlay.
3. Unfold: both panes restore exactly — scroll, form state, everything.

---

## 6.5 Device geometry (verified)

iPhone Duo display specs (per App Store Connect rendered sizes ÷ @3x):

| Display | Points | Aspect | Size class |
|---|---|---|---|
| Inner (unfolded) | 669 × 951 | 1.42 | Regular × Regular, both orientations |
| Outer (folded/cover) | 466 × 678 | 1.45 | Compact × Regular (portrait) |
| iPhone 18 Pro (reference) | 402 × 874 | 2.17 | — |

Consequences:
- Each unfolded "page" is ~466 × 678 — the same shape as the cover screen. Folded and unfolded pages are geometrically continuous; folding parks one page, it does not resize it.
- The inner display is squat (1.42 vs 2.17). Single-column phone layouts stretched across it look wrong — the Duo posture layouts (§4.4) are the default, not an enhancement.
- Inner display reports Regular width with the phone idiom — idiom-based layout gates never fire; gate on size class.
- Common wrong answer: 626 × 890 (panel pixels ÷ 3). Use 669 × 951 (rendered ÷ 3).
- Posture geometry: open book = two 466×678 pages, vertical hinge (951×678 overall, landscape). Tabletop/flex = device rotated 90°, hinge horizontal across the 669pt width: two 669×466 halves, content top, controls bottom.

**System UI placement (verified 2026-11-15 against Apple's Duo tech talks, the HIG, and Xcode 27.2 simulator measurements):**
- **The inner display is one continuous screen**, 951×669 when held open, with 55pt corner radii. The crease is a `.division` reserved region at x 455.5–495.5 (40pt). It's inactive when flat and active only when partially folded.
- **The status area is the top of a right-hand column, not a top strip.** It's an 84×124 occlusion at x 867, y 0, with the clock stacked above a circular battery/Wi-Fi ring (tap the ring for Control Center).
- **App controls stack vertically under the status area**, as 48pt circles centered at x ≈ 902.5. The order is back/close, then the prominent action, then the toolbar groups; a tab bar sits at the bottom, ending 24pt above the edge. They are icon-only.
- **Safe area:** right 84, bottom 34, top 0, left 0. Layout margins are leading 20, trailing 84. There is no permanent Dynamic Island on the inner display.
- **The inner camera sits under the display** at x 677, y 21 (58×37), as an occlusion region that's present only while the camera is on.
- **Apple's sidebar opt-in** is 280pt on the left, which gives an Arc-like layout: tabs on the left, system controls on the right. Safari opts out of vertical bars on the open display and uses a top bar instead; we take the sidebar route.
- **Cover display (466×678):** the hinge is on the left. The camera / Dynamic Island is top-right, with the clock and status ring below it in an 84×174 column at x 382. Content is 382pt wide; the bottom inset is 34.
- **Open, upright (669×951):** bars go horizontal again. Status is top-right (144×82), the top inset is 82, and the crease is horizontal at y 455.5–495.5.
- **Split View** is a fixed 50/50 with the divider on the crease. Each app's controls go on its outer edge, and each half gets about 475pt. Closing returns to one app at a time.
- **Hardware:** Touch ID is in the side button (right edge when open); there's no Face ID. The UI favors right-handed use.

## 6.6 Design files

Paper file **Spinebrowser** (https://app.paper.design/file/01M7FY98GFMEZV8Y6CCC1S8F2Q):

- **Design Language:** Principles · 01 Color (the reading room, Bindings) · 01b Light & dark · 02 Typography · 03 Space & motion · 04 Device & system UI · 05 The Spine (all four states).
- **Modes v2 — Postures & the Spine:** 01 Open flat · Sidebar · 02 Spines at night · 03 The Pair, drag between windows · 04 Pair + Spine overlay · 05 Glance & command bar · 06 Closing → cover storyboard · 07 Cover Shelf · 08 Book with thumb index · 09 Laptop console · 10 Open upright · 11 Pairs kept, one row in the Spine · 12 Drag a tab onto a window · 13 Drag a link across the Pair.
- **Settings:** 00 cover · 01 Settings, day, open flat · 02 Settings, night, open flat · 03 Open from the command bar.
- **iPad — no fold:** 01 Landscape · Sidebar · 02 The Pair, no crease · 03 Portrait · Spines · 04 Stage Manager, two windows · 05 Keyboard, menu bar, pointer.
- **Modes v1:** superseded. It used a two-screen model and a standard iPhone status bar.

## 7. Technical architecture

- **Platform:** Swift + SwiftUI (chrome/UI) with UIKit interop where needed; **WKWebView** per pane.
- **Process isolation:** separate `WKProcessPool` per pane; shared `WKWebsiteDataStore` in MVP (per-space data stores land with Profiles later — design the seam now).
- **Tab model:** single source of truth; panes and scenes render onto it. No tab state in view controllers. A shared `Library` holds spaces, tabs, Pairs, the archive, settings and the web views; each window's `BrowserStore` holds its panes, Spine and Pair, and saves under the window's scene id. A web view shows in one window at a time.
- **State restoration:** persist per-pane navigation state, scroll offsets, reader state; restore across launch and geometry change.
- **Scenes:** `UISceneSession` multi-scene support; one-window-spanned vs two-window modes behind an abstraction layer.
- **Seam geometry:** if/when Apple exposes viewport-segment APIs in WebKit, adopt; until then compute hinge zone from display geometry and keep a safe inset (never place interactive UI within it). Optionally inject segment info into pages via `WKUserScript` + CSS env polyfill.
- **Content blocking:** `WKContentRuleList` compiled at launch from a bundled list and toggled per user setting across every live web view. A per-page blocked count needs WebKit to report blocked loads; public API doesn't, so Settings quotes the list's size instead.
- **Memory budget:** target ≤2 loaded webviews per space beyond the two visible panes; Zen-style auto-unload at 30 min idle.

---

## 8. Design language

- **Chrome-less default:** full-bleed content; a floating URL pill (domain only) is the only persistent chrome, dismissible.
- **Sidebar** (left screen or overlay): blurred material background tinted by space gradient; SF Symbols; 44pt+ touch targets.
- **The seam:** treated as a hard layout boundary. No text, buttons, dialogs, or menus cross it. Media may mask under it in spanned mode.
- **Type:** SF Pro; reader mode offers a serif option.
- **Motion:** spring physics throughout (response ~0.4, damping ~0.8); 60fps floor; reduce-motion honored.

---

## 9. Success metrics (MVP)

| Metric | Target |
|---|---|
| Onboarding completion | ≥80% reach first dual-pane session |
| "Open in other pane" usage | ≥30% of DAU in week 1 |
| Auto-archive retention | ≤5% of users disable it |
| Fold/unfold state loss | 0 reported incidents |
| Cold start to interactive | <1.0s |
| Crash-free sessions | ≥99.5% |

---

## 10. Post-MVP roadmap (ordered)

1. **Profiles / per-space data isolation** (Zen container-binding equivalent) — the #1 Arc/Zen differentiator deferred from MVP.
2. **Sync** (end-to-end encrypted; iCloud-first).
3. **Boosts** (per-site appearance tweaks — tint, fonts, element zap; no JS injection initially).
4. **AI assist** (on-device page summaries; opt-in "Browse for Me"-style answers).
5. **Capture/Easel-lite** (live region capture that links back to source).
6. **Link routing rules** (Arc Air Traffic Control: domain → space).
7. **macOS companion** via SwiftUI shared code, after the iPad (§4.12).

---

## 11. Risks

| Risk | Mitigation |
|---|---|
| iPhone Duo SDK/geometry APIs unknown until Apple ships | Build against size classes + simulated hinge inset; abstract all seam logic behind one module |
| WKWebView memory with 2+ panes | Aggressive auto-unload; per-pane process pools; hard budget |
| Arc's "novelty tax" (learning curve killed mainstream adoption) | Onboarding teaches 3 gestures only; every advanced feature discoverable but never required |
| WebKit lacks viewport-segment CSS | Polyfill via WKUserScript; never depend on it for core layout |
| Scope creep toward "Arc everything" | §4.10 out-of-scope list is contractual; roadmap items need explicit re-prioritization |

---

*Research: Arc feature inventory, Zen feature inventory, dual-screen/foldable UX patterns (Microsoft Learn, MDN, Android/Samsung foldable docs, Apple multitasking docs). Gathered 2026-11-15.*
