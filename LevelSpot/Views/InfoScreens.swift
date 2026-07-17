import SwiftUI

// Privacy, Help and About — the §9 App-section screens. Static, honest, and short: each
// answers what a customer actually asks, in the same calm voice as the rest of the app.

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Label("Your data stays on this phone", systemImage: "iphone")
                    .font(.headline)
                Text("Measurements, saved pitches and settings are stored only on your device. LevelSpot has no accounts, no analytics and no advertising trackers.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Location") {
                Text("Used only to recognise pitches you have saved and to check the sun position and wind forecast where you are. Your location is not shared with other users or any third party besides Apple Weather (below).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Camera") {
                Text("Used only while you choose to measure your vehicle. No photos or video are taken or stored.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Weather") {
                Text("Wind alerts send your coordinates to Apple Weather to fetch the local forecast. Apple's handling is described in their attribution and legal page, linked under Weather data in Settings.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Shop links") {
                Text("Ramp links open the retailer's site. LevelSpot may earn commission from some purchases; this never changes your price, and nothing about you is shared with the retailer by this app.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            helpItem("Start here",
                     "Lay the phone flat in the vehicle, screen up, top toward the front. The dial shows which wheels need ramps and by how much. Tap Start guidance, drive up slowly, and stop at the tone.")
            helpItem("Calibrate once",
                     "Phones read a degree or two off when lying flat (the camera bump). Put the phone on ground you know is level and tap Calibrate here — once is enough. If readings ever look wrong, reset the calibration and redo it on level ground.")
            helpItem("Why did the wheel markers disappear?",
                     "Markers clear when the vehicle is within the comfort band (about 1.2°) — level enough that no ramp would genuinely improve it.")
            helpItem("Measuring your vehicle",
                     "Two figures — wheelbase and front track width, wheel-centre to wheel-centre. A tape measure is the reference; the camera measure is a convenience with roughly ±20 mm accuracy.")
            helpItem("Sun and shade",
                     "Pick a time from the sun button. Turn the vehicle until the sun marker reaches the top — morning and evening aim the awning at the sun, midday positions it for shade. It needs your measurements, awning side and a location fix.")
            helpItem("Wind alerts",
                     "With alerts on, LevelSpot checks the local gust forecast and warns you on screen — and by notification if notifications are allowed — before gusts that could threaten the awning.")
            // Email-support row deliberately absent until a support address is chosen —
            // shipping a placeholder contact is worse than shipping none. Add:
            //   Link(destination: URL(string: "mailto:<address>?subject=LevelSpot")!) {
            //       Label("Email support", systemImage: "envelope")
            //   }
            // once Jonathan picks the address (LevelSpot-branded vs an existing inbox).
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func helpItem(_ title: String, _ body: String) -> some View {
        Section(title) {
            Text(body).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: version)
            } header: {
                Text("LevelSpot")
            } footer: {
                Text("Park, lay the phone flat, and get level — for campervans, motorhomes, caravans and trailers.")
            }
            Section {
                Link(destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!) {
                    Label("Weather data by Apple Weather", systemImage: "cloud.sun")
                }
            } footer: {
                Text("Forecasts used for awning wind alerts.")
            }
        }
        .navigationTitle("About LevelSpot")
        .navigationBarTitleDisplayMode(.inline)
    }
}
