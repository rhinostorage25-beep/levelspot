import SwiftUI
import LevelSpotCore

/// The one screen — a guided level. FIXED layout: the dial never moves and every text zone is a
/// constant-height slot whose content swaps but whose size never changes, so nothing jumps as the
/// tilt crosses thresholds. A coach line + one button walk you through: Start → drive up → level.
/// The "you're level" alert only arms after you tap Start, so it doesn't chime while you handle it.
struct LevelScanView: View {
    let config: VehicleConfig

    @Environment(MotionService.self) private var motion
    @Environment(LocationService.self) private var location
    @Environment(EntitlementStore.self) private var entitlements

    @State private var audio = AudioCoach()
    @State private var sunPref: SunPreference = .sun
    @State private var armed = false
    @State private var showSaveSheet = false
    @State private var showCalibrate = false
    @State private var wasLevel = false

    private let dialSize: CGFloat = 280

    // MARK: - Derived

    private var plan: LevelPlan {
        RampAdvisor.plan(rollDeg: motion.rollDeg, pitchDeg: motion.pitchDeg,
                         trackFrontMM: Double(config.trackFrontMM), trackRearMM: Double(config.trackRearMM),
                         wheelbaseMM: Double(config.wheelbaseMM),
                         stepsMM: config.activeStepsMM, tolerance: .comfort)
    }
    private var isLevel: Bool { plan.isLevel }
    private var degOff: Double { max(abs(motion.rollDeg), abs(motion.pitchDeg)) }
    private var maxStep: Int { config.activeStepsMM.max() ?? 0 }
    private var neededMM: Int { plan.wheels.map { $0.liftMM }.max() ?? 0 }

    private var eveningDate: Date { Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date() }
    private var eveningSun: SunPosition? {
        guard let lat = location.latitude, let lon = location.longitude else { return nil }
        return SolarPosition.at(latitude: lat, longitude: lon, date: eveningDate)
    }
    private var sunTarget: Double? {
        guard let s = eveningSun, s.isUp else { return nil }
        return SolarPosition.vanHeadingForAwning(sunAzimuthDeg: s.azimuthDeg,
                                                 awningOffsetDeg: config.livingSide.awningOffsetDeg,
                                                 preference: sunPref)
    }
    private var sunRel: Double? {
        guard let t = sunTarget, let cur = location.headingDeg else { return nil }
        var d = (t - Double(cur)).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
    private var sunAligned: Bool { sunRel.map { abs($0) < 10 } ?? false }

    // MARK: - Body (fixed layout — nothing here changes size as you tilt)

    var body: some View {
        VStack(spacing: 14) {
            noticeZone
            dial
            levelStatus
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Level")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showSaveSheet) {
            SavePitchSheet(config: config,
                           corners: LevelMath.cornerHeights(rollDeg: motion.rollDeg, pitchDeg: motion.pitchDeg,
                                                            trackFrontMM: Double(config.trackFrontMM),
                                                            trackRearMM: Double(config.trackRearMM),
                                                            wheelbaseMM: Double(config.wheelbaseMM)),
                           isLevel: isLevel)
        }
        .onAppear { motion.start(); audio.start(); location.requestAndStart() }
        .onDisappear { motion.stop(); audio.stop() }
        .onChange(of: isLevel) { _, nowLevel in
            if nowLevel && !wasLevel && armed { Haptics.levelReached(); audio.alertLevel() }
            wasLevel = nowLevel
        }
        .sheet(isPresented: $showCalibrate) { CalibrateView() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { calibrateButton }
            ToolbarItem(placement: .topBarTrailing) { sunMenu }
            #if DEBUG
            ToolbarItem(placement: .topBarLeading) { simulateMenu }
            #endif
        }
    }

    // MARK: - Notice zone (fixed height — the coach line)

    private var noticeZone: some View {
        let n = notice
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.icon).font(.title3).foregroundStyle(n.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title).font(.callout.weight(.bold)).foregroundStyle(n.subtle ? Color(.label) : n.tint)
                Text(n.message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(height: 116, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(n.subtle ? Color(.secondarySystemGroupedBackground) : n.tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var notice: (icon: String, tint: Color, title: String, message: String, subtle: Bool) {
        if !plan.canLevel {
            return ("exclamationmark.triangle.fill", Theme.needsBigRamp, "You'll never level here",
                    "Needs ~\(neededMM)mm but your ramps are \(maxStep)mm. Move to flatter ground, or add packing.", false)
        }
        if !armed {
            if isLevel {
                return ("checkmark.circle.fill", Theme.levelGreen, "Already level", "You're good — park up, or save it below.", false)
            }
            let wheels = plan.ramps.map { $0.wheelName }.joined(separator: " & ")
            let step = plan.ramps.map { $0.stepMM ?? 0 }.max() ?? 0
            return ("arrow.up.circle.fill", Theme.needsRamp, "Ramp \(wheels) · ~\(step)mm",
                    "Drop your ramps in front of those wheels, then tap Start.", false)
        }
        if isLevel {
            return ("checkmark.circle.fill", Theme.levelGreen, "Level — handbrake on", "Nailed it. Save this pitch below.", false)
        }
        return ("waveform", Color(.secondaryLabel), "Drive up slowly", "Watch the dial — a chime tells you the moment you're level.", true)
    }

    // MARK: - The dial (nothing here changes SIZE; only colours/positions animate)

    private var dial: some View {
        let spyRed = Color(red: 0.98, green: 0.16, blue: 0.22)
        let target: Color = isLevel ? Theme.levelGreen : spyRed   // level scope: red targeting → green lock
        return ZStack {
            Circle().fill(target.opacity(0.20)).frame(width: dialSize + 18, height: dialSize + 18).blur(radius: 9)
            Circle().fill(Color(red: 0.09, green: 0.09, blue: 0.11)).frame(width: dialSize, height: dialSize)

            // Outer SUN ring — amber band (the sun)
            Circle().stroke(Theme.sun.opacity(0.6), lineWidth: 2.5).frame(width: dialSize - 8, height: dialSize - 8)
            Circle()
                .stroke(target.opacity(0.4), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1.5, 10]))
                .frame(width: dialSize - 26, height: dialSize - 26)
            ScopeTriangle().fill(sunAligned ? Theme.levelGreen : Theme.sun)   // NOSE marker (top)
                .frame(width: 22, height: 17).offset(y: -(dialSize / 2) + 3)
            sunMarker

            // Inner LEVEL target — red targeting scope
            Circle().stroke(target.opacity(0.5), lineWidth: 1.5).frame(width: 122, height: 122)
            Circle().stroke(target.opacity(0.35), lineWidth: 1).frame(width: 66, height: 66)
            ScopeReticle().stroke(target.opacity(0.7), lineWidth: 1.3).frame(width: 140, height: 140)

            Circle()
                .fill(target)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                .shadow(color: target.opacity(0.9), radius: 9)
                .offset(x: bubbleOffset.width, y: bubbleOffset.height)
                .animation(.snappy(duration: 0.12), value: bubbleOffset)
        }
        .frame(width: dialSize + 18, height: dialSize + 18)
        .frame(maxWidth: .infinity)
    }

    private var bubbleOffset: CGSize {
        let scale: CGFloat = 15
        let cap: CGFloat = 48
        let x = min(max(CGFloat(-motion.rollDeg) * scale, -cap), cap)
        let y = min(max(CGFloat(-motion.pitchDeg) * scale, -cap), cap)
        return CGSize(width: x, height: y)
    }

    @ViewBuilder private var sunMarker: some View {
        if let rel = sunRel {
            ZStack {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(sunAligned ? Theme.levelGreen : Theme.sun)
                    .shadow(color: (sunAligned ? Theme.levelGreen : Theme.sun).opacity(0.9), radius: 7)
                    .offset(y: -(dialSize / 2) + 28)
            }
            .frame(width: dialSize, height: dialSize)
            .rotationEffect(.degrees(rel))
            .animation(.snappy, value: rel)
        }
    }

    // MARK: - Level status (fixed height)

    private var levelStatus: some View {
        VStack(spacing: 4) {
            Text(isLevel ? "LEVEL" : String(format: "%.1f° off", degOff))
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundStyle(isLevel ? Theme.levelGreen : Color(.label))
                .contentTransition(.numericText())
            Text(isLevel ? "Stop — handbrake on." : levelDirection)
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(height: 92)
    }

    private var levelDirection: String {
        var parts: [String] = []
        if abs(motion.pitchDeg) > 0.3 { parts.append(motion.pitchDeg > 0 ? "nose high" : "nose low") }
        if abs(motion.rollDeg) > 0.3 { parts.append(motion.rollDeg > 0 ? "left high" : "right high") }
        return parts.isEmpty ? "almost there" : parts.joined(separator: " · ")
    }

    // MARK: - Bottom bar (Start → Save)

    @ViewBuilder private var bottomBar: some View {
        Group {
            if !armed {
                Button { armed = true; wasLevel = isLevel } label: {
                    Label("Start levelling", systemImage: "scope").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 12) {
                    Button("Stop") { armed = false }
                        .buttonStyle(.bordered)
                    Button(isLevel ? "Save this pitch" : "Save anyway") { showSaveSheet = true }
                        .buttonStyle(.borderedProminent)
                        .tint(isLevel ? Theme.levelGreen : Color.accentColor)
                }
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    // MARK: - Toolbar menus

    private var calibrateButton: some View {
        Button { showCalibrate = true } label: {
            Image(systemName: motion.isCalibrated ? "scope" : "exclamationmark.triangle")
        }
    }

    private var sunMenu: some View {
        Menu {
            Button { sunPref = .sun } label: {
                Label("Chase sun", systemImage: sunPref == .sun ? "checkmark" : "sun.max")
            }
            Button { sunPref = .shade } label: {
                Label("Find shade", systemImage: sunPref == .shade ? "checkmark" : "cloud.sun")
            }
        } label: {
            Image(systemName: "sun.max")
        }
    }

    #if DEBUG
    private var simulateMenu: some View {
        Menu("Sim") {
            Button("Level") { motion.simulate(rollDeg: 0.1, pitchDeg: 0.05) }
            Button("Nose low 2.9°") { motion.simulate(rollDeg: 0.2, pitchDeg: -2.9) }
            Button("Left low 2.2°") { motion.simulate(rollDeg: -2.2, pitchDeg: 0) }
            Button("Way off (can't level)") { motion.simulate(rollDeg: 0.2, pitchDeg: -6) }
        }
    }
    #endif
}
