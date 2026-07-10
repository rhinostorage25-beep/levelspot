import SwiftUI
import LevelSpotCore

/// The one screen. A big dial you glance at from the driver's seat while you drive up your ramps:
/// OUTER ring = sun (park facing the right way), INNER bubble = level (drive up till it centres).
/// A loud alert when level, and an upfront "you'll never level here" pop-up when the tilt beats
/// your ramps. Calibration lives behind a guarded menu so a stray tap can't corrupt it.
struct LevelScanView: View {
    let config: VehicleConfig

    @Environment(MotionService.self) private var motion
    @Environment(LocationService.self) private var location
    @Environment(EntitlementStore.self) private var entitlements

    @State private var audio = AudioCoach()
    @State private var sunPref: SunPreference = .sun
    @State private var showSaveSheet = false
    @State private var showCalibrateConfirm = false
    @State private var wasLevel = false

    private let dialSize: CGFloat = 300

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

    // Sun (evening) target relative to where the nose currently points.
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

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !plan.canLevel { cantLevelBanner }
                dial
                levelStatus
                sunStatus
                if !isLevel && plan.canLevel { rampHint }
                sunToggle
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Level")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { saveBar }
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
            if nowLevel && !wasLevel { Haptics.levelReached(); audio.alertLevel() }
            wasLevel = nowLevel
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Calibrate — I'm on flat ground") { showCalibrateConfirm = true }
                    if motion.isCalibrated {
                        Button("Reset calibration", role: .destructive) { motion.resetCalibration() }
                    }
                } label: {
                    Image(systemName: motion.isCalibrated ? "scope" : "exclamationmark.triangle")
                }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarLeading) { simulateMenu }
            #endif
        }
        .alert("Set level here?", isPresented: $showCalibrateConfirm) {
            Button("Set level") { motion.calibrateHere(); Haptics.saved() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(degOff > 8
                 ? "This spot reads \(String(format: "%.0f", degOff))° off — that doesn't look flat. Only calibrate here if you're certain it's level."
                 : "Only on ground you KNOW is flat. It zeroes the phone/mount tilt.")
        }
    }

    // MARK: - The dial

    private var dial: some View {
        let accent: Color = isLevel ? Theme.levelGreen : Theme.needsRamp
        return ZStack {
            Circle().fill(accent.opacity(0.16)).frame(width: dialSize + 18, height: dialSize + 18).blur(radius: 8)
            Circle().fill(Color.black.opacity(0.9)).frame(width: dialSize, height: dialSize)

            // Outer SUN ring
            Circle().stroke(Theme.sun.opacity(0.35), lineWidth: 1.5).frame(width: dialSize - 8, height: dialSize - 8)
            Circle()
                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1.5, 10]))
                .frame(width: dialSize - 26, height: dialSize - 26)
            ScopeTriangle().fill(sunAligned ? Theme.levelGreen : Theme.sun)   // NOSE marker (top)
                .frame(width: 13, height: 10).offset(y: -(dialSize / 2) + 4)
            sunMarker

            // Inner LEVEL target
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5).frame(width: 132, height: 132)
            Circle().stroke(Color.white.opacity(0.22), lineWidth: 1).frame(width: 70, height: 70)
            ScopeReticle().stroke(Color.white.opacity(0.5), lineWidth: 1.2).frame(width: 150, height: 150)

            // The bubble — floats toward the HIGH side (like a spirit level); centre = level.
            Circle()
                .fill((isLevel ? Theme.levelGreen : Theme.needsRamp).opacity(0.9))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                .offset(x: bubbleOffset.width, y: bubbleOffset.height)
                .animation(.snappy(duration: 0.12), value: bubbleOffset)
        }
        .frame(width: dialSize + 18, height: dialSize + 18)
        .frame(maxWidth: .infinity)
    }

    private var bubbleOffset: CGSize {
        let scale: CGFloat = 16
        let cap: CGFloat = 52
        let x = min(max(CGFloat(-motion.rollDeg) * scale, -cap), cap)      // left high → bubble left
        let y = min(max(CGFloat(-motion.pitchDeg) * scale, -cap), cap)     // nose high → bubble up
        return CGSize(width: x, height: y)
    }

    @ViewBuilder private var sunMarker: some View {
        if let rel = sunRel {
            ZStack {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(sunAligned ? Theme.levelGreen : Theme.sun)
                    .offset(y: -(dialSize / 2) + 22)
            }
            .frame(width: dialSize, height: dialSize)
            .rotationEffect(.degrees(rel))
            .animation(.snappy, value: rel)
        }
    }

    // MARK: - Status + hints

    private var levelStatus: some View {
        VStack(spacing: 4) {
            Text(isLevel ? "LEVEL" : String(format: "%.1f° off", degOff))
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(isLevel ? Theme.levelGreen : Color(.label))
                .contentTransition(.numericText())
            Text(isLevel ? "Stop — handbrake on." : levelDirection)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var levelDirection: String {
        var parts: [String] = []
        if abs(motion.pitchDeg) > 0.3 { parts.append(motion.pitchDeg > 0 ? "nose high" : "nose low") }
        if abs(motion.rollDeg) > 0.3 { parts.append(motion.rollDeg > 0 ? "left high" : "right high") }
        return parts.isEmpty ? "almost there" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var sunStatus: some View {
        if let _ = sunRel {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").foregroundStyle(sunAligned ? Theme.levelGreen : Theme.sun)
                Text(sunAligned
                     ? "Facing right for evening \(sunPref == .sun ? "sun" : "shade")."
                     : "Turn the van until the sun marker reaches the nose.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var rampHint: some View {
        let wheels = plan.ramps.map { $0.wheelName }.joined(separator: " & ")
        let step = plan.ramps.map { $0.stepMM ?? 0 }.max() ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.needsRamp)
            Text("Ramp \(wheels) · ~\(step)mm")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var cantLevelBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.needsBigRamp)
            VStack(alignment: .leading, spacing: 2) {
                Text("You'll never level here").font(.callout.weight(.bold)).foregroundStyle(Theme.needsBigRamp)
                Text("Needs ~\(neededMM)mm but your ramps are \(maxStep)mm. Move to flatter ground, or add packing under the ramps.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.needsBigRamp.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sunToggle: some View {
        Picker("", selection: $sunPref) {
            Text("Chase sun").tag(SunPreference.sun)
            Text("Find shade").tag(SunPreference.shade)
        }
        .pickerStyle(.segmented)
    }

    private var saveBar: some View {
        Button { showSaveSheet = true } label: {
            Text(isLevel ? "Save this pitch" : "Save anyway").font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isLevel ? Theme.levelGreen : Color.accentColor)
        .controlSize(.large)
        .padding()
        .background(.bar)
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
