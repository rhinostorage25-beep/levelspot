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
}
