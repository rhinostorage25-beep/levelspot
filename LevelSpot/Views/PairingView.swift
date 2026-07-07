import SwiftUI
import SwiftData

/// Spare-device sensor pairing. The staged flow matches the design handoff exactly; in this
/// build the scan/pair/calibrate steps are SIMULATED (visibly labelled below) — the real BLE
/// transport is build-order step 5, after the single-device flow proves out end to end.
/// The GATT service shape is documented in ../platform-strategy-2026-07.md so an old Android
/// phone can eventually feed an iPhone display and vice versa.
struct PairingView: View {
    @Query private var configs: [VehicleConfig]

    enum Step { case idle, scanning, found, paired, calibrating, calibrated }
    @State private var step: Step = .idle

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Turn an old iPhone or iPad into a permanently mounted in-van sensor, paired over Bluetooth — no extra hardware to buy.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                card

                Text("Pairing is simulated in this build — the Bluetooth transport arrives once the single-device flow is proven.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Spare-Device Sensor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if configs.first?.spareDeviceName != nil { step = .calibrated }
        }
    }

    @ViewBuilder
    private var card: some View {
        switch step {
        case .idle:
            stateCard(symbol: "iphone.gen1.radiowaves.left.and.right", pulsing: false,
                      title: "No spare device paired") {
                Button("Scan for Nearby Devices") {
                    step = .scanning
                    Task {
                        try? await Task.sleep(for: .seconds(1.1))
                        if step == .scanning { step = .found }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .scanning:
            stateCard(symbol: "iphone.gen1.radiowaves.left.and.right", pulsing: true,
                      title: "Scanning for nearby devices…") { EmptyView() }
        case .found:
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("iPhone 8")
                    Text("Nearby · strong signal").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Pair") { step = .paired }
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        case .paired:
            stateCard(symbol: "checkmark", tint: Theme.levelGreen, pulsing: false,
                      title: "Paired with iPhone 8",
                      subtitle: "Place this device on a flat, level surface, then calibrate — the same one-time step LevelSpot already asks of your main phone.") {
                Button("Calibrate") {
                    step = .calibrating
                    Task {
                        try? await Task.sleep(for: .seconds(0.9))
                        step = .calibrated
                        configs.first?.spareDeviceName = "iPhone 8"
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .calibrating:
            stateCard(symbol: "gyroscope", pulsing: true, title: "Calibrating…") { EmptyView() }
        case .calibrated:
            VStack(spacing: 14) {
                Image(systemName: "checkmark").font(.largeTitle).foregroundStyle(Theme.levelGreen)
                Text("Paired & Calibrated").font(.headline)
                Text("Using iPhone 8, mounted in the van, as your live sensor. Your current phone is now just the display.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Forget This Device", role: .destructive) {
                    configs.first?.spareDeviceName = nil
                    step = .idle
                }
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(Theme.levelGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func stateCard(symbol: String, tint: Color = .secondary, pulsing: Bool,
                           title: String, subtitle: String? = nil,
                           @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: pulsing)
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            action().frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
