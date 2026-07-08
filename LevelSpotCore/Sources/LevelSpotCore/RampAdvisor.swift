import Foundation

/// User-facing precision setting. Fridges run fine well before "guest-comfortable" level,
/// so the thresholds differ; Comfort is the default and the free-tier behaviour.
public enum Tolerance: String, CaseIterable, Codable, Sendable {
    case fridge, comfort, precise

    public var multiplier: Double {
        switch self {
        case .fridge: return 2.4
        case .comfort: return 1.0
        case .precise: return 0.4
        }
    }

    public var label: String {
        switch self {
        case .fridge: return "Fridge"
        case .comfort: return "Comfort"
        case .precise: return "Precise"
        }
    }
}

public enum Side: String, Codable, Sendable { case left, right }
public enum End: String, Codable, Sendable { case front, rear }

/// One concrete instruction: which wheel, which step, where to start the ramp.
public struct RampInstruction: Equatable, Sendable {
    public let end: End
    public let side: Side
    public let stepMM: Int
    public let placementCM: Int

    /// e.g. "Front Right" — left/right wheel naming is unambiguous in every market;
    /// driver/passenger is reserved for the living-side setting, and nearside/offside
    /// is banned throughout the codebase.
    public var wheelName: String {
        "\(end == .front ? "Front" : "Rear") \(side == .left ? "Left" : "Right")"
    }
}

public struct Advice: Equatable, Sendable {
    /// Primary instruction — the single wheel to ramp for the dominant (side-to-side) error.
    public let wheel: RampInstruction?
    /// Secondary — the axle-pair correction for residual front-to-back, surfaced once
    /// side-to-side is sorted. Pair semantics: both wheels of the low end.
    public let lowEnd: End?
    public let longStepMM: Int?
    public let longPlacementCM: Int?
    /// The tilt is so severe on this axis that no ramp in the set can bring it level — the
    /// honest "reposition the van" case, NOT a silent clamp to the biggest step (the bug the
    /// old code had: a 40° reading snapped to the max step and pretended it solved it).
    /// When a side is beyond range its normal instruction is suppressed (wheel / longStep nil).
    public let lateralBeyondRamp: Bool
    public let longBeyondRamp: Bool
    public var beyondRamp: Bool { lateralBeyondRamp || longBeyondRamp }
    public var isLevel: Bool { wheel == nil && longStepMM == nil && !beyondRamp }
}

public enum RampAdvisor {
    /// Default wedge slope: 4.3mm of rise per cm of run along the ramp. Used when the
    /// profile has no per-step placement data of its own (brand profiles can override later).
    public static let defaultSlopeMMPerCM = 4.3

    public static func placementCM(forStepMM step: Int) -> Int {
        Int((Double(step) / defaultSlopeMMPerCM).rounded())
    }

    /// Snap a deficit to the nearest real step a physical ramp offers — never an arbitrary
    /// figure nothing can deliver. Returns nil ("level enough") when the deficit is under
    /// half the smallest step scaled by tolerance: below that, no ramp can improve things.
    public static func nearestStep(deficitMM: Double, stepsMM: [Int], tolerance: Tolerance) -> Int? {
        guard let smallest = stepsMM.first else { return nil }
        if deficitMM < Double(smallest) / 2 * tolerance.multiplier { return nil }
        return stepsMM.min(by: { abs(deficitMM - Double($0)) < abs(deficitMM - Double($1)) })
    }

    /// True when the deficit runs so far past the biggest available step that snapping to it
    /// would leave the vehicle badly out — i.e. no ramp can fix this and the honest answer is
    /// "reposition." The 1.5× margin means the largest step must land you within half a step
    /// of level to still count as rampable.
    public static func exceedsRampRange(deficitMM: Double, stepsMM: [Int]) -> Bool {
        guard let largest = stepsMM.max() else { return false }
        return deficitMM > Double(largest) * 1.5
    }

    /// Full recommendation from one attitude reading + the vehicle's known dimensions.
    /// `stepsMM` must be ascending. Track here is the RELEVANT track — the caller passes the
    /// rear track for AL-KO-style chassis where rear differs from front (the difference is
    /// large enough to change the answer; see the chassis-type question in Setup).
    public static func advise(rollDeg: Double, pitchDeg: Double,
                              trackMM: Double, wheelbaseMM: Double,
                              stepsMM: [Int], tolerance: Tolerance) -> Advice {
        let lateral = LevelMath.lateralDeficitMM(rollDeg: rollDeg, trackMM: trackMM)
        let longitudinal = LevelMath.longitudinalDeficitMM(pitchDeg: pitchDeg, wheelbaseMM: wheelbaseMM)
        let lowSide: Side = rollDeg > 0 ? .right : .left      // roll>0 = left high
        let lowEnd: End = pitchDeg > 0 ? .rear : .front       // pitch>0 = front high

        // Beyond range = un-rampable. Suppress the normal instruction so the UI shows the
        // honest "reposition" state instead of a max-step figure that doesn't actually level it.
        let lateralBeyond = abs(rollDeg) > 0.001 && exceedsRampRange(deficitMM: lateral, stepsMM: stepsMM)
        let longBeyond = abs(pitchDeg) > 0.001 && exceedsRampRange(deficitMM: longitudinal, stepsMM: stepsMM)

        var wheel: RampInstruction?
        if !lateralBeyond, abs(rollDeg) > 0.001,
           let step = nearestStep(deficitMM: lateral, stepsMM: stepsMM, tolerance: tolerance) {
            wheel = RampInstruction(end: lowEnd, side: lowSide, stepMM: step,
                                    placementCM: placementCM(forStepMM: step))
        }

        var longStep: Int?
        if !longBeyond, abs(pitchDeg) > 0.001 {
            longStep = nearestStep(deficitMM: longitudinal, stepsMM: stepsMM, tolerance: tolerance)
        }

        return Advice(
            wheel: wheel,
            lowEnd: longStep != nil ? lowEnd : nil,
            longStepMM: longStep,
            longPlacementCM: longStep.map(placementCM(forStepMM:)),
            lateralBeyondRamp: lateralBeyond,
            longBeyondRamp: longBeyond
        )
    }
}
