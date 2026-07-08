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
            VStack(spacing: 16) {
                verdictBanner
                vanCard
                stepsCard
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

    // MARK: - Verdict banner (reflects BOTH axes — never green while one side is out)

    private var verdictBanner: some View {
        let (text, tint, bg, icon): (String, Color, Color, String) = {
            if advice.beyondRamp {
                return ("Too steep here — reposition the van", Theme.needsBigRamp,
                        Theme.needsBigRamp.opacity(0.14), "exclamationmark.triangle.fill")
            }
            if advice.isLevel {
                return ("You're level — nice work", Theme.levelGreen,
                        Theme.levelGreen.opacity(0.14), "checkmark.circle.fill")
            }
            return ("Not level yet — follow the steps below", Color(.secondaryLabel),
                    Color(.secondarySystemGroupedBackground), "arrow.down.to.line")
        }()
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout.weight(.semibold)).foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Van card (top-view diagram + the two live tilt angles)

    private var vanCard: some View {
        HStack(alignment: .center, spacing: 20) {
            vanDiagram
            tiltReadout
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topTrailing) { estimatedBadge }
    }

    private var vanDiagram: some View {
        VStack(spacing: 5) {
            Text("FRONT").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundStyle(.tertiary)
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.tertiarySystemFill))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(.separator), lineWidth: 1))
                VStack {
                    HStack { tyre(.front, .left); Spacer(); tyre(.front, .right) }
                    Spacer()
                    HStack { tyre(.rear, .left); Spacer(); tyre(.rear, .right) }
                }
                .padding(12)
            }
            .frame(width: 132, height: 190)
            Text("REAR").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundStyle(.tertiary)
        }
    }

    /// A wheel: coloured by how far this corner sits below the highest one (from the rigid-body
    /// corner maths), with the recommended ramp step badged on the wheels that actually get one.
    private func tyre(_ end: End, _ side: Side) -> some View {
        let step = stepBadge(end, side)
        let color = wheelColor(end, side)
        return VStack(spacing: 4) {
            if end == .rear, let step { stepPill(step, color) }
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 30)
            if end == .front, let step { stepPill(step, color) }
        }
    }

    private func stepPill(_ mm: Int, _ color: Color) -> some View {
        Text("\(mm)mm")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var tiltReadout: some View {
        VStack(alignment: .leading, spacing: 16) {
            tiltStat(title: "Side-to-side", deg: motion.rollDeg, detail: rollDetail,
                     axisLevel: advice.wheel == nil && !advice.lateralBeyondRamp,
                     beyond: advice.lateralBeyondRamp)
            tiltStat(title: "Front-to-back", deg: motion.pitchDeg, detail: pitchDetail,
                     axisLevel: advice.longStepMM == nil && !advice.longBeyondRamp,
                     beyond: advice.longBeyondRamp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tiltStat(title: String, deg: Double, detail: String,
                          axisLevel: Bool, beyond: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f°", abs(deg)))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(beyond ? Theme.needsBigRamp : (axisLevel ? Theme.levelGreen : Color(.label)))
                .contentTransition(.numericText())
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var rollDetail: String {
        if advice.lateralBeyondRamp { return "way over — reposition" }
        if abs(motion.rollDeg) < 0.1 { return "level" }
        return motion.rollDeg > 0 ? "left side high" : "right side high"
    }

    private var pitchDetail: String {
        if advice.longBeyondRamp { return "way over — reposition" }
        if abs(motion.pitchDeg) < 0.1 { return "level" }
        return motion.pitchDeg > 0 ? "nose high" : "nose low"
    }

    @ViewBuilder private var estimatedBadge: some View {
        if config.usingTypicalDims {
            Text("ESTIMATED")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .padding(14)
        }
    }

    // MARK: - Wheel colouring / badges

    private var maxCornerHeight: Double { max(corners.fl, corners.fr, corners.rl, corners.rr) }

    private func cornerHeight(_ end: End, _ side: Side) -> Double {
        switch (end, side) {
        case (.front, .left): return corners.fl
        case (.front, .right): return corners.fr
        case (.rear, .left): return corners.rl
        case (.rear, .right): return corners.rr
        }
    }

    private func wheelColor(_ end: End, _ side: Side) -> Color {
        if advice.isLevel { return Theme.levelGreen }
        let raise = maxCornerHeight - cornerHeight(end, side)
        if raise < 3 { return Color(.systemGray3) }   // a high corner — it stays on the ground
        return advice.beyondRamp ? Theme.needsBigRamp : Theme.needsRamp
    }

    /// The recommended ramp step for a wheel, if it's one the advice actually ramps (nil when
    /// beyond range, so no misleading figure is stamped on a van that needs repositioning).
    private func stepBadge(_ end: End, _ side: Side) -> Int? {
        var candidates: [Int] = []
        if let w = advice.wheel, w.end == end, w.side == side { candidates.append(w.stepMM) }
        if let ls = advice.longStepMM, advice.lowEnd == end { candidates.append(ls) }
        return candidates.max()
    }

    // MARK: - Step instructions (per axis, honest about un-rampable tilts)

    private enum StepState { case level, ramp(String, Color), beyond }

    private var lateralState: StepState {
        if advice.lateralBeyondRamp { return .beyond }
        if let w = advice.wheel {
            return .ramp("\(w.wheelName) · \(w.stepMM)mm ramp, start ~\(w.placementCM)cm out", severity(w.stepMM))
        }
        return .level
    }

    private var longState: StepState {
        if advice.longBeyondRamp { return .beyond }
        if let s = advice.longStepMM, let p = advice.longPlacementCM, let e = advice.lowEnd {
            return .ramp("\(e == .front ? "Front" : "Rear") wheels · \(s)mm ramp, start ~\(p)cm out", severity(s))
        }
        return .level
    }

    private func severity(_ step: Int) -> Color {
        guard let idx = config.activeStepsMM.firstIndex(of: step) else { return Theme.needsRamp }
        return idx >= config.activeStepsMM.count - 1 ? Theme.needsBigRamp : Theme.needsRamp
    }

    private var stepsCard: some View {
        VStack(spacing: 0) {
            stepLine(title: "Side-to-side", state: lateralState)
            Divider().padding(.leading, 48)
            stepLine(title: "Front-to-back", state: longState)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func stepLine(title: String, state: StepState) -> some View {
        let (icon, iconColor, detail, detailColor): (String, Color, String, Color) = {
            switch state {
            case .level:
                return ("checkmark.circle.fill", Theme.levelGreen, "level", Theme.levelGreen)
            case .beyond:
                return ("exclamationmark.triangle.fill", Theme.needsBigRamp,
                        "too steep for a ramp — reposition", Theme.needsBigRamp)
            case .ramp(let text, let c):
                return ("arrow.up.forward.circle.fill", c, text, Color(.secondaryLabel))
            }
        }()
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(iconColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(detailColor)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // MARK: - Details (Pro: tolerance + exact per-corner offsets)

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
            Button("Way off (40° nose-up)") { motion.simulate(rollDeg: 0.2, pitchDeg: 40) }
        }
    }
    #endif
}
