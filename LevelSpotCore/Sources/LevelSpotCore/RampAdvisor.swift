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

/// One wheel in the multi-ramp plan: how much it must rise, and the ramp to use for it.
public struct WheelRamp: Equatable, Sendable {
    public let end: End
    public let side: Side
    public let liftMM: Int        // exact rise this wheel needs to bring the body level
    public let stepMM: Int?       // the ramp step to use, nil when the wheel needs no ramp
    public let placementCM: Int?  // run distance up the ramp to reach the lift

    public var needsRamp: Bool { stepMM != nil }
    public var wheelName: String {
        "\(end == .front ? "Front" : "Rear") \(side == .left ? "Left" : "Right")"
    }
}

/// The whole-vehicle levelling plan from ONE frozen measurement — the honest, real-world model:
/// each low wheel gets its own ramp height, and if the corner spread exceeds the tallest ramp it
/// says so plainly instead of pretending.
public struct LevelPlan: Equatable, Sendable {
    public let wheels: [WheelRamp]   // all four, in the fixed order FL, FR, RL, RR
    public let isLevel: Bool         // already level — nothing to ramp
    public let canLevel: Bool        // the tilt CAN be levelled with the ramps on hand
    public let shortfallMM: Int      // how far past the tallest ramp the tilt runs (0 when canLevel)
    public let lowEnd: End           // which end is lower — for the drive-on wording

    /// Just the wheels that actually need a ramp, low-to-high (biggest lift first).
    public var ramps: [WheelRamp] {
        wheels.filter { $0.needsRamp }.sorted { $0.liftMM > $1.liftMM }
    }
}

/// The physical family of a levelling aid — it changes both the maths and the on-vehicle flow.
public enum RampKind: String, Codable, Sendable, CaseIterable {
    case stepped      // discrete shelves — drive up to a step (Milenco Quattro, Thule, Fiamma…)
    case wedge        // smooth drive-on wedge — stop at any height (MGI Wedge)
    case blocks       // stackable blocks — build height in per-block increments (Stacka, Lynx)
    case inflatable   // air bag — inflate a wheel to an exact height (Flat-Jack, LocknLevel)
    case ratchet      // screw/ratchet leveller — wind a wheel to an exact height (Milenco Aluminium)

    public var isContinuous: Bool { self != .stepped }

    /// Types set wheel-by-wheel (each corner independently) rather than driven up onto — these
    /// use the guided per-wheel flow (pick a wheel → raise it to its target → next wheel).
    public var isPerWheel: Bool {
        switch self { case .blocks, .inflatable, .ratchet: return true; default: return false }
    }
}

/// A concrete ramp's capability — what it can actually deliver. Stepped ramps carry their shelf
/// set; continuous ramps carry a max lift (and, for blocks, the per-block increment).
public struct RampSet: Equatable, Sendable {
    public let kind: RampKind
    public let stepsMM: [Int]       // ascending shelves (stepped only; empty for continuous)
    public let maxLiftMM: Int       // continuous ceiling; for stepped == tallest shelf
    public let incrementMM: Int     // 0 = smooth; ≈ block height for stackable blocks

    public init(kind: RampKind, stepsMM: [Int], maxLiftMM: Int, incrementMM: Int) {
        self.kind = kind
        self.stepsMM = stepsMM.sorted()
        self.maxLiftMM = maxLiftMM
        self.incrementMM = incrementMM
    }

    public var isContinuous: Bool { kind.isContinuous }

    /// The tallest lift this ramp can reach — decides whether a tilt is levellable.
    public var ceilingMM: Int { kind == .stepped ? (stepsMM.max() ?? 0) : maxLiftMM }

    /// Resolve a required lift to what THIS ramp actually delivers: snap to the nearest shelf
    /// (stepped), round to the block increment (blocks), or take the exact figure clamped to the
    /// ceiling (wedge / inflatable / ratchet). nil when no ramp is warranted / possible.
    public func deliver(liftMM: Double, tolerance: Tolerance) -> Int? {
        switch kind {
        case .stepped:
            return RampAdvisor.nearestStep(deficitMM: liftMM, stepsMM: stepsMM, tolerance: tolerance)
        case .wedge, .inflatable, .ratchet:
            let clamped = min(liftMM, Double(maxLiftMM))
            return clamped >= 1 ? Int(clamped.rounded()) : nil
        case .blocks:
            let inc = Double(max(incrementMM, 1))
            let clamped = min((liftMM / inc).rounded() * inc, Double(maxLiftMM))
            return clamped >= inc / 2 ? Int(clamped.rounded()) : nil
        }
    }
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
    /// A recommendation must also STRICTLY improve the error — a step that leaves the
    /// vehicle exactly as far off (the other way) is noise dressed up as advice.
    public static func nearestStep(deficitMM: Double, stepsMM: [Int], tolerance: Tolerance) -> Int? {
        guard let smallest = stepsMM.first else { return nil }
        if deficitMM < Double(smallest) / 2 * tolerance.multiplier { return nil }
        guard let best = stepsMM.min(by: { abs(deficitMM - Double($0)) < abs(deficitMM - Double($1)) }),
              abs(deficitMM - Double(best)) < deficitMM else { return nil }
        return best
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

    /// Backwards-compatible stepped-ramp entry point (keeps existing call sites + test vectors).
    public static func plan(rollDeg: Double, pitchDeg: Double,
                            trackFrontMM: Double, trackRearMM: Double, wheelbaseMM: Double,
                            stepsMM: [Int], tolerance: Tolerance) -> LevelPlan {
        plan(rollDeg: rollDeg, pitchDeg: pitchDeg,
             trackFrontMM: trackFrontMM, trackRearMM: trackRearMM, wheelbaseMM: wheelbaseMM,
             ramp: RampSet(kind: .stepped, stepsMM: stepsMM, maxLiftMM: stepsMM.max() ?? 0, incrementMM: 0),
             tolerance: tolerance)
    }

    /// The whole-vehicle multi-ramp plan from one frozen reading, for ANY ramp type. Each corner's
    /// required lift is `highest corner − this corner`; the highest corner stays on the ground (0).
    /// Stepped ramps snap each lift to their nearest shelf; continuous ramps (wedge / blocks /
    /// inflatable / ratchet) deliver the exact lift (rounded to the block increment where relevant),
    /// so an air leveller gets a precise target instead of a step it doesn't have. The tilt is
    /// levellable when the corner SPREAD fits under the ramp's ceiling — otherwise we say so
    /// (`canLevel == false`, with the shortfall).
    public static func plan(rollDeg: Double, pitchDeg: Double,
                            trackFrontMM: Double, trackRearMM: Double, wheelbaseMM: Double,
                            ramp: RampSet, tolerance: Tolerance) -> LevelPlan {
        let c = LevelMath.cornerHeights(rollDeg: rollDeg, pitchDeg: pitchDeg,
                                        trackFrontMM: trackFrontMM, trackRearMM: trackRearMM,
                                        wheelbaseMM: wheelbaseMM)
        let corners: [(End, Side, Double)] = [
            (.front, .left, c.fl), (.front, .right, c.fr),
            (.rear, .left, c.rl), (.rear, .right, c.rr),
        ]
        let heights = corners.map { $0.2 }
        let maxH = heights.max() ?? 0
        let minH = heights.min() ?? 0
        let ceiling = ramp.ceilingMM
        let baseTol = ramp.kind == .stepped ? Double(ramp.stepsMM.min() ?? 44) / 2 : 8
        let tolMM = baseTol * tolerance.multiplier

        let wheels = corners.map { corner -> WheelRamp in
            let (end, side, h) = corner
            let lift = maxH - h
            guard lift >= tolMM else {
                return WheelRamp(end: end, side: side, liftMM: Int(lift.rounded()), stepMM: nil, placementCM: nil)
            }
            let step = ramp.deliver(liftMM: lift, tolerance: tolerance)
            return WheelRamp(end: end, side: side, liftMM: Int(lift.rounded()),
                             stepMM: step, placementCM: step.map(placementCM(forStepMM:)))
        }

        let spread = maxH - minH
        return LevelPlan(
            wheels: wheels,
            isLevel: !wheels.contains { $0.needsRamp },
            canLevel: spread <= Double(ceiling) + tolMM,
            shortfallMM: max(0, Int((spread - Double(ceiling)).rounded())),
            lowEnd: pitchDeg > 0 ? .rear : .front
        )
    }
}
