import SwiftUI
import LevelSpotCore

struct LevelScanView: View {
    let config: VehicleConfig

    @Environment(MotionService.self) private var motion
    @Environment(EntitlementStore.self) private var entitlements

    @State private var tolerance: Tolerance = .comfort
    @State private var detailsOpen = false
    @State private var showPaywall = false
    @State private var showSaveSheet = false
    @State private var wasLevel = false
    @State private var lastStep: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                banner
                instructionCard
                frontBackRow
                detailsSection
                Text("Audio and haptic cues guide you as you adjust — no need to keep checking the screen.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Level Scan")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                showSaveSheet = true
            } label: {
                Text("Rate & Save This Pitch").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .sheet(isPresented: $showSaveSheet) {
            SavePitchSheet(config: config, corners: corners, isLevel: advice.isLevel)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .onChange(of: advice.isLevel) { _, nowLevel in
            if nowLevel && !wasLevel { Haptics.levelReached() }
            wasLevel = nowLevel
        }
        .onChange(of: advice.wheel?.stepMM) { _, step in
            if step != lastStep && step != nil { Haptics.stepChanged() }
            lastStep = step
        }
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) { simulateMenu }
            #endif
        }
    }

    // MARK: - Derived state (recomputed live from the sensor; no manual entry anywhere)

    private var effectiveTolerance: Tolerance { entitlements.isPro ? tolerance : .comfort }

    /// The ramped wheel sits on a specific axle, so the lateral maths uses THAT axle's track —
    /// this is exactly where an AL-KO widened rear differs from the front.
    private var advice: Advice {
        let lowEnd: End = motion.pitchDeg > 0 ? .rear : .front
        let track = Double(lowEnd == .front ? config.trackFrontMM : config.trackRearMM)
        return RampAdvisor.advise(rollDeg: motion.rollDeg, pitchDeg: motion.pitchDeg,
                                  trackMM: track, wheelbaseMM: Double(config.wheelbaseMM),
                                  stepsMM: config.activeStepsMM, tolerance: effectiveTolerance)
    }

    private var corners: CornerHeights {
        LevelMath.cornerHeights(rollDeg: motion.rollDeg, pitchDeg: motion.pitchDeg,
                                trackMM: Double(config.trackRearMM),
                                wheelbaseMM: Double(config.wheelbaseMM))
    }

    // MARK: - Pieces

    private var banner: some View {
        let (text, color): (String, Color) = {
            if advice.isLevel { return ("You're level — nice work", Theme.levelGreen) }
            if let wheel = advice.wheel { return ("\(wheel.wheelName) needs a ramp — drive up slowly", .secondary) }
            return ("Side-to-side sorted — check front-to-back next", .secondary)
        }()
        return Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(advice.isLevel ? Theme.levelGreen.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
    }

    private var instructionCard: some View {
        VStack(spacing: 16) {
            Text(advice.wheel.map { "\($0.wheelName) needs a ramp" } ?? "No ramp needed here")
                .font(.headline)
            HStack(spacing: 24) {
                cornerDiagram
                VStack(spacing: 4) {
                    Text(advice.wheel.map { "\($0.placementCM)cm" } ?? "Flat")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(advice.wheel == nil ? Theme.levelGreen : severityColor)
                        .contentTransition(.numericText())
                    Text(advice.wheel == nil ? "no ramp needed" : "out from the tyre")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topTrailing) {
            if config.usingTypicalDims {
                Text("ESTIMATED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    .padding(14)
            }
        }
    }

    private var severityColor: Color {
        guard let step = advice.wheel?.stepMM,
              let index = config.activeStepsMM.firstIndex(of: step) else { return Theme.needsRamp }
        return index >= config.activeStepsMM.count - 1 ? Theme.needsBigRamp : Theme.needsRamp
    }

    private var cornerDiagram: some View {
        let lowFL = advice.wheel?.end == .front && advice.wheel?.side == .left
        let lowFR = advice.wheel?.end == .front && advice.wheel?.side == .right
        let lowRL = advice.wheel?.end == .rear && advice.wheel?.side == .left
        let lowRR = advice.wheel?.end == .rear && advice.wheel?.side == .right
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.tertiaryLabel), lineWidth: 1.6)
            VStack {
                HStack { dot(lowFL); Spacer(); dot(lowFR) }
                Spacer()
                HStack { dot(lowRL); Spacer(); dot(lowRR) }
            }
            .padding(8)
        }
        .frame(width: 58, height: 104)
    }

    private func dot(_ isLow: Bool) -> some View {
        Circle()
            .fill(isLow ? Theme.needsRamp : (advice.isLevel ? Theme.levelGreen : Color(.tertiaryLabel)))
            .frame(width: 14, height: 14)
    }

    private var frontBackRow: some View {
        HStack {
            if let step = advice.longStepMM, let placement = advice.longPlacementCM, let end = advice.lowEnd {
                Text("Front to back: \(placement)cm out under the \(end == .front ? "front" : "rear") wheels · \(step)mm step")
                    .foregroundStyle(.secondary)
            } else {
                Text("Front to back: level").foregroundStyle(Theme.levelGreen)
            }
            Spacer()
        }
        .font(.footnote)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var detailsSection: some View {
        VStack(spacing: 0) {
            Button {
                if entitlements.isPro {
                    withAnimation(.snappy) { detailsOpen.toggle() }
                } else {
                    showPaywall = true
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Details").font(.subheadline.weight(.medium))
                    Image(systemName: entitlements.isPro ? "chevron.right" : "lock")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(entitlements.isPro && detailsOpen ? 90 : 0))
                }
            }
            .padding(8)

            if detailsOpen && entitlements.isPro {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LEVEL TOLERANCE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Tolerance", selection: $tolerance) {
                        ForEach(Tolerance.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Fridge operation and general comfort don't need the same precision.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Divider()
                    // Per-corner offsets in mm — the honest per-corner quantity a single rigid
                    // body has (per-corner "degrees" would be theatre).
                    cornerRow("Front Left", corners.fl)
                    cornerRow("Front Right", corners.fr)
                    cornerRow("Rear Left", corners.rl)
                    cornerRow("Rear Right", corners.rr)
                    Divider()
                    HStack {
                        Text("Sensor confidence").foregroundStyle(.secondary)
                        Spacer()
                        Text(motion.isSteady ? "High · vehicle steady" : "Medium · vehicle moving")
                            .fontWeight(.semibold)
                    }
                    .font(.footnote)
                    Text("Derived from a single tilt reading plus your vehicle's known dimensions — no sensor hardware needed at every wheel.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func cornerRow(_ label: String, _ mm: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%+.0fmm", mm)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.footnote)
    }

    #if DEBUG
    private var simulateMenu: some View {
        Menu("Sim") {
            Button("Level") { motion.simulate(rollDeg: 0.1, pitchDeg: 0.05) }
            Button("Right low 2.9°") { motion.simulate(rollDeg: 2.86, pitchDeg: 0) }
            Button("Left low + nose down") { motion.simulate(rollDeg: -2.2, pitchDeg: -1.2) }
        }
    }
    #endif
}
