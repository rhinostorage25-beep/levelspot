import Foundation
import CoreLocation
import Network
import Observation

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var latitude: Double?
    private(set) var longitude: Double?
    private(set) var headingDeg: Int?
    private(set) var authorized = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // 2° steps: still perfectly smooth to steer a van by, but doesn't spam the UI with
        // sub-degree jitter — every heading write re-renders the whole Level screen.
        manager.headingFilter = 2
    }

    /// Without this, an uncalibrated compass NEVER produces a valid heading and iOS never shows
    /// its figure-8 prompt — the sun planner would sit on "finding your position" forever.
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }

    func requestAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            authorized = true
            manager.startUpdatingLocation()
        default:
            authorized = false
        }
    }

    /// Heading (compass) runs ONLY while the sun planner is engaged — that's when the user is
    /// holding the phone (so iOS's figure-8 calibration prompt is actionable, not an ambush
    /// over the dial mid-levelling), and the compass hardware stays off the rest of the time.
    func startHeading() {
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stopHeading() {
        manager.stopUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // This delegate fires on manager CREATION (app launch) with .notDetermined. Asking for
        // permission there would prompt every fresh install at first open — free users must
        // never see a location prompt (funnel-flip contract). Only react to real grants/denials;
        // the ask itself happens solely via an explicit requestAndStart() (Pro surfaces).
        guard manager.authorizationStatus != .notDetermined else { return }
        requestAndStart()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // Deadband ~11m: a parked van doesn't need per-second coordinate writes re-rendering
        // the UI; sun position and pitch recall are insensitive at this scale.
        if let lat = latitude, let lon = longitude,
           abs(loc.coordinate.latitude - lat) < 0.0001, abs(loc.coordinate.longitude - lon) < 0.0001 {
            return
        }
        latitude = loc.coordinate.latitude
        longitude = loc.coordinate.longitude
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Prefer true north, but fall back to magnetic — trueHeading is -1 until iOS has a
        // location fix and a calibrated compass, and without the fallback the heading (and the
        // sun-planner compass) would sit at nil forever. Magnetic is within ~1° in the UK.
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        if heading >= 0 { headingDeg = Int(heading.rounded()) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Poor GPS at a remote pitch is an expected state, not an error path.
    }
}

/// Connectivity drives copy only ("No signal — showing your saved pitch data"), never a
/// spinner and never a gate on the core scan.
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.isOnline = (path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "levelspot.connectivity"))
    }
}
