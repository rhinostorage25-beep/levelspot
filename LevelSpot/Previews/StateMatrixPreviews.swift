import SwiftUI

// The reviewable state matrix (redesign brief §24): every coach state, status variant and
// primary action, side by side, at a glance. These compile in CI like any other code, and
// on a Mac they render in the Xcode canvas — the closest thing this Mac-less project has
// to a visual regression harness. Components only (no live services), so they stay cheap
// and deterministic.

#if DEBUG

#Preview("Coach — every state") {
    ScrollView {
        VStack(spacing: DS.row) {
            CoachPanel(role: .neutral, icon: "iphone.gen3",
                       title: "Lay your phone flat",
                       message: "Place it screen-up in the vehicle to measure the pitch.")
            CoachPanel(role: .neutral, icon: "exclamationmark.triangle",
                       title: "Tilt sensor unavailable",
                       message: "This device can't read tilt, so levelling guidance can't run. The sun planner and your saved pitches still work.")
            CoachPanel(role: .action, icon: "arrow.up.circle.fill",
                       title: "Place ramps at the highlighted wheels",
                       message: "Required lift: about 70 mm.")
            CoachPanel(role: .action, icon: "arrow.up.circle.fill",
                       title: "Place ramps at the highlighted wheels",
                       message: "Estimated lift: 70 mm. Add your vehicle measurements for greater accuracy.",
                       secondaryTitle: "Add measurements", secondaryAction: {})
            CoachPanel(role: .unsafe, icon: "exclamationmark.triangle.fill",
                       title: "Your ramps are not high enough",
                       message: "They reach 100 mm. This pitch requires about 145 mm. Move to a flatter spot, or use taller ramps.",
                       secondaryTitle: "View suitable ramps", secondaryAction: {})
            CoachPanel(role: .unsafe, icon: "exclamationmark.triangle.fill",
                       title: "Move to a flatter spot",
                       message: "Required lift: about 210 mm — beyond normal levelling-ramp limits.")
            CoachPanel(role: .neutral, icon: "checkmark.circle",
                       title: "This is as close as your ramps allow",
                       message: "Your smallest step would not improve the result.")
            CoachPanel(role: .action, icon: "arrow.up.circle.fill",
                       title: "Ready to level",
                       message: "Place your levelling equipment under the highlighted wheels.")
            CoachPanel(role: .action, icon: "waveform",
                       title: "Move forward slowly",
                       message: "Listen for the stop tone.")
            CoachPanel(role: .action, icon: "waveform",
                       title: "Almost level",
                       message: "Continue slowly.")
            CoachPanel(role: .unsafe, icon: "exclamationmark.octagon.fill",
                       title: "STOP",
                       message: "Vehicle level. Stop moving.")
            CoachPanel(role: .success, icon: "checkmark.circle.fill",
                       title: "Vehicle level",
                       message: "Apply the handbrake before leaving the driver's seat.")
            CoachPanel(role: .windWatch, icon: "wind",
                       title: "Gusts to 26 mph around 23:00",
                       message: "Keep an eye on the awning.")
            CoachPanel(role: .windUrgent, icon: "wind",
                       title: "Gusts to 42 mph around 23:00",
                       message: "Bring the awning in.")
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}

#Preview("Status — every variant") {
    VStack(spacing: DS.section) {
        StatusSummary(value: "4.2° off", detail: "Nose high · right high")
        StatusSummary(value: "1.4° off", detail: "Almost level")
        StatusSummary(value: "Level", detail: "", valueColor: .green)
        StatusSummary(value: "STOP", detail: "", valueColor: .red)
        StatusSummary(value: "—", detail: "No tilt data")
    }
    .padding()
}

#Preview("Primary actions") {
    VStack(spacing: DS.row) {
        PrimaryBottomAction(title: "Start guidance", icon: "scope") {}
        PrimaryBottomAction(title: "Guide me wheel by wheel", icon: "scope") {}
        PrimaryBottomAction(title: "Stop", icon: "xmark", isProminent: false) {}
        PrimaryBottomAction(title: "Done", icon: "checkmark.circle.fill") {}
    }
    .padding()
}

#Preview("Setup progress") {
    VStack(spacing: DS.related) {
        ForEach(1...5, id: \.self) { SetupProgress(step: $0, total: 5) }
    }
    .padding()
}

#Preview("Coach — accessibility type") {
    ScrollView {
        VStack(spacing: DS.row) {
            CoachPanel(role: .action, icon: "arrow.up.circle.fill",
                       title: "Place ramps at the highlighted wheels",
                       message: "Estimated lift: 70 mm. Add your vehicle measurements for greater accuracy.",
                       secondaryTitle: "Add measurements", secondaryAction: {})
            CoachPanel(role: .windUrgent, icon: "wind",
                       title: "Gusts to 42 mph around 23:00",
                       message: "Bring the awning in.")
            StatusSummary(value: "4.2° off", detail: "Nose high · right high")
        }
        .padding()
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#endif
