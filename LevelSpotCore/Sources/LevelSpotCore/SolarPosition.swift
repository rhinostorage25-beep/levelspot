import Foundation

/// Where the sun sits in the sky for a place + instant — pure astronomy, no network, so the
/// awning/sun planner works with zero signal like the rest of the levelling core.
///
/// `azimuthDeg` is a compass bearing (0 = north, 90 = east, 180 = south, 270 = west);
/// `elevationDeg` is degrees above the horizon (negative = the sun is down). Based on the NOAA
/// solar-position equations; accuracy is well within what pitch planning needs (~0.1–0.5°).
/// Cross-platform contract like the levelling maths — the Kotlin port must match these vectors.
public struct SunPosition: Equatable, Sendable {
    public let azimuthDeg: Double
    public let elevationDeg: Double
    public var isUp: Bool { elevationDeg > 0 }

    public init(azimuthDeg: Double, elevationDeg: Double) {
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
    }
}

/// Whether the camper wants the awning in the sun or in shade — the temperature auto-flip
/// (a later, network-backed step) just sets this for the user.
public enum SunPreference: String, Codable, Sendable, CaseIterable { case sun, shade }

public enum SolarPosition {
    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Sun azimuth + elevation for a coordinate at an instant. `longitude` is east-positive.
    public static func at(latitude: Double, longitude: Double, date: Date) -> SunPosition {
        let unix = date.timeIntervalSince1970
        let jd = unix / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545.0) / 36_525.0

        let l0 = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
              + sin(rad(2 * m)) * (0.019993 - 0.000101 * t)
              + sin(rad(3 * m)) * 0.000289
        let trueLong = l0 + c
        let appLong = trueLong - 0.00569 - 0.00478 * sin(rad(125.04 - 1_934.136 * t))
        let meanObliq = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliqCorr = meanObliq + 0.00256 * cos(rad(125.04 - 1_934.136 * t))
        let declin = deg(asin(sin(rad(obliqCorr)) * sin(rad(appLong))))

        let varY = tan(rad(obliqCorr / 2)) * tan(rad(obliqCorr / 2))
        let eqTime = 4 * deg(varY * sin(2 * rad(l0))
                             - 2 * e * sin(rad(m))
                             + 4 * e * varY * sin(rad(m)) * cos(2 * rad(l0))
                             - 0.5 * varY * varY * sin(4 * rad(l0))
                             - 1.25 * e * e * sin(2 * rad(m)))

        let minutesUTC = unix.truncatingRemainder(dividingBy: 86_400) / 60
        var trueSolarTime = (minutesUTC + eqTime + 4 * longitude).truncatingRemainder(dividingBy: 1_440)
        if trueSolarTime < 0 { trueSolarTime += 1_440 }
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let latR = rad(latitude)
        let declR = rad(declin)
        let zenith = deg(acos(sin(latR) * sin(declR) + cos(latR) * cos(declR) * cos(rad(hourAngle))))
        let elevation = 90 - zenith

        // Azimuth measured clockwise from north (NOAA convention).
        let denom = cos(latR) * sin(rad(zenith))
        var azimuth: Double
        if abs(denom) < 1e-9 {
            azimuth = elevation > 0 ? 180 : 0    // sun straight overhead / straight down
        } else {
            let cosAz = min(max((sin(latR) * cos(rad(zenith)) - sin(declR)) / denom, -1), 1)
            let base = deg(acos(cosAz))
            azimuth = hourAngle > 0 ? (base + 180).truncatingRemainder(dividingBy: 360)
                                    : (540 - base).truncatingRemainder(dividingBy: 360)
        }
        if azimuth < 0 { azimuth += 360 }
        return SunPosition(azimuthDeg: azimuth, elevationDeg: elevation)
    }

    /// The van heading (compass deg) that puts the awning toward the sun (`.sun`) or away from
    /// it (`.shade`). `awningOffsetDeg` is the awning's bearing relative to the van's nose:
    /// front 0, rear 180, right +90, left −90.
    public static func vanHeadingForAwning(sunAzimuthDeg: Double, awningOffsetDeg: Double,
                                           preference: SunPreference) -> Double {
        let targetAwningBearing = preference == .sun ? sunAzimuthDeg : sunAzimuthDeg + 180
        var heading = (targetAwningBearing - awningOffsetDeg).truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }
        return heading
    }
}
