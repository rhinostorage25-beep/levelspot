import SwiftUI
import SwiftData
import LevelSpotCore

struct PaywallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementStore.self) private var entitlements

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                }

                // A static preview of the Pro dial — the sun ring + green lock a free user doesn't have.
                ProPreviewDial()
                    .frame(width: 150, height: 150)
                    .accessibilityHidden(true)

                Text("LevelSpot Pro").font(.title2.weight(.bold))
                Text("Plan the pitch before you park.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 16) {
                    benefit("sun.max.fill", "Position the awning for sun or shade",
                            "See which way to face the vehicle for morning, midday or evening.")
                    benefit("wind", "Get warnings for strong gusts",
                            "On screen and by notification, before they reach your pitch.")
                    benefit("mappin.and.ellipse", "Remember previous pitches",
                            "Recall the exact setup when you return.")
                    benefit("bed.double.fill", "Add a comfortable sleep tilt",
                            "A gentle rise toward your pillow, built into the level target.")
                    benefit("car.2.fill", "Save multiple vehicles",
                            "Separate setups, one tap to switch.")
                    benefit("scope", "Follow wheel-by-wheel guidance",
                            "Targets for air bags, blocks and ratchet levellers.")
                }
                .padding(.horizontal, 4)

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
                            Text(entitlements.proPriceText.map { "Unlock Pro · \($0)" } ?? "Unlock LevelSpot Pro")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(entitlements.purchaseInFlight)

                Text("One-time purchase. No subscription.")
                    .font(.caption2).foregroundStyle(.secondary)

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
            }
            .padding(24)
        }
        .presentationDetents([.large])
    }

    private func benefit(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// A static, non-interactive rendering of the Pro dial for the paywall — the amber sun ring
/// (the sun & shade planner) that the free targeting dial doesn't show.
private struct ProPreviewDial: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.levelGreen.opacity(0.18)).blur(radius: 8)
            Circle().fill(Color(red: 0.09, green: 0.09, blue: 0.11))
            Circle().stroke(Theme.sun.opacity(0.7), lineWidth: 3).padding(7)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 17))
                .foregroundStyle(Theme.sun)
                .shadow(color: Theme.sun.opacity(0.9), radius: 5)
                .offset(y: -60)
            Circle().stroke(Theme.levelGreen.opacity(0.5), lineWidth: 1.3).frame(width: 74, height: 74)
            ScopeReticle().stroke(Theme.levelGreen.opacity(0.8), lineWidth: 1.3).frame(width: 92, height: 92)
            Circle().fill(Theme.levelGreen).frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.6))
                .shadow(color: Theme.levelGreen.opacity(0.9), radius: 6)
        }
    }
}
