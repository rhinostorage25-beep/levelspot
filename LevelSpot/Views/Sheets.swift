import SwiftUI
import SwiftData
import LevelSpotCore

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
                Task {
                    await entitlements.purchasePro()
                    if entitlements.isPro { dismiss() }
                }
            } label: {
                Group {
                    if entitlements.purchaseInFlight {
                        ProgressView()
                    } else {
                        // Show the real localised price once StoreKit has loaded the product.
                        Text(entitlements.proPriceText.map { "Unlock Pro · \($0)" } ?? "Unlock LevelSpot Pro")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(entitlements.purchaseInFlight)

            Button("Restore purchases") {
                Task {
                    await entitlements.restore()
                    if entitlements.isPro { dismiss() }
                }
            }
            .font(.footnote)
            .disabled(entitlements.purchaseInFlight)

            if let error = entitlements.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
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
