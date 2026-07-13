import Foundation
import CoreLocation
import WeatherKit
import UserNotifications
import Observation

/// Awning wind alerts (Pro): watches the next 24h of forecast GUSTS at the pitch and warns
/// before they get awning-threatening — in app (capsule under the dial) and as a local
/// notification scheduled ahead of the peak. Silence is a feature: below threshold, or on
/// any failure (no entitlement, no network), nothing shows and nothing nags.
@MainActor
@Observable
final class WindService {
    /// Typical cassette-awning guidance: retract by ~25 mph gusts; 38+ is get-it-in-now.
    static let warnMPH = 25.0
    static let severeMPH = 38.0

    struct WindWarning: Equatable {
        let peakMPH: Int
        let at: Date

        var severe: Bool { Double(peakMPH) >= WindService.severeMPH }
        var timeLabel: String { at.formatted(date: .omitted, time: .shortened) }
    }

    /// The current warning, or nil when the forecast is calm / unknown. UI shows nothing for nil.
    private(set) var warning: WindWarning?

    /// The warning the user was last actually NOTIFIED about — forecast wobble (a peak that
    /// re-rounds from 27 to 26 mph, or shifts an hour) must not ping them twice for one blow.
    private var lastNotified: WindWarning?
    private var lastFetch: (lat: Double, lon: Double, at: Date)?
    private static let notificationID = "levelspot.windWarning"

    /// Check the forecast at the pitch. Cheap to call often — skips if the last check was
    /// under 30 minutes ago and we haven't moved ~5 km (one WeatherKit call per real check,
    /// comfortably inside the free 500k/month tier).
    func refreshIfNeeded(lat: Double, lon: Double) async {
        if let last = lastFetch,
           Date().timeIntervalSince(last.at) < 30 * 60,
           abs(lat - last.lat) < 0.05, abs(lon - last.lon) < 0.05 {
            return
        }
        lastFetch = (lat, lon, Date())
        do {
            let hourly = try await WeatherService.shared.weather(
                for: CLLocation(latitude: lat, longitude: lon), including: .hourly)
            let now = Date()
            // From the START of the current hour (the first forecast element is stamped on the
            // hour, and the "act now" gust may be in the hour we're already in) to +24h.
            let window = hourly.forecast.filter {
                $0.date > now.addingTimeInterval(-3600) && $0.date < now.addingTimeInterval(24 * 3600)
            }
            let peak = window.max { gustMPH($0) < gustMPH($1) }
            if let peak, gustMPH(peak) >= Self.warnMPH {
                let newWarning = WindWarning(peakMPH: Int(gustMPH(peak).rounded()), at: peak.date)
                warning = newWarning
                let alreadyTold = lastNotified.map { sameBlow($0, newWarning) } ?? false
                if !alreadyTold {
                    lastNotified = newWarning
                    await scheduleNotification(for: newWarning)
                }
            } else {
                warning = nil
                lastNotified = nil
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
            }
        } catch {
            // Transient failure (arriving with no signal, entitlement still propagating,
            // WeatherKit hiccup): KEEP the last known warning and any booked notification —
            // silently dropping a real alert is the worst outcome. Rewind the throttle so the
            // next check retries in ~3 minutes instead of 30.
            lastFetch = (lat, lon, Date().addingTimeInterval(-27 * 60))
        }
    }

    /// Same weather event, allowing forecast wobble: within 3 mph and an hour, same severity.
    private func sameBlow(_ a: WindWarning, _ b: WindWarning) -> Bool {
        abs(a.peakMPH - b.peakMPH) <= 3
            && abs(a.at.timeIntervalSince(b.at)) <= 3600
            && a.severe == b.severe
    }

    /// Ask for notification permission at a moment with context (the user just turned the
    /// feature on in Settings) instead of ambushing them mid-levelling at the first warning.
    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Forecast gust in mph, falling back to sustained wind when the gust field is absent.
    private func gustMPH(_ hour: HourWeather) -> Double {
        (hour.wind.gust ?? hour.wind.speed).converted(to: .milesPerHour).value
    }

    /// One pending notification, fired ~an hour before the peak (or straight away if the
    /// peak is nearly here). Each new warning replaces the previous schedule.
    private func scheduleNotification(for warning: WindWarning) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Wind at your pitch"
        content.body = "Gusts to \(warning.peakMPH) mph expected around \(warning.timeLabel)"
            + (warning.severe ? " — bring the awning in." : " — keep an eye on the awning.")
        content.sound = .default

        let fireIn = max(warning.at.timeIntervalSinceNow - 3600, 5)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        try? await center.add(UNNotificationRequest(identifier: Self.notificationID,
                                                    content: content, trigger: trigger))
    }

    /// Turning the feature off (or Pro lapsing): wipe ALL state, not just the pending alarm.
    /// A bare pending-removal left the capsule alive with no alarm behind it, and the throttle
    /// then blocked re-scheduling on re-enable — reset means re-enabling starts fresh.
    func reset() {
        warning = nil
        lastNotified = nil
        lastFetch = nil
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}
