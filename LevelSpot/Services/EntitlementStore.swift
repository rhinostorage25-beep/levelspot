import Foundation
import StoreKit
import Observation

/// Free/Pro entitlement, backed by StoreKit 2.
///
/// `Transaction.currentEntitlements` is the on-device source of truth; a live `Transaction
/// .updates` stream keeps it correct across restores, refunds and Family Sharing without the
/// app being reopened. The old local UserDefaults flag is gone — it was tamperable, and the
/// data layer's RLS (supabase/migrations/001_schema.sql, user_entitlements) is what actually
/// enforces Pro on *synced* data regardless of this client.
///
/// v1 uses client-side verification (`VerificationResult`). Server-side receipt validation
/// (App Store Server Notifications → user_entitlements) is a later hardening step, not needed
/// to gate the local Pro surfaces.
@MainActor
@Observable
final class EntitlementStore {
    /// Non-consumable, lifetime "LevelSpot Pro" unlock. Must match the product id created in
    /// App Store Connect (and any local .storekit config used for simulator testing).
    static let proProductID = "uk.co.levelspot.pro"

    /// ⚠️ TESTFLIGHT PREVIEW LEVER — works in Release (not `#if DEBUG`), because Windows-only
    /// dev means TestFlight is the only way to see a device build; there's no local Xcode run
    /// to reach the DEBUG sim toggle. Toggled from inside the app itself (long-press the
    /// calibrate icon on the Level screen — deliberately not a visible button, so a reviewer
    /// tapping through the app in the normal way won't stumble onto a free-Pro switch) and
    /// persisted so it survives relaunch. Real purchases/restores always win over this.
    /// **MUST be OFF before App Store submission — this is a live toggle, not a build-time
    /// constant, so it ships in every build regardless of state. Removing the gesture (or at
    /// minimum confirming it's off and staying off) is a required submission step.**
    private static let previewKey = "proPreviewOverride"
    private(set) var previewProOn = UserDefaults.standard.bool(forKey: EntitlementStore.previewKey)

    /// Flip the TestFlight preview lever. Fires a fresh `updateEntitlement()` so `isPro`
    /// reflects it immediately (real entitlement still takes priority if present).
    func setPreviewPro(_ on: Bool) {
        previewProOn = on
        UserDefaults.standard.set(on, forKey: Self.previewKey)
        Task { await updateEntitlement() }
    }

    // Seeded synchronously from the same persisted flag (can't reference `previewProOn`
    // directly here — Swift forbids one stored-property default from reading another).
    // `updateEntitlement()` re-derives this properly moments later at launch.
    private(set) var isPro = UserDefaults.standard.bool(forKey: EntitlementStore.previewKey)
    private(set) var proProduct: Product?
    private(set) var purchaseInFlight = false
    private(set) var lastError: String?

    /// Localised price string ("£2.99") once the product loads — nil before then. Exposed so
    /// the paywall never has to import StoreKit itself.
    var proPriceText: String? { proProduct?.displayPrice }

    init() {
        // Keep the entitlement current for the whole app lifetime — this store is created once
        // at the app root, so the updates stream intentionally runs until the process exits.
        Task { [weak self] in
            for await update in Transaction.updates {
                await self?.apply(update)
            }
        }
        Task { await refresh() }
    }

    /// Load the product and re-derive the current entitlement.
    func refresh() async {
        await loadProduct()
        await updateEntitlement()
    }

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.proProductID])
            proProduct = products.first
        } catch {
            lastError = "Couldn't load the Pro option — check your connection and try again."
        }
    }

    private func updateEntitlement() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.proProductID, t.revocationDate == nil {
                entitled = true
            }
        }
        isPro = entitled || previewProOn   // remove the OR with previewProOn before App Store submission
    }

    /// Kick off the purchase. Safe to call before the product exists in App Store Connect —
    /// it surfaces a friendly message instead of crashing.
    func purchasePro() async {
        guard !purchaseInFlight else { return }
        guard let product = proProduct else {
            lastError = "Pro isn't available just now — please try again shortly."
            return
        }
        purchaseInFlight = true
        lastError = nil
        defer { purchaseInFlight = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await apply(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = "That purchase didn't go through."
        }
    }

    /// Restore prior purchases — required by App Store review for non-consumables.
    func restore() async {
        try? await AppStore.sync()
        await updateEntitlement()
    }

    private func apply(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if transaction.productID == Self.proProductID, transaction.revocationDate == nil {
            isPro = true
        }
        await transaction.finish()
    }

    #if DEBUG
    /// Debug-only local override so gated surfaces stay exercisable without a sandbox account.
    func debugToggle() { isPro.toggle() }
    #endif
}
