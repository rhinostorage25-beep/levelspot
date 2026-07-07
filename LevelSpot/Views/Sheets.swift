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

    @State private var rating = 0
    @State private var siteName = ""

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
        modelContext.insert(record)
        Haptics.saved()
        dismiss()
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
