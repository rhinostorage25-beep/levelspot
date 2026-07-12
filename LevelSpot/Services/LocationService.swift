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
        manager.headingFilter = kCLHeadingFilterNone   // report every change so the sun tracks smoothly as you turn
    }

    func requestAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            authorized = true
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        default:
            authorized = false
        }
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
