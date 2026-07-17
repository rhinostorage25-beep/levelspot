import SwiftUI
import LevelSpotCore

/// The Pro guided flow for ramps you set one wheel at a time — inflatables, stackable blocks,
/// ratchet levellers. You've placed the aids under the low wheels and driven on; this walks you
/// through raising each wheel to the exact height that brings it level with the reference (highest)
/// corner, beeping as you approach the target so you watch the pump/blocks, not the phone.
///
/// The signal: from the live tilt we derive each corner's height (LevelMath.cornerHeights). A
/// corner's "gap" = highest corner − this corner = how much further it must rise. Raise a wheel and
/// its gap shrinks; at ~0 it's level with the reference and we chime. Re-derived live, so it
/// self-corrects if you overshoot (that corner becomes the new high and the others' gaps grow).
struct InflationGuideView: View {
    let config: VehicleConfig

    @Environment(MotionService.self) private var motion
    @Environment(\.dismiss) private var dismiss
    // Value-critical text scales with Dynamic Type like every other reading in the app.
    @ScaledMetric(relativeTo: .largeTitle) private var gaugeValueSize: CGFloat = 34

    @State private var audio = AudioCoach()
    @State private var selected: Corner?
    @State private var selectedStartGap: Double = 0
    @State private var done: Set<Corner> = []

    private let tolMM = 12.0

    enum Corner: CaseIterable, Hashable {
        case fl, fr, rl, rr
        var label: String {
            switch self {
            case .fl: return "Front-left";  case .fr: return "Front-right"
            case .rl: return "Rear-left";   case .rr: return "Rear-right"
            }
        }
    }

    // MARK: - Live geometry

    private var corners: CornerHeights {
        LevelMath.cornerHeights(rollDeg: motion.rollDeg, pitchDeg: motion.pitchDeg,
                                trackFrontMM: Double(config.trackFrontMM),
                                trackRearMM: Double(config.trackRearMM),
                                wheelbaseMM: Double(config.wheelbaseMM))
    }
    private func height(_ c: Corner) -> Double {
        let ch = corners
        switch c { case .fl: return ch.fl; case .fr: return ch.fr; case .rl: return ch.rl; case .rr: return ch.rr }
    }
    private var maxHeight: Double { Corner.allCases.map(height).max() ?? 0 }
    /// How much further this corner must rise to match the reference (highest) corner.
    private func gap(_ c: Corner) -> Double { max(0, maxHeight - height(c)) }
    private var reference: Corner { Corner.allCases.max(by: { height($0) < height($1) }) ?? .fl }
    private func isDone(_ c: Corner) -> Bool { c == reference || done.contains(c) || gap(c) < tolMM }
    private var allLevel: Bool { Corner.allCases.allSatisfy { gap($0) < tolMM } }
    private var activeGap: Double? { selected.map(gap) }

    private var kind: RampKind { config.activeRampSet.kind }
    private var verb: String {
        switch kind {
        case .inflatable: return "Inflate"
        case .ratchet: return "Wind up"
        case .blocks: return "Stack blocks under"
        default: return "Raise"
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            // ScrollView that doesn't scroll at standard sizes: the guidance card grows with
            // its content (min-height keeps the anti-reflow floor) and accessibility Dynamic
            // Type users can still reach everything instead of the card clipping.
            ScrollView {
                VStack(spacing: 20) {
                    Text("Keep the highest wheel in place and raise the highlighted wheels one at a time.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    wheelDiagram
                        .frame(height: 240)

                    actionZone
                        .frame(minHeight: 150, alignment: .top)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Level wheel by wheel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { motion.start(); audio.start() }
            .onDisappear { motion.stop(); audio.stop() }
            .onChange(of: activeGap) { _, g in pushAudio(g) }
        }
    }

    // MARK: - Top-view wheel selector

    private var wheelDiagram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color(.tertiaryLabel), lineWidth: 2)
                .frame(width: 116, height: 168)
            Text("FRONT")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .offset(y: -100)
            wheelButton(.fl).offset(x: -74, y: -74)
            wheelButton(.fr).offset(x: 74, y: -74)
            wheelButton(.rl).offset(x: -74, y: 74)
            wheelButton(.rr).offset(x: 74, y: 74)
        }
        .frame(maxWidth: .infinity)
    }

    private func wheelButton(_ c: Corner) -> some View {
        let isRef = c == reference
        let finished = isDone(c)
        let isSel = selected == c
        let tint: Color = isRef ? Color(.systemGray3)
            : finished ? Theme.levelGreen
            : isSel ? Color(red: 0.98, green: 0.16, blue: 0.22)
            : Theme.needsRamp
        return Button {
            if !isRef && !finished { select(c) }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(tint).frame(width: 34, height: 34)
                        .overlay(Circle().stroke(.white.opacity(isSel ? 0.9 : 0), lineWidth: 2))
                    if isRef { Image(systemName: "anchor").font(.caption2).foregroundStyle(.white) }
                    else if finished { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                }
                Text(isRef ? "Reference" : finished ? "Complete" : "\(Int(gap(c).rounded())) mm")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isRef ? .secondary : tint)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRef || finished)
        .accessibilityLabel(isRef ? "\(c.label) wheel. Reference — keep in place."
                            : finished ? "\(c.label) wheel. Complete."
                            : "\(c.label) wheel. Raise by \(Int(gap(c).rounded())) millimetres.")
    }

    // MARK: - Action zone (fixed height)

    @ViewBuilder private var actionZone: some View {
        if allLevel {
            card(icon: "checkmark.circle.fill", tint: Theme.levelGreen,
                 title: "Vehicle level",
                 message: "All wheels have reached their targets. Apply the handbrake.")
        } else if let c = selected {
            activeGauge(c)
        } else {
            let next = Corner.allCases.filter { !isDone($0) }.max(by: { gap($0) < gap($1) })
            card(icon: "hand.tap.fill", tint: Theme.needsRamp,
                 title: next.map { "Start with \($0.label.lowercased())" } ?? "Pick a wheel",
                 message: next.map { "Raise it by \(Int(gap($0).rounded())) mm." }
                    ?? "Tap the wheel you'll raise first.")
        }
    }

    private func activeGauge(_ c: Corner) -> some View {
        let remaining = gap(c)
        let progress = selectedStartGap > 0 ? min(1, max(0, 1 - remaining / selectedStartGap)) : 0
        let blocks = config.activeRampSet.incrementMM > 0
            ? max(1, Int((remaining / Double(config.activeRampSet.incrementMM)).rounded())) : 0
        return VStack(spacing: 10) {
            Text("\(verb) \(c.label)")
                .font(.headline)
            Text("\(Int(remaining.rounded())) mm to go")
                .font(.system(size: gaugeValueSize, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(remaining < tolMM ? Theme.levelGreen : Color(.label))
                .contentTransition(.numericText())
            switch kind {
            case .blocks:
                Text("Add approximately \(blocks) block\(blocks == 1 ? "" : "s"), then check the reading.")
                    .font(.subheadline).foregroundStyle(.secondary)
            case .inflatable:
                Text("Inflate slowly. The tones speed up as you approach the target.")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                Text("Raise slowly until the target is reached.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: progress).tint(Theme.levelGreen)
            // 44pt frame + contentShape INSIDE the label — outside the Button it only
            // reserves layout space and the tap target stays text-height.
            Button { selected = nil } label: {
                Text("Choose another wheel")
                    .font(.footnote)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func card(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.bold)).foregroundStyle(tint)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Selection + audio

    private func select(_ c: Corner) {
        selected = c
        selectedStartGap = gap(c)
        Haptics.stepChanged()
    }

    private func pushAudio(_ g: Double?) {
        guard let g, let c = selected else {
            audio.update(offMM: 0, toleranceMM: tolMM, isLevel: false, beyond: false, enabled: false)
            return
        }
        let level = g < tolMM
        audio.update(offMM: g, toleranceMM: tolMM, isLevel: level, beyond: false, enabled: true)
        if level {
            done.insert(c)
            selected = nil
            audio.alertLevel()
            Haptics.levelReached()
        }
    }
}
