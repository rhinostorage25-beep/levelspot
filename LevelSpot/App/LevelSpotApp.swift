import SwiftUI
import SwiftData

@main
struct LevelSpotApp: App {
    // Local-first storage: the scan, history and setup all work with zero connectivity.
    // Supabase only ever enters the picture for the reg lookup and (later) signed-in sync.
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: VehicleConfig.self, PitchRecord.self)
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }()

    @State private var motion = MotionService()
    @State private var location = LocationService()
    @State private var connectivity = ConnectivityMonitor()
    @State private var entitlements = EntitlementStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(motion)
                .environment(location)
                .environment(connectivity)
                .environment(entitlements)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Query private var configs: [VehicleConfig]
    // Chosen in the setup wizard's language step. Drives the app locale; once the app is localised
    // (DE/FR/IT/ES/NL) this switches the strings. English-only for now, but the wiring is live.
    @AppStorage("appLanguageCode") private var languageCode = "en"

    var body: some View {
        // Always open to the Level dial. Free users need no setup at all; Pro users who haven't
        // set their van up yet get a "Set up your van" prompt on the dial (config == nil here).
        NavigationStack {
            LevelScanView(config: configs.first)
        }
        .environment(\.locale, Locale(identifier: languageCode))
    }
}
