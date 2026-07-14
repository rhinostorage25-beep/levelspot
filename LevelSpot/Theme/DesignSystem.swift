import SwiftUI
import UIKit

// The shared design system for the Apple-quality redesign (see redesign-audit-2026-07-13.md).
// Every screen composes these instead of styling itself: one spacing rhythm, one coach panel,
// one primary action, one status style. Semantic colours only — orange asks for physical
// action, red means stop/unsafe, green means confirmed success, grey is inactive guidance.

/// Spacing rhythm. Use these instead of ad-hoc numbers.
enum DS {
    static let micro: CGFloat = 4        // icon/text micro-gap
    static let related: CGFloat = 8      // related items
    static let row: CGFloat = 12         // row padding
    static let content: CGFloat = 16     // standard content spacing
    static let margin: CGFloat = 20      // screen horizontal margin
    static let section: CGFloat = 24     // major section spacing
    static let transition: CGFloat = 32  // large content transition
}

/// What a coach message means, which decides how it looks. One panel at a time, always.
enum CoachRole {
    case neutral      // passive guidance ("Lay your phone flat")
    case action       // physical action required (place ramps, raise wheels)
    case unsafe       // impossible or stop-worthy (too steep, STOP)
    case success      // confirmed complete
    case windWatch    // amber gust warning — solid panel, replaces coaching
    case windUrgent   // red gust warning

    var tint: Color {
        switch self {
        case .neutral: return Color(.secondaryLabel)
        case .action, .windWatch: return .orange
        case .unsafe, .windUrgent: return .red
        case .success: return .green
        }
    }

    /// Wind panels are solid (white text on the tint); everything else is a quiet tinted card.
    var isSolid: Bool { self == .windWatch || self == .windUrgent }
}

/// The one current coach message. Grows with Dynamic Type (min height, never max — an
/// instruction must never truncate), holds a floor height so state changes don't reflow
/// the dial below.
struct CoachPanel: View {
    let role: CoachRole
    let icon: String
    let title: String
    let message: String
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    @ScaledMetric(relativeTo: .footnote) private var floorHeight: CGFloat = 116

    var body: some View {
        HStack(alignment: .top, spacing: DS.row) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(role.isSolid ? .white : role.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.micro) {
                Text(title)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(role.isSolid ? .white
                                     : role == .neutral ? Color(.label) : role.tint)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(role.isSolid ? .white.opacity(0.92) : Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                if let secondaryTitle, let secondaryAction {
                    Button(action: secondaryAction) {
                        Text(secondaryTitle)
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: 44, alignment: .leading)   // real 44pt hit target
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.content)
        // The floor exists to stop state-to-state reflow, not to reserve half the screen:
        // past ~2× the base size the content itself drives the height.
        .frame(minHeight: min(floorHeight, 232), alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(role.isSolid ? AnyShapeStyle(role.tint)
                                 : role == .neutral
                                 ? AnyShapeStyle(Color(.secondarySystemGroupedBackground))
                                 : AnyShapeStyle(role.tint.opacity(0.13)),
                    in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

/// The single primary action for the current state. Full width, one per screen.
struct PrimaryBottomAction: View {
    let title: String
    var icon: String?
    var role: ButtonRole?
    var isProminent = true
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: DS.related) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 28)
        }
        .buttonStyle(BorderedProminentIf(prominent: isProminent))
        .controlSize(.large)
    }
}

/// bordered vs borderedProminent chosen at runtime (ternaries can't switch button styles).
struct BorderedProminentIf: PrimitiveButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.bordered)
        }
    }
}

/// Live status: a big value line (monospaced digits so it doesn't shimmer) and one
/// direction line. Sentence case; STOP is the only permitted capitals, passed by the caller.
struct StatusSummary: View {
    let value: String
    let detail: String
    var valueColor: Color = Color(.label)

    @ScaledMetric(relativeTo: .largeTitle) private var floorHeight: CGFloat = 92
    // Scales with Dynamic Type in lockstep with the floor — a hard-coded 44 stayed small
    // while the detail line grew, inverting the hierarchy exactly for low-vision users.
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 44

    var body: some View {
        VStack(spacing: DS.micro) {
            Text(value)
                .font(.system(size: valueSize, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: min(floorHeight, 184))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Meaningful wizard progress — "Step 2 of 5", not anonymous dots.
struct SetupProgress: View {
    let step: Int
    let total: Int

    var body: some View {
        Text("Step \(step) of \(total)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

extension Haptics {
    /// Physical-action selection (wheel picked, awning side chosen).
    static func selected() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    /// A measurement point was placed (camera measure).
    static func pointPlaced() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    /// Something needs attention before continuing (invalid calibration surface).
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    /// Sun alignment locked on target.
    static func sunAligned() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
