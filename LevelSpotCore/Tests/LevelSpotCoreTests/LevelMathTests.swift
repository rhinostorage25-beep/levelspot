import XCTest
@testable import LevelSpotCore

/// These vectors are the cross-platform contract. They were generated and verified by an
/// independent JavaScript implementation of the same formulas (scripts kept alongside the
/// repo docs); the Kotlin port must pass these exact numbers too. Do not change an expected
/// value without re-deriving it in the mirror harness first.
final class LevelMathTests: XCTestCase {
    let defaultSteps = [44, 78, 112]
    let milenco = [40, 110, 170]

    // V1: typical side slope on a Ducato — roll 2.86°, track 1790 -> 89.42mm -> step 78 @ 18cm
    func testV1TypicalSideSlope() {
        let deficit = LevelMath.lateralDeficitMM(rollDeg: 2.86, trackMM: 1790)
        XCTAssertEqual(deficit, 89.42, accuracy: 0.01)
        let advice = RampAdvisor.advise(rollDeg: 2.86, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertEqual(advice.wheel?.wheelName, "Front Right")
        XCTAssertEqual(advice.wheel?.stepMM, 78)
        XCTAssertEqual(advice.wheel?.placementCM, 18)
        XCTAssertNil(advice.longStepMM)
    }

    // V2: nearly level — roll 0.30° -> no ramp
    func testV2NearlyLevel() {
        let advice = RampAdvisor.advise(rollDeg: 0.30, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertNil(advice.wheel)
        XCTAssertTrue(advice.isLevel)
    }

    // V3: a 45mm deficit is "level" for the fridge, a 44mm step for comfort and precise
    func testV3ToleranceBands() {
        let roll = atan(45.0 / 1790.0) * 180 / .pi
        XCTAssertNil(RampAdvisor.advise(rollDeg: roll, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: defaultSteps, tolerance: .fridge).wheel)
        XCTAssertEqual(RampAdvisor.advise(rollDeg: roll, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                          stepsMM: defaultSteps, tolerance: .comfort).wheel?.stepMM, 44)
        XCTAssertEqual(RampAdvisor.advise(rollDeg: roll, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                          stepsMM: defaultSteps, tolerance: .precise).wheel?.stepMM, 44)
    }

    // V4: pitch-only — 1.2° nose-down on wb 3450 -> 72.27mm -> step 78 under the front pair
    func testV4PitchOnly() {
        let deficit = LevelMath.longitudinalDeficitMM(pitchDeg: -1.2, wheelbaseMM: 3450)
        XCTAssertEqual(deficit, 72.27, accuracy: 0.01)
        let advice = RampAdvisor.advise(rollDeg: 0, pitchDeg: -1.2, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertNil(advice.wheel)
        XCTAssertEqual(advice.lowEnd, .front)
        XCTAssertEqual(advice.longStepMM, 78)
        XCTAssertEqual(advice.longPlacementCM, 18)
    }

    // V5: corner heights, roll 1° pitch 0.5°, track 1800 wb 3000 — planarity fl+rr == fr+rl
    func testV5CornerHeights() {
        let c = LevelMath.cornerHeights(rollDeg: 1, pitchDeg: 0.5, trackMM: 1800, wheelbaseMM: 3000)
        XCTAssertEqual(c.fl, 28.80, accuracy: 0.01)
        XCTAssertEqual(c.fr, -2.62, accuracy: 0.01)
        XCTAssertEqual(c.rl, 2.62, accuracy: 0.01)
        XCTAssertEqual(c.rr, -28.80, accuracy: 0.01)
        XCTAssertEqual(c.fl + c.rr, c.fr + c.rl, accuracy: 0.0001)
    }

    // V6: the Milenco profile snaps the same 89.42mm deficit to 110, not 40
    func testV6MilencoSnap() {
        let advice = RampAdvisor.advise(rollDeg: 2.86, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: milenco, tolerance: .comfort)
        XCTAssertEqual(advice.wheel?.stepMM, 110)
    }

    // V7: naming — roll negative = left low; pitch positive = front high -> rear low
    func testV7WheelNaming() {
        let advice = RampAdvisor.advise(rollDeg: -2.86, pitchDeg: 1.0, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertEqual(advice.wheel?.wheelName, "Rear Left")
    }

    // V8: the AL-KO question matters — same 1.9° roll, different step on the wide rear track.
    func testV8AlkoTrackChangesRecommendation() {
        let standard = RampAdvisor.advise(rollDeg: 1.9, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                          stepsMM: defaultSteps, tolerance: .comfort)
        let alko = RampAdvisor.advise(rollDeg: 1.9, pitchDeg: 0, trackMM: 1980, wheelbaseMM: 3450,
                                      stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertEqual(standard.wheel?.stepMM, 44)
        XCTAssertEqual(alko.wheel?.stepMM, 78)
    }

    // V9: an extreme tilt is honest, not a silent clamp. 40° nose-up over wb 3450 needs ~2.9m
    // of lift under the rear — no ramp does that. The old code snapped it to the 112mm step and
    // showed "112mm · 26cm out" (the reported #6 bug). Now longStep is suppressed and flagged.
    func testV9BeyondRampRangeLongitudinal() {
        let advice = RampAdvisor.advise(rollDeg: 0, pitchDeg: 40, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertTrue(advice.longBeyondRamp)
        XCTAssertTrue(advice.beyondRamp)
        XCTAssertNil(advice.longStepMM)      // NOT clamped to 112
        XCTAssertNil(advice.longPlacementCM)
        XCTAssertFalse(advice.isLevel)       // a 40° van is emphatically not level
    }

    // V10: the boundary holds — a big-but-rampable deficit still snaps to the top step. 150mm on
    // track 1790 (roll ~4.79°) is under the 1.5×112 = 168mm ceiling, so it's a 112mm ramp, not
    // "beyond range". Guards the threshold against creeping down onto legitimate steep pitches.
    func testV10LargeButRampableStillSnaps() {
        let roll = atan(150.0 / 1790.0) * 180 / .pi
        let advice = RampAdvisor.advise(rollDeg: roll, pitchDeg: 0, trackMM: 1790, wheelbaseMM: 3450,
                                        stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertFalse(advice.lateralBeyondRamp)
        XCTAssertEqual(advice.wheel?.stepMM, 112)
    }

    // P1: multi-ramp plan — pure roll ramps BOTH wheels on the low (right) side by the same step.
    func testP1PureRollRampsBothLowSideWheels() {
        let plan = RampAdvisor.plan(rollDeg: 2.86, pitchDeg: 0, trackFrontMM: 1790, trackRearMM: 1790,
                                    wheelbaseMM: 3450, stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertFalse(plan.isLevel)
        XCTAssertTrue(plan.canLevel)
        XCTAssertEqual(Set(plan.ramps.map(\.wheelName)), ["Front Right", "Rear Right"])
        XCTAssertTrue(plan.ramps.allSatisfy { $0.stepMM == 78 })
    }

    // P2: near-level → no ramps at all.
    func testP2LevelPlanHasNoRamps() {
        let plan = RampAdvisor.plan(rollDeg: 0.3, pitchDeg: 0, trackFrontMM: 1790, trackRearMM: 1790,
                                    wheelbaseMM: 3450, stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertTrue(plan.isLevel)
        XCTAssertTrue(plan.ramps.isEmpty)
    }

    // P3: honest "can't level here" — 5° roll spreads the corners 157mm, past the 112mm tallest ramp.
    func testP3CannotLevelBeyondTallestRamp() {
        let plan = RampAdvisor.plan(rollDeg: 5, pitchDeg: 0, trackFrontMM: 1790, trackRearMM: 1790,
                                    wheelbaseMM: 3450, stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertFalse(plan.canLevel)
        XCTAssertEqual(plan.shortfallMM, 45)
    }

    // P4: roll + pitch → three wheels ramped, each a different height (the highest corner stays down).
    func testP4RollAndPitchRampsThreeWheels() {
        let plan = RampAdvisor.plan(rollDeg: -2, pitchDeg: 1, trackFrontMM: 1790, trackRearMM: 1790,
                                    wheelbaseMM: 3450, stepsMM: defaultSteps, tolerance: .comfort)
        XCTAssertEqual(plan.ramps.count, 3)
        XCTAssertEqual(Set(plan.ramps.map(\.wheelName)), ["Front Left", "Rear Left", "Rear Right"])
    }

    // P5: a continuous inflatable levels the SAME 5° roll P3 couldn't (200mm ceiling > 157mm spread)
    // and delivers the EXACT lift, not a snapped step.
    func testP5InflatableLevelsBeyondSteppedRange() {
        let air = RampSet(kind: .inflatable, stepsMM: [], maxLiftMM: 200, incrementMM: 0)
        let plan = RampAdvisor.plan(rollDeg: 5, pitchDeg: 0, trackFrontMM: 1790, trackRearMM: 1790,
                                    wheelbaseMM: 3450, ramp: air, tolerance: .comfort)
        XCTAssertTrue(plan.canLevel)
        XCTAssertEqual(plan.ramps.count, 2)
        XCTAssertTrue(plan.ramps.allSatisfy { $0.stepMM == $0.liftMM })   // exact, not snapped to a shelf
    }

    // P6: stackable blocks round each wheel's target to the block increment (40mm here).
    func testP6BlocksRoundToIncrement() {
        let blocks = RampSet(kind: .blocks, stepsMM: [], maxLiftMM: 200, incrementMM: 40)
        let plan = RampAdvisor.plan(rollDeg: 5, pitchDeg: 0, trackFrontMM: 1790, trackRearMM: 1790,
                                    wheelbaseMM: 3450, ramp: blocks, tolerance: .comfort)
        XCTAssertTrue(plan.canLevel)
        XCTAssertTrue(plan.ramps.allSatisfy { ($0.stepMM ?? 0) % 40 == 0 })
    }
}
