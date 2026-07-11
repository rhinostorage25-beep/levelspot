import Foundation
import SwiftData
import LevelSpotCore

/// Which side you sit out on / the awning is. Plain Left/Right (not driver/passenger, which flip
/// meaning between LHD and RHD markets) — unambiguous everywhere, and simpler for users.
enum LivingSide: String, Codable, CaseIterable {
    case front, left, rear, right

    var label: String {
        switch self {
        case .front: return "Front"
        case .left: return "Left"
        case .rear: return "Rear"
        case .right: return "Right"
        }
    }

    /// The awning/living side as a bearing offset from the van's nose — front 0, rear 180,
    /// right +90, left −90 — used by the sun/shade planner.
    var awningOffsetDeg: Double {
        switch self {
        case .front: return 0
        case .rear: return 180
        case .right: return 90
        case .left: return -90
        }
    }
}

/// Answer to the Setup chassis question. `.measured` is the resolved form of "Not sure" —
/// by the time setup completes, a Not-sure user has entered a real figure.
enum ChassisKind: String, Codable {
    case standard, alko, measured
}

@Model
final class VehicleConfig {
    var presetId: String?          // one of the six Setup presets, nil for manual entry
    var genId: String?             // resolved vehicle_generations row, nil for manual
    var displayName: String
    var wheelbaseMM: Int
    var trackFrontMM: Int
    var trackRearMM: Int
    var chassisKindRaw: String
    var livingSideRaw: String
    var rampProfileId: String
    var customStepsMM: [Int]
    /// True whenever dimensions came from the preset table rather than the user's own
    /// measurements — every calculated result on screen must then carry the ESTIMATED tag.
    var usingTypicalDims: Bool
    var spareDeviceName: String?   // set once a spare device is paired & calibrated
    var updatedAt: Date

    var chassisKind: ChassisKind { ChassisKind(rawValue: chassisKindRaw) ?? .standard }
    var livingSide: LivingSide { LivingSide(rawValue: livingSideRaw) ?? .front }

    init(presetId: String?, genId: String?, displayName: String,
         wheelbaseMM: Int, trackFrontMM: Int, trackRearMM: Int,
         chassisKind: ChassisKind, livingSide: LivingSide,
         rampProfileId: String, customStepsMM: [Int], usingTypicalDims: Bool) {
        self.presetId = presetId
        self.genId = genId
        self.displayName = displayName
        self.wheelbaseMM = wheelbaseMM
        self.trackFrontMM = trackFrontMM
        self.trackRearMM = trackRearMM
        self.chassisKindRaw = chassisKind.rawValue
        self.livingSideRaw = livingSide.rawValue
        self.rampProfileId = rampProfileId
        self.customStepsMM = customStepsMM
        self.usingTypicalDims = usingTypicalDims
        self.spareDeviceName = nil
        self.updatedAt = .now
    }

    /// Ascending step heights for the active ramp profile (stepped ramps only — kept for the
    /// custom-steps editor and any stepped-specific display).
    var activeStepsMM: [Int] {
        if rampProfileId == "custom" { return customStepsMM.filter { $0 > 0 }.sorted() }
        return ReferenceStore.shared.rampProfile(id: rampProfileId)?.stepsMm.sorted() ?? [44, 78, 112]
    }

    /// The full ramp capability (type + heights) driving the levelling maths and the on-vehicle flow.
    var activeRampSet: RampSet {
        if rampProfileId == "custom" {
            let s = customStepsMM.filter { $0 > 0 }.sorted()
            return RampSet(kind: .stepped, stepsMM: s, maxLiftMM: s.max() ?? 0, incrementMM: 0)
        }
        return ReferenceStore.shared.rampProfile(id: rampProfileId)?.rampSet
            ?? RampSet(kind: .stepped, stepsMM: [44, 78, 112], maxLiftMM: 112, incrementMM: 0)
    }
}

@Model
final class PitchRecord {
    var id: UUID
    var latitude: Double
    var longitude: Double
    var levelHeading: Int?
    var cornerFLmm: Double
    var cornerFRmm: Double
    var cornerRLmm: Double
    var cornerRRmm: Double
    var rating: Int
    var sunHeading: Int?     // Pro data; server-side RLS re-enforces gating on sync
    var viewHeading: Int?
    var siteName: String
    var visitedAt: Date
    var synced: Bool

    init(latitude: Double, longitude: Double, levelHeading: Int?,
         corners: (fl: Double, fr: Double, rl: Double, rr: Double),
         rating: Int, siteName: String) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.levelHeading = levelHeading
        self.cornerFLmm = corners.fl
        self.cornerFRmm = corners.fr
        self.cornerRLmm = corners.rl
        self.cornerRRmm = corners.rr
        self.rating = rating
        self.sunHeading = nil
        self.viewHeading = nil
        self.siteName = siteName
        self.visitedAt = .now
        self.synced = false
    }

    /// Metres between this pitch and a coordinate — local haversine so the arrival match
    /// works with zero connectivity (PostGIS does the same job server-side once synced).
    func distanceM(latitude lat: Double, longitude lon: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat - latitude) * .pi / 180
        let dLon = (lon - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
