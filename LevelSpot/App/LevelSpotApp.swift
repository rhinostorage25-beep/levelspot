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

    var body: some View {
        NavigationStack {
            if configs.isEmpty {
                VehicleSetupView()
            } else {
                LevelScanView(config: configs[0])
            }
        }
    }
}
