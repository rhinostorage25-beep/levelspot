import SwiftUI
import SwiftData
import LevelSpotCore

/// Save = one tap plus a star rating. A private note to self, never shared content.
struct SavePitchSheet: View {
    let config: VehicleConfig
    let corners: CornerHeights
    let isLevel: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocationService.self) private var location
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(EntitlementStore.self) private var entitlements

    @State private var rating = 0
    @State private var siteName = ""
    @State private var capturedSun: Int?
    @State private var capturedView: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            rating = star
                        } label: {
                            Image(systemName: "star.fill")
                                .font(.title)
                                .foregroundStyle(star <= rating ? Theme.proBadge : Color(.tertiaryLabel))
                        }
                        .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                    }
                }
                .padding(.top, 16)

                TextField("Site name (optional)", text: $siteName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Text("Just a private note to yourself for next time — nothing here is shared or visible to anyone else.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if !connectivity.isOnline {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                        Text("No signal — saved on this phone; will sync to your other devices once you're back online and signed in.")
                            .font(.caption)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                if location.latitude == nil {
                    Text("Waiting for a GPS fix — a moment, no signal needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if entitlements.isPro {
                    proHeadingCapture
                }
                Spacer()
            }
            .navigationTitle("Rate This Pitch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(rating == 0 || location.latitude == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let lat = location.latitude, let lon = location.longitude else { return }
        let record = PitchRecord(
            latitude: lat, longitude: lon,
            levelHeading: location.headingDeg,
            corners: (corners.fl, corners.fr, corners.rl, corners.rr),
            rating: rating, siteName: siteName
        )
        // Pro sun/view headings, if the user logged them (nil otherwise — the free tier
        // never reaches this UI). Server RLS re-enforces the gate on sync regardless.
        record.sunHeading = capturedSun
        record.viewHeading = capturedView
        modelContext.insert(record)
        Haptics.saved()
        dismiss()
    }

    // Pro-only: point the top of the phone at the sun / the view and tap to log that
    // compass heading. Optional — a pitch is perfectly valid with neither. Uses the same
    // live heading (`location.headingDeg`) that the level scan reads, so no new plumbing.
    @ViewBuilder
    private var proHeadingCapture: some View {
        VStack(spacing: 10) {
            Text("Sun & view (optional)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            captureButton(symbol: "sun.max.fill", label: "sun", tint: Theme.sun,
                          value: capturedSun) { capturedSun = location.headingDeg }
            captureButton(symbol: "mountain.2.fill", label: "view", tint: Theme.view,
                          value: capturedView) { capturedView = location.headingDeg }
            Text(location.headingDeg == nil
                 ? "Point the top of your phone at the sun or the view, then tap — waiting for the compass…"
                 : "Point the top of your phone at the sun or the view, then tap Log.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
    }

    private func captureButton(symbol: String, label: String, tint: Color,
                               value: Int?, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.saved()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
                Text(value.map { "Best \(label): \($0)°" } ?? "Log best \(label) heading")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: value == nil ? "location.north.line" : "checkmark.circle.fill")
                    .foregroundStyle(value == nil ? Color.secondary : tint)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(location.headingDeg == nil)
    }
}

struct PaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
            }
            Image(systemName: "star.fill")
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(colors: [Color(light: "#2AA9FF", dark: "#2AA9FF"),
                                            Color(light: "#00C7BE", dark: "#00C7BE")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16))
            Text("LevelSpot Pro").font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 14) {
                benefit("sun.max", "Sun & view headings on the arrival screen, with conflict flagging against your level position")
                benefit("lock.open", "Exact ramp brand & model calibration — Thule, Milenco, VonHaus, Fiamma")
                benefit("clock", "Full detail view on every scan — exact offsets, sensor confidence, and your own custom level tolerance")
            }

            Button {
                // v1 placeholder — becomes a StoreKit 2 purchase with server verification.
                entitlements.purchasePro()
                dismiss()
            } label: {
                Text("Unlock LevelSpot Pro").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text).font(.subheadline)
        }
    }
}
