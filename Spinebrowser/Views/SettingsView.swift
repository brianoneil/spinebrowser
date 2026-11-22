import RevenueCat
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings own the inner display. The Spine steps aside and the sheet opens as a spread whose
/// gutter is the crease, so the layout holds when the Duo folds into a book. Windows too narrow
/// for a spread (the cover, upright) stack the same sections in one column.
struct SettingsView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        #if os(macOS)
        // The Mac gets a window-sized sheet with one column. The Duo's spread and its custom
        // alignment do not survive AppKit's constraint pass.
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { store.isSettingsOpen = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                SettingsStack()
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 680)
        .background(p.desk)
        #else
        GeometryReader { safe in
            SettingsSheet(insets: safe.safeAreaInsets)
                .ignoresSafeArea()
        }
        .background(p.desk.ignoresSafeArea())
        // No navigation title: it would add a bar across the top. The sheet's own title names it.
        .hideNavigationBackButton()
        .toolbar {
            // Back sits where the browser's Back sits, at the top of the system column.
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left") { store.isSettingsOpen = false }
                    .tint(p.text)
            }
        }
        #endif
    }
}

private struct SettingsSheet: View {
    /// Safe-area insets read outside this view; the trailing inset is the system column.
    let insets: EdgeInsets

    @Environment(\.palette) private var p

    /// The sheet's paper starts 10pt in from the left and stops 8pt short of the system column.
    private static let sheetLeading: CGFloat = 10
    private static let padding: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            ScrollView {
                Group {
                    if let columns = columns(in: geo) {
                        SettingsSpread(columns: columns)
                    } else {
                        SettingsStack()
                    }
                }
                .padding(.top, 34)
                .padding(.horizontal, Self.padding)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .environment(\.hasFold, !geo.reservedRegions(kind: .division, options: [.includeInactive]).isEmpty)
            .background(p.page)
            .clipShape(shape)
            .background {
                // Night depth comes from the lighter surface, never a shadow.
                if !p.isDark {
                    shape.fill(p.page)
                        .shadow(color: Color(hex: 0x221D18, opacity: 0.06), radius: 1, y: 1)
                        .shadow(color: Color(hex: 0x221D18, opacity: 0.08), radius: 15, y: 10)
                }
            }
            .padding(.leading, Self.sheetLeading)
            .padding(.trailing, insets.trailing + 8)
            // Upright, the system bar runs across the top. Flat it's 0.
            .padding(.top, insets.top + 10)
            .padding(.bottom, 10)
        }
    }

    /// Column widths for the spread, measured from the crease so nothing sits on the fold.
    /// Nil when the window is too narrow, or the crease runs across rather than down.
    private func columns(in geo: GeometryProxy) -> SpreadColumns? {
        let width = geo.size.width
        guard width >= Metrics.openMinimumWidth else { return nil }
        let crease: ClosedRange<CGFloat>
        if let frame = geo.reservedRegions(kind: .division, options: [.includeInactive]).first?.frame {
            guard frame.height > frame.width else { return nil }
            crease = frame.minX...frame.maxX
        } else {
            crease = (width / 2 - 20)...(width / 2 + 20)
        }
        let contentLeading = Self.sheetLeading + Self.padding
        let contentTrailing = width - insets.trailing - 8 - Self.padding
        let left = crease.lowerBound - SpreadColumns.creaseClearance.leading - contentLeading
        let rightStart = crease.upperBound + SpreadColumns.creaseClearance.trailing
        let right = contentTrailing - rightStart
        guard left >= 280, right >= 260 else { return nil }
        return SpreadColumns(left: left, gap: rightStart - (contentLeading + left), right: right)
    }
}

struct SpreadColumns {
    let left: CGFloat
    let gap: CGFloat
    let right: CGFloat

    /// How far each column stops short of the crease. The right page is narrower, so it sits closer.
    static let creaseClearance = (leading: CGFloat(38), trailing: CGFloat(26))
}

extension VerticalAlignment {
    private enum FirstSection: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.top] }
    }

    /// Lines up the first section on each page, under the title on the left.
    static let firstSection = VerticalAlignment(FirstSection.self)
}

/// Left page: the title, Tabs, Privacy and Pro. Right page: Appearance, About and the colophon.
private struct SettingsSpread: View {
    let columns: SpreadColumns

    var body: some View {
        HStack(alignment: .firstSection, spacing: columns.gap) {
            VStack(alignment: .leading, spacing: 28) {
                SettingsTitle()
                TabsSection().alignmentGuide(.firstSection) { $0[.top] }
                PrivacySection()
                ProSection()
            }
            .frame(width: columns.left, alignment: .leading)

            VStack(alignment: .leading, spacing: 28) {
                AppearanceSection().alignmentGuide(.firstSection) { $0[.top] }
                AboutSection()
                Colophon()
            }
            .frame(width: columns.right, alignment: .leading)
        }
    }
}

private struct SettingsStack: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsTitle()
            TabsSection()
            AppearanceSection()
            #if os(macOS)
            DefaultBrowserSection()
            #endif
            PrivacySection()
            ProSection()
            AboutSection()
            Colophon()
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

#if os(macOS)
/// The Mac's own habit: being the browser other apps open links with.
private struct DefaultBrowserSection: View {
    @Environment(\.palette) private var p
    @State private var isDefault = false
    @State private var working = false

    var body: some View {
        SettingsSection(title: "Browser") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Make Spine the default browser")
                    .font(.body)
                    .foregroundStyle(p.text)
                Text(isDefault
                     ? "Spine opens links from other apps."
                     : "macOS asks once before changing it.")
                    .font(.footnote)
                    .foregroundStyle(p.textSecondary)
                Button(isDefault ? "Default browser" : "Make Default") { requestDefault() }
                    .disabled(isDefault || working)
            }
        }
        .onAppear(perform: refresh)
    }

    private func requestDefault() {
        working = true
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
                Task { @MainActor in
                    refresh()
                    working = false
                }
            }
        }
    }

    private func refresh() {
        let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefault = current?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}
#endif

private struct SettingsTitle: View {
    @Environment(\.palette) private var p

    var body: some View {
        Text("Settings")
            .font(.largeTitle.bold())
            .foregroundStyle(p.text)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Sections

private struct TabsSection: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        SettingsSection(title: "Tabs") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Archive Today tabs after")
                    .font(.body)
                    .foregroundStyle(p.text)
                    .accessibilityHidden(true)
                ArchiveTimingPicker()
                ArchiveForecast()
            }
            .modifier(RowChrome())

            ToggleRow(
                title: "Unload idle tabs",
                detail: store.settings.unloadsIdleTabs
                    ? "After 30 minutes untouched. They reload when you open them."
                    : "Every tab stays in memory until you close it.",
                isOn: store.settingBinding(\.unloadsIdleTabs)
            )
        }
    }
}

private struct AppearanceSection: View {
    @Environment(BrowserStore.self) private var store
    @Environment(ProStore.self) private var pro
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsSection(title: "Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme")
                    .font(.body)
                    .foregroundStyle(p.text)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    ForEach(BrowserSettings.Theme.allCases) { theme in
                        ThemeSwatch(theme: theme, isSelected: store.settings.theme == theme) {
                            withAnimation(Motion.spring(reduce: reduceMotion)) {
                                store.updateSettings { $0.theme = theme }
                            }
                        }
                    }
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Hairline() }

            // Day never goes dark, so the option rests there. It's a Pro feature: locked, the switch
            // opens the paywall, and a purchase made there turns it on.
            ToggleRow(
                title: "True black at night",
                detail: "At night the desk behind your pages goes OLED black.",
                isOn: Binding(
                    get: { store.settings.trueBlackAtNight && pro.isPro },
                    set: { isOn in pro.requirePro { store.updateSettings { $0.trueBlackAtNight = isOn } } }
                ),
                isEnabled: store.settings.theme != .day && pro.isAvailable,
                isLocked: !pro.isPro
            )
        }
    }
}

private struct PrivacySection: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        SettingsSection(title: "Privacy") {
            ToggleRow(
                title: "Block trackers and ads",
                detail: store.settings.blocksTrackers
                    ? "Blocks \(ContentBlocker.blockedHostCount) known ad and tracker domains on every site."
                    : "Off. Pages load everything they ask for.",
                isOn: store.settingBinding(\.blocksTrackers)
            )
            ClearDataRow()
        }
    }
}

/// Free, the section sells Pro and restores it. Paid, it says what's active and opens Customer Center.
/// A build without a store key shows nothing.
private struct ProSection: View {
    @Environment(ProStore.self) private var pro

    var body: some View {
        if pro.isAvailable {
            SettingsSection(title: "Pro") {
                if let entitlement = pro.entitlement, entitlement.isActive {
                    ValueRow(title: "Spine Pro", value: "Active", detail: Self.term(of: entitlement))
                    ActionRow(title: "Manage purchase…", detail: "Change plan, cancel, or ask for a refund.") {
                        #if os(macOS)
                        if let account = URL(string: "https://apps.apple.com/account/subscriptions") {
                            Platform.openExternally(account)
                        }
                        #else
                        pro.isCustomerCenterOpen = true
                        #endif
                    }
                } else {
                    ActionRow(title: "Get Spine Pro…", detail: prices) { pro.isPaywallOpen = true }
                    RestoreRow()
                }
            }
        }
    }

    /// The store's own price strings, so currency and format follow the customer's storefront.
    private var prices: String {
        let parts = [
            pro.offering?.monthly.map { "\($0.localizedPriceString) a month" },
            pro.offering?.annual.map { "\($0.localizedPriceString) a year" },
            pro.offering?.lifetime.map { "\($0.localizedPriceString) once" },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "Monthly, yearly, or pay once and keep it." }
        return parts.formatted(.list(type: .or)) + "."
    }

    private static func term(of entitlement: EntitlementInfo) -> String {
        // The lifetime purchase never expires.
        guard let end = entitlement.expirationDate else { return "Yours for life." }
        if entitlement.billingIssueDetectedAt != nil { return "Payment failed. Fix it under Manage purchase." }
        let date = end.formatted(date: .abbreviated, time: .omitted)
        return entitlement.willRenew ? "Renews \(date)." : "Ends \(date)."
    }
}

private struct AboutSection: View {
    var body: some View {
        SettingsSection(title: "About") {
            ValueRow(title: "Version", value: Self.version)
            ValueRow(title: "Your data", value: "On this \(Platform.deviceName)", detail: "No accounts and no telemetry.")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }
}

/// New York signs the sheet, bound in the active space's cloth.
private struct Colophon: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.hasFold) private var hasFold

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Spinebrowser")
                .font(.system(.body, design: .serif).weight(.semibold))
                .foregroundStyle(p.text)
            Text("Made for the \(hasFold ? "fold" : "page"). Bound in \(store.activeSpace.binding.label).")
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(p.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title, color: p.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Hairline() }
            content
        }
    }
}

private struct Hairline: View {
    @Environment(\.palette) private var p

    var body: some View {
        Rectangle().fill(p.line).frame(height: 1).accessibilityHidden(true)
    }
}

/// A row sits on the paper: 14pt above and below, a hairline under it.
private struct RowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var isEnabled = true
    /// A Pro feature the customer hasn't paid for. The row wears the word until they do.
    var isLocked = false

    @Environment(\.palette) private var p

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(isEnabled ? p.text : p.textTertiary)
                    if isLocked { ProMark() }
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(isEnabled ? p.textSecondary : p.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(p.accent)
        .disabled(!isEnabled)
        .modifier(RowChrome())
    }
}

private struct ValueRow: View {
    let title: String
    let value: String
    var detail: String?

    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(.body).foregroundStyle(p.text)
                Spacer(minLength: 0)
                Text(value)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(p.textSecondary)
            }
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(p.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .modifier(RowChrome())
    }
}

/// The word on a locked Pro feature: a section-label "Pro" on a slip of soft verdigris.
private struct ProMark: View {
    @Environment(\.palette) private var p

    var body: some View {
        SectionLabel(text: "Pro", color: p.accentStrong)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(p.accentSoft, in: Capsule())
    }
}

/// A row you tap. Verdigris ink says so.
private struct ActionRow: View {
    let title: String
    let detail: String
    let action: () -> Void

    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(p.accentStrong)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(RowChrome())
    }
}

/// With no accounts, Restore is how a purchase follows its owner to a new phone.
private struct RestoreRow: View {
    @Environment(ProStore.self) private var pro
    @State private var isRestoring = false
    @State private var outcome: String?

    var body: some View {
        ActionRow(
            title: "Restore purchases",
            detail: isRestoring
                ? "Checking your purchases…"
                : outcome ?? "Paid before? Bring it back to this \(Platform.deviceName)."
        ) {
            isRestoring = true
            Task {
                do {
                    // When Pro comes back the section swaps to its paid rows, so only a miss needs words.
                    if try await pro.restore() == false {
                        outcome = "No purchase found for this Apple Account."
                    }
                } catch {
                    outcome = Self.message(for: error)
                }
                isRestoring = false
            }
        }
        .disabled(isRestoring)
    }

    private static func message(for error: Error) -> String {
        switch error as? ErrorCode {
        case .networkError, .offlineConnectionError: "You're offline. Connect and try again."
        default: "The store didn't answer. Try again in a minute."
        }
    }
}

/// Madder, with the word. A confirmation stands between the tap and the loss.
private struct ClearDataRow: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @State private var isConfirming = false
    @State private var isClearing = false
    @State private var didClear = false

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clear browsing data…")
                    .font(.body)
                    .foregroundStyle(p.danger)
                Text(didClear
                     ? "Cleared. Sites will ask you to sign in again."
                     : "Cookies, site data, caches, history and the archive. Open tabs stay.")
                    .font(.footnote)
                    .foregroundStyle(p.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isClearing)
        .modifier(RowChrome())
        .confirmationDialog("Clear browsing data?", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("Clear browsing data", role: .destructive) {
                isClearing = true
                Task {
                    await store.clearBrowsingData()
                    isClearing = false
                    didClear = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs you out of every site and empties your history and the archive. Open tabs stay and reload fresh.")
        }
    }
}

// MARK: - Controls

private struct ArchiveOption: Identifiable {
    let label: String
    let spoken: String
    let hours: Double?
    var id: String { label }

    static let all = [
        ArchiveOption(label: "6h", spoken: "6 hours", hours: 6),
        ArchiveOption(label: "12h", spoken: "12 hours", hours: 12),
        ArchiveOption(label: "24h", spoken: "24 hours", hours: 24),
        ArchiveOption(label: "Never", spoken: "Never", hours: nil),
    ]
}

/// Four segments on a sunken track. The chosen one is a slip of paper in verdigris ink.
private struct ArchiveTimingPicker: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ArchiveOption.all) { option in
                segment(option, isSelected: store.archiveAfterHours == option.hours)
            }
        }
        .padding(3)
        .background(p.sunken, in: Capsule())
        // The segments themselves are the elements, so focus rings sit on what's drawn.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Archive Today tabs after")
    }

    private func segment(_ option: ArchiveOption, isSelected: Bool) -> some View {
        Button {
            withAnimation(Motion.spring(reduce: reduceMotion)) { store.setArchiveAfter(hours: option.hours) }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? p.accentStrong : p.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(p.raised)
                            .overlay {
                                if p.isDark { Capsule().strokeBorder(p.line, lineWidth: 1) }
                            }
                            .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.08), radius: 1, y: 1)
                            .shadow(color: Color(hex: 0x221D18, opacity: p.isDark ? 0 : 0.06), radius: 4, y: 3)
                            .matchedGeometryEffect(id: "selected", in: selection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.spoken)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Copper says when the next Today tab shelves. On-screen tabs don't count down.
private struct ArchiveForecast: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Group {
                if store.archiveAfterHours == nil {
                    Text("Today tabs stay until you close them.")
                } else if let date = store.nextArchiveDate {
                    let remaining = max(0, date.timeIntervalSince(context.date))
                    let countdown = Text("Next tab shelves in \(ArchiveCountdown.format(remaining)).")
                        .foregroundStyle(p.time)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("\(countdown) Pinned tabs stay put.")
                        .accessibilityLabel(
                            "Next tab shelves in \(ArchiveCountdown.spoken(remaining)). Pinned tabs stay put."
                        )
                } else {
                    Text("Nothing waiting to shelve. Pinned tabs stay put.")
                }
            }
            .font(.footnote)
            .foregroundStyle(p.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small sheet of the theme it picks: desk behind, paper in front, a few lines of type.
private struct ThemeSwatch: View {
    let theme: BrowserSettings.Theme
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var p

    private var label: String {
        switch theme {
        case .system: "Match system"
        case .day: "Day"
        case .night: "Night"
        }
    }

    var body: some View {
        let inner = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 60)
                    .clipShape(inner)
                    .overlay {
                        if !isSelected { inner.strokeBorder(p.line, lineWidth: 1) }
                    }
                    .padding(2)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(p.accent, lineWidth: 2)
                                .padding(-2)
                        }
                    }
                    .accessibilityHidden(true)
                Text(label)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? p.accentStrong : p.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        switch theme {
        case .day:
            MiniPage(palette: Palette(isDark: false))
        case .night:
            MiniPage(palette: Palette(isDark: true))
        case .system:
            HStack(spacing: 0) {
                MiniPage(palette: Palette(isDark: false), half: .leading)
                MiniPage(palette: Palette(isDark: true), half: .trailing)
            }
        }
    }
}

/// One page of a theme preview. Halves meet in the middle for "Match system".
private struct MiniPage: View {
    let palette: Palette
    var half: HorizontalEdge?

    var body: some View {
        let r: CGFloat = 6
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: half == .trailing ? 0 : r,
            bottomLeadingRadius: half == .trailing ? 0 : r,
            bottomTrailingRadius: half == .leading ? 0 : r,
            topTrailingRadius: half == .leading ? 0 : r,
            style: .continuous
        )
        let narrow = half != nil
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(palette.text).frame(width: narrow ? 18 : 22, height: 4)
            Capsule().fill(palette.line).frame(width: narrow ? 26 : 40, height: 3)
            Capsule().fill(palette.line).frame(width: narrow ? 22 : 32, height: 3)
        }
        .padding(.top, 9)
        .padding(.leading, half == .trailing ? 6 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            shape.fill(palette.page)
                .shadow(color: Color(hex: 0x221D18, opacity: palette.isDark ? 0 : 0.08), radius: 1.5, y: 1)
        }
        .padding(.vertical, 8)
        .padding(.leading, half == .trailing ? 0 : 8)
        .padding(.trailing, half == .leading ? 0 : 8)
        .background(palette.desk)
    }
}

// MARK: - Store bindings

extension BrowserStore {
    /// A toggle's binding onto one setting, routed through `updateSettings` so side effects run.
    func settingBinding(_ keyPath: WritableKeyPath<BrowserSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

extension BrowserSettings.Theme {
    /// Nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .day: .light
        case .night: .dark
        }
    }
}
