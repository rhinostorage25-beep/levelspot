import Foundation

/// Corner heights in mm relative to the vehicle centroid, derived from ONE attitude reading.
/// The vehicle body is rigid, so a single tilt reading plus wheelbase and track mathematically
/// determines all four corners — no per-wheel hardware exists or is needed.
///
/// Sign conventions (documented once, used everywhere — including the Kotlin port):
///   roll  > 0  =>  LEFT side high (left/right as seen facing the vehicle's front)
///   pitch > 0  =>  FRONT high
public struct CornerHeights: Equatable, Sendable {
    public let fl: Double
    public let fr: Double
    public let rl: Double
    public let rr: Double

    public init(fl: Double, fr: Double, rl: Double, rr: Double) {
        self.fl = fl; self.fr = fr; self.rl = rl; self.rr = rr
    }
}

public enum LevelMath {
    /// Rigid-plane corner heights. Planarity invariant: fl + rr == fr + rl.
    public static func cornerHeights(rollDeg: Double, pitchDeg: Double,
                                     trackMM: Double, wheelbaseMM: Double) -> CornerHeights {
        let halfRoll = trackMM * tan(rollDeg * .pi / 180) / 2
        let halfPitch = wheelbaseMM * tan(pitchDeg * .pi / 180) / 2
        return CornerHeights(
            fl: halfPitch + halfRoll,
            fr: halfPitch - halfRoll,
            rl: -halfPitch + halfRoll,
            rr: -halfPitch - halfRoll
        )
    }

    /// Per-corner heights using the ACTUAL front and rear tracks (they differ on AL-KO chassis),
    /// so the per-wheel ramp plan is exact rather than assuming one track for both axles.
    public static func cornerHeights(rollDeg: Double, pitchDeg: Double,
                                     trackFrontMM: Double, trackRearMM: Double,
                                     wheelbaseMM: Double) -> CornerHeights {
        let halfPitch = wheelbaseMM * tan(pitchDeg * .pi / 180) / 2
        let frontRoll = trackFrontMM * tan(rollDeg * .pi / 180) / 2
        let rearRoll = trackRearMM * tan(rollDeg * .pi / 180) / 2
        return CornerHeights(
            fl: halfPitch + frontRoll,
            fr: halfPitch - frontRoll,
            rl: -halfPitch + rearRoll,
            rr: -halfPitch - rearRoll
        )
    }

    /// Height deficit (mm) of the low side across an axle for a given roll.
    public static func lateralDeficitMM(rollDeg: Double, trackMM: Double) -> Double {
        trackMM * tan(abs(rollDeg) * .pi / 180)
    }

    /// Height deficit (mm) of the low end along the wheelbase for a given pitch.
    public static func longitudinalDeficitMM(pitchDeg: Double, wheelbaseMM: Double) -> Double {
        wheelbaseMM * tan(abs(pitchDeg) * .pi / 180)
    }
}
