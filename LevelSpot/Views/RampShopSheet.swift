import SwiftUI
import LevelSpotCore

/// The affiliate ramp shop. Shown at the "you can't level here" moment (`neededMM` set) and from
/// Setup (`neededMM == nil` → browse). Honestly filtered — only ramps that actually clear the
/// required height, cheapest-that-clears first. The disclosure is non-negotiable (ASA/FTC, and it's
/// the trust that makes the links convert). Buy links are physical goods → no Apple 30% cut.
struct RampShopSheet: View {
    let neededMM: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var products: [RampProfileRef] { ReferenceStore.shared.rampsReaching(mm: neededMM) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let mm = neededMM {
                        Text("Your ramps fall short here. These reach the ~\(mm)mm you need — cheapest first.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(products) { card($0) }
                    disclosure
                }
                .padding()
            }
            .navigationTitle(neededMM.map { "Ramps that reach \($0)mm" } ?? "Shop ramps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func card(_ p: RampProfileRef) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(tint(p).opacity(0.18)).frame(width: 40, height: 40)
                Image(systemName: icon(p)).foregroundStyle(tint(p))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(p.name).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text("\(p.ceilingMM)mm")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.levelGreen.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.levelGreen)
                    Text(kindLabel(p.rampKind)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(p.priceLabel).font(.subheadline.weight(.bold))
                Button { if let u = p.buyURL { openURL(u) } } label: {
                    Text("Buy →").font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(p.buyURL == nil)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var disclosure: some View {
        Text("LevelSpot earns a small commission on some links. It never changes your price — or which ramps we recommend. Only whether a ramp reaches the height decides that.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func kindLabel(_ k: RampKind) -> String {
        switch k {
        case .stepped: return "stepped"
        case .wedge: return "drive-on wedge"
        case .blocks: return "stackable blocks"
        case .inflatable: return "air · exact height"
        case .ratchet: return "ratchet · exact height"
        }
    }

    private func icon(_ p: RampProfileRef) -> String {
        switch p.rampKind {
        case .inflatable: return "cloud.fill"
        case .blocks: return "square.stack.3d.up.fill"
        case .ratchet: return "gearshape.fill"
        default: return "triangle.fill"
        }
    }

    private func tint(_ p: RampProfileRef) -> Color {
        p.rampKind.isContinuous ? Theme.sun : Theme.levelGreen
    }
}
