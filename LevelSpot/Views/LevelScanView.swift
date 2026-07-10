import SwiftUI
import LevelSpotCore

struct LevelScanView: View {
    let config: VehicleConfig

    @Environment(MotionService.self) private var motion
    @Environment(EntitlementStore.self) private var entitlements

    enum Stage { case measure, plan, levelling }
    struct Frozen: Equatable { let roll: Double; let pitch: Double }

    @State private var stage: Stage = .measure
    @State private var frozen: Frozen?
    @State private var driveForward = true
    @State private var tolerance: Tolerance = .comfort
    @State private var soundOn = true
    @State private var showPaywall = false
    @State private var showSaveSheet = false
    @State private var wasLevel = false
    @State private var audio = AudioCoach()

    // MARK: - Derived

    private var effectiveTolerance: Tolerance { entitlements.isPro ? tolerance : .comfort }

    private func planFrom(roll: Double, pitch: Double) -> LevelPlan {
        RampAdvisor.plan(rollDeg: roll, pitchDeg: pitch,
                         trackFrontMM: Double(config.trackFrontMM), trackRearMM: Double(config.trackRearMM),
                         wheelbaseMM: Double(config.wheelbaseMM),
                         stepsMM: config.activeStepsMM, tolerance: effectiveTolerance)
    }

    /// Recomputed from the live sensor — used while measuring and while driving up.
    private var livePlan: LevelPlan { planFrom(roll: motion.rollDeg, pitch: motion.pitchDeg) }
    /// The FROZEN plan (locked at Measure) — the fixed ramp list you act on. Falls back to live.
    private var planned: LevelPlan {
        if let f = frozen { return planFrom(roll: f.roll, pitch: f.pitch) }
        return livePlan
    }

    private func cornersFrom(roll: Double, pitch: Double) -> CornerHeights {
        LevelMath.cornerHeights(rollDeg: roll, pitchDeg: pitch,
                                trackFrontMM: Double(config.trackFrontMM), trackRearMM: Double(config.trackRearMM),
                                wheelbaseMM: Double(config.wheelbaseMM))
    }
    private var liveCorners: CornerHeights { cornersFrom(roll: motion.rollDeg, pitch: motion.pitchDeg) }
    private var liveOffMM: Double {
        let c = [liveCorners.fl, liveCorners.fr, liveCorners.rl, liveCorners.rr]
        return (c.max() ?? 0) - (c.min() ?? 0)
    }
    private var liveDegOff: Double { max(abs(motion.rollDeg), abs(motion.pitchDeg)) }
    private var toleranceMM: Double { Double(config.activeStepsMM.first ?? 44) / 2 * effectiveTolerance.multiplier }

    private var maxStep: Int { config.activeStepsMM.max() ?? 0 }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch stage {
                case .measure:   measureStage
                case .plan:      planStage
                case .levelling: levellingStage
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .sheet(isPresented: $showSaveSheet) {
            SavePitchSheet(config: config, corners: liveCorners, isLevel: livePlan.isLevel)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop(); audio.stop() }
        .onChange(of: liveOffMM) { _, _ in if stage == .levelling { pushAudioState() } }
        .onChange(of: soundOn) { _, _ in if stage == .levelling { pushAudioState() } }
        .onChange(of: livePlan.isLevel) { _, nowLevel in
            guard stage == .levelling else { return }
            if nowLevel && !wasLevel { Haptics.levelReached() }
            wasLevel = nowLevel
            pushAudioState()
        }
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) { simulateMenu }
            #endif
        }
    }

    private var navTitle: String {
        switch stage {
        case .measure:   return "Measure"
        case .plan:      return "Ramp plan"
        case .levelling: return "Levelling"
        }
    }

    // MARK: - Stage 1 · Measure

    private var measureStage: some View {
        VStack(spacing: 16) {
            infoBanner("car.side", "Park on the pitch and stop. Set the phone down flat where you'll measure, then tap Measure.")
            vanCard(livePlan, roll: motion.rollDeg, pitch: motion.pitchDeg)
            calibrateCard
        }
    }

    private var calibrateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: motion.isCalibrated ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(motion.isCalibrated ? Theme.levelGreen : Theme.needsRamp)
                Text(motion.isCalibrated ? "Calibrated" : "Calibrate before you measure")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text("Phones don't lie flat — the camera bump tilts them a degree or two. On ground you KNOW is flat, set the phone down the way you'll measure and tap Calibrate to zero it. You only need to do this occasionally.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                motion.calibrateHere()
                Haptics.saved()
            } label: {
                Label("Calibrate — I'm on flat ground", systemImage: "scope").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Stage 2 · Plan

    private var planStage: some View {
        VStack(spacing: 16) {
            planVerdict(planned)
            vanCard(planned, roll: frozen?.roll ?? 0, pitch: frozen?.pitch ?? 0)
            if !planned.isLevel {
                Picker("Driving onto the ramps", selection: $driveForward) {
                    Text("Drive forward on").tag(true)
                    Text("Reverse on").tag(false)
                }
                .pickerStyle(.segmented)
                rampList(planned)
            }
            if entitlements.isPro { toleranceControl }
        }
    }

    private func planVerdict(_ plan: LevelPlan) -> some View {
        let neutral = plan.canLevel && !plan.isLevel      // the normal "here's the plan" case
        let (text, tint, icon): (String, Color, String) = {
            if plan.isLevel {
                return ("Already level — you're good to park.", Theme.levelGreen, "checkmark.circle.fill")
            }
            if !plan.canLevel {
                return ("Can't get fully level here — the tilt needs \(plan.shortfallMM)mm more than your tallest ramp. Reposition, or level as best you can.",
                        Theme.needsBigRamp, "exclamationmark.triangle.fill")
            }
            let n = plan.ramps.count
            return ("Set \(n) ramp\(n == 1 ? "" : "s") as below, then start levelling.", Color(.label), "list.bullet.rectangle")
        }()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(neutral ? Color(.secondaryLabel) : tint)
            Text(text).font(.callout.weight(.medium)).foregroundStyle(neutral ? Color(.label) : tint)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(neutral ? Color(.secondarySystemGroupedBackground) : tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func rampList(_ plan: LevelPlan) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.ramps.enumerated()), id: \.offset) { i, w in
                if i > 0 { Divider().padding(.leading, 52) }
                rampRow(w)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func rampRow(_ w: WheelRamp) -> some View {
        let colour: Color = (w.stepMM == maxStep) ? Theme.needsBigRamp : Theme.needsRamp
        let placement = driveForward ? "in front of" : "behind"
        return HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(colour).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(w.wheelName) · \(w.stepMM ?? 0) mm ramp")
                    .font(.subheadline.weight(.semibold))
                Text("Place it \(placement) the tyre, thin end touching. Drive up ~\(w.placementCM ?? 0)cm until it's level.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var toleranceControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW LEVEL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Tolerance", selection: $tolerance) {
                ForEach(Tolerance.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Fridge operation and general comfort don't need the same precision.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Stage 3 · Levelling (drive up)

    private var levellingStage: some View {
        VStack(spacing: 16) {
            liveStatusCard
            vanCard(livePlan, roll: motion.rollDeg, pitch: motion.pitchDeg)
            rampReminder(planned)
            audioToggle
        }
    }

    private var liveStatusCard: some View {
        let level = livePlan.isLevel
        return VStack(spacing: 6) {
            Text(level ? "LEVEL" : String(format: "%.1f° off", liveDegOff))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(level ? Theme.levelGreen : Color(.label))
                .contentTransition(.numericText())
            Text(level ? "Stop and put the handbrake on." : "Drive up slowly — the tone rises and holds steady when you're level.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background((level ? Theme.levelGreen.opacity(0.14) : Color(.secondarySystemGroupedBackground)),
                    in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func rampReminder(_ plan: LevelPlan) -> some View {
        if !plan.ramps.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                Text(plan.ramps.map { "\($0.wheelName): \($0.stepMM ?? 0)mm" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var audioToggle: some View {
        Toggle(isOn: $soundOn) {
            Label(soundOn ? "Audio guide on" : "Audio guide off",
                  systemImage: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.subheadline)
        }
        .tint(Theme.levelGreen)
        .padding(.horizontal, 4)
    }

    // MARK: - Shared: van diagram + tilt readout

    private func vanCard(_ plan: LevelPlan, roll: Double, pitch: Double) -> some View {
        HStack(alignment: .center, spacing: 20) {
            vanDiagram(plan)
            tiltReadout(roll: roll, pitch: pitch)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .topTrailing) { estimatedBadge }
    }

    private func vanDiagram(_ plan: LevelPlan) -> some View {
        VStack(spacing: 5) {
            Text("FRONT").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundStyle(.tertiary)
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.tertiarySystemFill))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(.separator), lineWidth: 1))
                VStack {
                    HStack { tyre(plan, .front, .left); Spacer(); tyre(plan, .front, .right) }
                    Spacer()
                    HStack { tyre(plan, .rear, .left); Spacer(); tyre(plan, .rear, .right) }
                }
                .padding(12)
            }
            .frame(width: 132, height: 190)
            Text("REAR").font(.system(size: 10, weight: .heavy)).tracking(2).foregroundStyle(.tertiary)
        }
    }

    private func wheelRamp(_ plan: LevelPlan, _ end: End, _ side: Side) -> WheelRamp? {
        plan.wheels.first { $0.end == end && $0.side == side }
    }

    private func tyre(_ plan: LevelPlan, _ end: End, _ side: Side) -> some View {
        let w = wheelRamp(plan, end, side)
        let needs = w?.needsRamp ?? false
        let colour: Color = plan.isLevel ? Theme.levelGreen
            : (needs ? (plan.canLevel ? Theme.needsRamp : Theme.needsBigRamp) : Color(.systemGray3))
        return VStack(spacing: 4) {
            if end == .rear, let step = w?.stepMM { stepPill(step, colour) }
            RoundedRectangle(cornerRadius: 3).fill(colour).frame(width: 14, height: 30)
            if end == .front, let step = w?.stepMM { stepPill(step, colour) }
        }
    }

    private func stepPill(_ mm: Int, _ colour: Color) -> some View {
        Text("\(mm)mm")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(colour, in: Capsule())
    }

    private func tiltReadout(roll: Double, pitch: Double) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            tiltStat(title: "Side-to-side", deg: roll,
                     detail: abs(roll) < 0.2 ? "level" : (roll > 0 ? "left side high" : "right side high"))
            tiltStat(title: "Front-to-back", deg: pitch,
                     detail: abs(pitch) < 0.2 ? "level" : (pitch > 0 ? "nose high" : "nose low"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tiltStat(title: String, deg: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f°", abs(deg)))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(abs(deg) < 0.2 ? Theme.levelGreen : Color(.label))
                .contentTransition(.numericText())
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
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

    private func infoBanner(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Bottom bar (per stage)

    @ViewBuilder private var bottomBar: some View {
        Group {
            switch stage {
            case .measure:
                Button { freeze() } label: {
                    Label("Measure", systemImage: "scope").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

            case .plan:
                HStack(spacing: 12) {
                    Button("Re-measure") { reset() }
                        .buttonStyle(.bordered)
                    Button(planned.isLevel ? "Save pitch" : "Start levelling") {
                        if planned.isLevel { showSaveSheet = true } else { startLevelling() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large).frame(maxWidth: .infinity)

            case .levelling:
                HStack(spacing: 12) {
                    Button("Re-measure") { audio.stop(); reset() }
                        .buttonStyle(.bordered)
                    Button("Save pitch") { showSaveSheet = true }
                        .buttonStyle(.borderedProminent)
                        .tint(livePlan.isLevel ? Theme.levelGreen : Color.accentColor)
                }
                .controlSize(.large).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Actions

    private func freeze() {
        frozen = Frozen(roll: motion.rollDeg, pitch: motion.pitchDeg)
        stage = .plan
    }
    private func startLevelling() {
        stage = .levelling
        wasLevel = livePlan.isLevel
        audio.start()
        pushAudioState()
    }
    private func reset() {
        frozen = nil
        stage = .measure
    }
    private func pushAudioState() {
        audio.update(offMM: liveOffMM, toleranceMM: toleranceMM,
                     isLevel: livePlan.isLevel, beyond: !planned.canLevel, enabled: soundOn)
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
