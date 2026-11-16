import Foundation
import Observation
import RevenueCat

enum ProConfig {
    /// The entitlement every paid product unlocks, as named in the RevenueCat dashboard.
    static let entitlementID = "spine_browser_pro"

    /// RevenueCat public SDK key. The SDK crashes on purpose when a Release build is configured
    /// with a Test Store (`test_`) key, so each configuration carries its own.
    #if DEBUG
    static let apiKey: String? = "test_CnwqACVApBCVWIDydFFMQyEmqrv"
    #else
    /// The App Store key (`appl_…`) from RevenueCat > Project Settings > API keys.
    /// While this is nil, Release builds leave purchases switched off.
    static let apiKey: String? = nil
    #endif
}

/// What the customer has paid for. RevenueCat holds the truth; this mirrors it for the views.
@MainActor
@Observable
final class ProStore {
    /// False when the build has no API key. Nothing here touches the SDK then.
    let isAvailable: Bool
    private(set) var customerInfo: CustomerInfo? {
        didSet {
            guard isPro else { return }
            // Finish what the customer was doing when the paywall stopped them, then close it:
            // with Pro unlocked it has nothing left to sell.
            pending?()
            pending = nil
            isPaywallOpen = false
        }
    }
    /// The offering the paywall sells: monthly, yearly and lifetime packages.
    private(set) var offering: Offering?

    var isPaywallOpen = false {
        // Closing the paywall without buying drops whatever was waiting on it.
        didSet { if !isPaywallOpen { pending = nil } }
    }
    var isCustomerCenterOpen = false

    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        guard let apiKey = ProConfig.apiKey else {
            isAvailable = false
            return
        }
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        // No accounts: RevenueCat keeps an anonymous ID, and Restore moves a purchase between phones.
        Purchases.configure(withAPIKey: apiKey)
        isAvailable = true
        // Read the cache now, so a paid launch never draws a frame of the free app.
        customerInfo = Purchases.shared.cachedCustomerInfo

        updates = Task { [weak self] in
            // Starts with the cached value, then yields every change, whoever made it:
            // the paywall, Customer Center, a restore, a renewal, an expiry.
            for await info in Purchases.shared.customerInfoStream {
                self?.customerInfo = info
            }
        }
        Task { [weak self] in
            // Prices for Settings. The paywall loads its own, so a failure here only costs the price line.
            self?.offering = try? await Purchases.shared.offerings().current
        }
    }

    var entitlement: EntitlementInfo? { customerInfo?.entitlements[ProConfig.entitlementID] }
    var isPro: Bool { entitlement?.isActive == true }

    /// Runs `action` for Pro customers. Everyone else gets the paywall, and `action` runs if they buy.
    func requirePro(_ action: @escaping () -> Void) {
        if isPro {
            action()
        } else if isAvailable {
            pending = action
            isPaywallOpen = true
        }
    }

    /// The paywall reports a purchase or restore before it dismisses, ahead of the update stream.
    func received(_ info: CustomerInfo) {
        customerInfo = info
    }

    /// Brings back purchases made with this Apple Account. True when Pro came back with them.
    func restore() async throws -> Bool {
        guard isAvailable else { return false }
        customerInfo = try await Purchases.shared.restorePurchases()
        return isPro
    }
}
