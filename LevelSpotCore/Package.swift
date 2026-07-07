// swift-tools-version: 5.9
// LevelSpotCore — the platform-neutral heart of LevelSpot: levelling geometry, ramp-step
// snapping, tolerance rules. NO UIKit/SwiftUI imports allowed in this package, ever — it is
// the written spec the Android (Kotlin) port will be transliterated from, test vectors and all.
import PackageDescription

let package = Package(
    name: "LevelSpotCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "LevelSpotCore", targets: ["LevelSpotCore"])
    ],
    targets: [
        .target(name: "LevelSpotCore"),
        .testTarget(name: "LevelSpotCoreTests", dependencies: ["LevelSpotCore"]),
    ]
)
