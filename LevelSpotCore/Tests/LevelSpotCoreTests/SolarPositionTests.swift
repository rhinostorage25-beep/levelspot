import XCTest
@testable import LevelSpotCore

/// Sun-position vectors. The awning-heading maths is plain arithmetic → exact. The sun position
/// itself can't be hand-derived to two decimals, so these assert the physically-necessary facts
/// (sun high & south at summer noon, east in the morning, west in the evening, low in winter) —
/// wide enough to survive rounding, tight enough to catch the real mistakes (azimuth flipped
/// 180°, elevation sign wrong, day/night confusion). London is the reference site.
final class SolarPositionTests: XCTestCase {
    private let londonLat = 51.5074
    private let londonLon = -0.1278

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return cal.date(from: c)!
    }

    // S1: London, summer solstice, ~solar noon — sun high (~62°) and due south (~180°).
    func testS1SummerNoonHighAndSouth() {
        let p = SolarPosition.at(latitude: londonLat, longitude: londonLon, date: utc(2025, 6, 21, 12, 0))
        XCTAssertGreaterThan(p.elevationDeg, 58)
        XCTAssertLessThan(p.elevationDeg, 64)
        XCTAssertGreaterThan(p.azimuthDeg, 165)
        XCTAssertLessThan(p.azimuthDeg, 195)
    }

    // S2: summer morning — sun up in the east.
    func testS2SummerMorningEast() {
        let p = SolarPosition.at(latitude: londonLat, longitude: londonLon, date: utc(2025, 6, 21, 5, 30))
        XCTAssertGreaterThan(p.elevationDeg, 3)
        XCTAssertGreaterThan(p.azimuthDeg, 50)
        XCTAssertLessThan(p.azimuthDeg, 100)
    }

    // S3: summer evening — sun up in the west (the sundowner window).
    func testS3SummerEveningWest() {
        let p = SolarPosition.at(latitude: londonLat, longitude: londonLon, date: utc(2025, 6, 21, 18, 30))
        XCTAssertGreaterThan(p.elevationDeg, 3)
        XCTAssertGreaterThan(p.azimuthDeg, 270)
        XCTAssertLessThan(p.azimuthDeg, 315)
    }

    // S4: winter solstice noon — sun scrapes low (~15°), far below the summer figure.
    func testS4WinterNoonLow() {
        let p = SolarPosition.at(latitude: londonLat, longitude: londonLon, date: utc(2025, 12, 21, 12, 0))
        XCTAssertGreaterThan(p.elevationDeg, 11)
        XCTAssertLessThan(p.elevationDeg, 19)
    }

    // S5: night — sun below the horizon.
    func testS5NightSunDown() {
        let p = SolarPosition.at(latitude: londonLat, longitude: londonLon, date: utc(2025, 6, 21, 1, 0))
        XCTAssertLessThan(p.elevationDeg, 0)
        XCTAssertFalse(p.isUp)
    }

    // S6: awning heading — exact arithmetic. Sun in the west (270°).
    func testS6AwningHeadingExact() {
        // Front awning toward the sun → nose points at the sun.
        XCTAssertEqual(SolarPosition.vanHeadingForAwning(sunAzimuthDeg: 270, awningOffsetDeg: 0, preference: .sun), 270, accuracy: 0.001)
        // Front awning for shade → nose points away.
        XCTAssertEqual(SolarPosition.vanHeadingForAwning(sunAzimuthDeg: 270, awningOffsetDeg: 0, preference: .shade), 90, accuracy: 0.001)
        // Rear awning toward the sun → tail at the sun, so nose faces east.
        XCTAssertEqual(SolarPosition.vanHeadingForAwning(sunAzimuthDeg: 270, awningOffsetDeg: 180, preference: .sun), 90, accuracy: 0.001)
        // Left/passenger awning toward the sun → van heading wraps to 0 (north).
        XCTAssertEqual(SolarPosition.vanHeadingForAwning(sunAzimuthDeg: 270, awningOffsetDeg: -90, preference: .sun), 0, accuracy: 0.001)
        // Right/driver awning for shade, sun in the east (100°).
        XCTAssertEqual(SolarPosition.vanHeadingForAwning(sunAzimuthDeg: 100, awningOffsetDeg: 90, preference: .shade), 190, accuracy: 0.001)
    }
}
