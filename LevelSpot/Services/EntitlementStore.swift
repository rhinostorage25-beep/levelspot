import Foundation
import Observation

/// Free/Pro entitlement. v1 wiring: local flag with a debug unlock so every gated surface is
/// exercisable. Real purchase flow is StoreKit 2 (`Product.purchase()`, `Transaction
/// .currentEntitlements`) verified server-side into user_entitlements — the data layer's RLS
/// (see supabase/migrations/001_schema.sql) is what actually enforces Pro on synced data, so
/// tampering with this client flag never exposes another tier's server data.
@Observable
final class EntitlementStore {
    private(set) var isPro: Bool = UserDefaults.standard.bool(forKey: "entitlement.isPro")

    /// Placeholder purchase: flips the local flag so the unlocked UI is demonstrable.
    /// Replace body with StoreKit 2 purchase + server receipt verification before release.
    func purchasePro() {
        isPro = true
        UserDefaults.standard.set(true, forKey: "entitlement.isPro")
    }

    #if DEBUG
    func debugToggle() {
        isPro.toggle()
        UserDefaults.standard.set(isPro, forKey: "entitlement.isPro")
    }
    #endif
}
