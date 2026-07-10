import SwiftUI
import LevelSpotCore

/// The one screen.
/// FREE = a simple targeting bubble level: the dial + degrees + LEVEL state + calibrate. No setup.
/// PRO unlocks the sun ring, ramp coaching (drive-up targets + honest can't-level maths) and audio
/// levelling. Fixed layout: the dial never moves and every text zone is a constant-height slot, so
/// nothing jumps as the tilt crosses thresholds.
struct LevelScanView: View {
    /// nil for a free user, or a Pro user who hasn't set their van up yet. Only the Pro ramp/sun
    /// features need it — the basic level works off the motion sensor alone.
    let config: VehicleConfig?

    @Environment(MotionService.self) private var motion
    @Environment(LocationService.self) private var location
    @Environment(EntitlementStore.self) private var entitlements

    @State private var audio = AudioCoach()
    @State private var sunPref: SunPreference = .sun
    @State private var armed = false
    @State private var showCalibrate = false
    @State private var showSetup = false
    @State private var showPaywall = false
    @State private var showInflateGuide = false
    @State private var showRampShop = false
    @State private var shopNeededMM: Int?
    @State private var wasLevel = false

    private let dialSize: CGFloat = 280
    private let levelTolDeg = 0.45   // the bubble-level "close enough" band, sensor-only (config-free)

    private var isPro: Bool { entitlements.isPro }

    // MARK: - Derived

    private var degOff: Double { max(abs(motion.rollDeg), abs(motion.pitchDeg)) }
    private var isLevel: Bool { degOff < levelTolDeg }

    /// Pro ramp plan — nil for free users or before the van is set up.
    private var plan: LevelPlan? {
        guard isPro, let config else { return nil }
        return RampAdvisor.plan(rollDeg: motion.rollDeg, pitchDeg: motion.pitchDeg,
                                trackFrontMM: Double(config.trackFrontMM), trackRearMM: Double(config.trackRearMM),
                                wheelbaseMM: Double(config.wheelbaseMM),
                                ramp: config.activeRampSet, tolerance: .comfort)
    }

    /// Ramps you set wheel-by-wheel (inflatables, blocks, ratchets) use the guided per-wheel flow.
    private var usesPerWheelFlow: Bool { config?.activeRampSet.kind.isPerWheel ?? false }

    private var eveningDate: Date { Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date() }
    private var eveningSun: SunPosition? {
        guard let lat = location.latitude, let lon = location.longitude else { return nil }
        return SolarPosition.at(latitude: lat, longitude: lon, date: eveningDate)
    }
    private var sunTarget: Double? {
        guard isPro, let config, let s = eveningSun, s.isUp else { return nil }
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
            if isPro { noticeZone }
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
        .onAppear {
            motion.start()
            if isPro { audio.start(); location.requestAndStart() }   // audio + sun are Pro-only
        }
        .onDisappear { motion.stop(); audio.stop() }
        .onChange(of: isLevel) { _, nowLevel in
            if nowLevel && !wasLevel && armed && isPro { Haptics.levelReached(); audio.alertLevel() }
            wasLevel = nowLevel
        }
        .sheet(isPresented: $showCalibrate) { CalibrateView() }
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .sheet(isPresented: $showRampShop) { RampShopSheet(neededMM: shopNeededMM) }
        .fullScreenCover(isPresented: $showInflateGuide) {
            if let config { InflationGuideView(config: config) }
        }
        .navigationDestination(isPresented: $showSetup) { VehicleSetupView() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { if isPro { showSetup = true } else { showPaywall = true } } label: {
                    Image(systemName: "gearshape").accessibilityLabel(isPro ? "Setup" : "Unlock Pro")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { calibrateButton }
            if isPro {
                ToolbarItem(placement: .topBarTrailing) { sunMenu }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) { simulateMenu }
            #endif
        }
    }

    // MARK: - Notice zone (Pro only — fixed height coach line)

    @ViewBuilder private var noticeZone: some View {
        if let config, let plan {
            if !plan.canLevel {
                // Can't level here → tap through to the shop (ramps that actually reach the height).
                Button {
                    shopNeededMM = plan.wheels.map { $0.liftMM }.max() ?? 0
                    showRampShop = true
                } label: {
                    noticeCard(rampNotice(plan, config), tappable: true)
                }
                .buttonStyle(.plain)
            } else {
                noticeCard(rampNotice(plan, config), tappable: false)
            }
        } else {
            // Pro, but the van isn't set up yet — ramp coaching needs the dimensions.
            Button { showSetup = true } label: {
                noticeCard(("slider.horizontal.3", Theme.needsRamp, "Set up your van",
                            "Add your wheelbase, track & ramps to get drive-up ramp coaching.", false),
                           tappable: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func noticeCard(_ n: (icon: String, tint: Color, title: String, message: String, subtle: Bool),
                            tappable: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.icon).font(.title3).foregroundStyle(n.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title).font(.callout.weight(.bold)).foregroundStyle(n.subtle ? Color(.label) : n.tint)
                Text(n.message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if tappable {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(height: 116, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(n.subtle ? Color(.secondarySystemGroupedBackground) : n.tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func rampNotice(_ plan: LevelPlan, _ config: VehicleConfig)
        -> (icon: String, tint: Color, title: String, message: String, subtle: Bool) {
        let ceiling = config.activeRampSet.ceilingMM
        let neededMM = plan.wheels.map { $0.liftMM }.max() ?? 0
        if !plan.canLevel {
            return ("exclamationmark.triangle.fill", Theme.needsBigRamp, "You'll never level here",
                    "Needs ~\(neededMM)mm but your ramps reach \(ceiling)mm. Tap for ramps that reach it — or move / add packing.", false)
        }
        if isLevel {
            return ("checkmark.circle.fill", Theme.levelGreen, "Level — handbrake on", "Nailed it.", false)
        }
        // Wheel-by-wheel aids (inflatables / blocks / ratchets): place, then start the guided flow.
        if usesPerWheelFlow {
            let noun: String = {
                switch config.activeRampSet.kind {
                case .inflatable: return "air bags"
                case .blocks: return "blocks"
                default: return "levellers"
                }
            }()
            return ("arrow.up.circle.fill", Theme.needsRamp, "Ready when you are",
                    "Put your \(noun) under the low wheels, then tap Level wheel by wheel.", false)
        }
        // Drive-up ramps (stepped / wedge).
        if !armed {
            let wheels = plan.ramps.map { $0.wheelName }.joined(separator: " & ")
            let step = plan.ramps.map { $0.stepMM ?? 0 }.max() ?? 0
            return ("arrow.up.circle.fill", Theme.needsRamp, "Ramp \(wheels) · ~\(step)mm",
                    "Drop your ramps in front of those wheels, then tap Start.", false)
        }
        return ("waveform", Color(.secondaryLabel), "Drive up slowly",
                "Watch the dial — a chime tells you the moment you're level.", true)
    }

    // MARK: - The dial (nothing here changes SIZE; only colours/positions animate)

    private var dial: some View {
        let spyRed = Color(red: 0.98, green: 0.16, blue: 0.22)
        let target: Color = isLevel ? Theme.levelGreen : spyRed   // level scope: red targeting → green lock
        return ZStack {
            Circle().fill(target.opacity(0.20)).frame(width: dialSize + 18, height: dialSize + 18).blur(radius: 9)
            Circle().fill(Color(red: 0.09, green: 0.09, blue: 0.11)).frame(width: dialSize, height: dialSize)

            // Sun layer — Pro only.
            if isPro {
                Circle().stroke(Theme.sun.opacity(0.6), lineWidth: 2.5).frame(width: dialSize - 8, height: dialSize - 8)
                sunMarker
            }

            // Targeting scope — the free bubble level.
            Circle()
                .stroke(target.opacity(0.4), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1.5, 10]))
                .frame(width: dialSize - 26, height: dialSize - 26)
            ScopeTriangle().fill(target)   // NOSE marker (top)
                .frame(width: 22, height: 17).offset(y: -(dialSize / 2) + 3)
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

    // MARK: - Bottom bar

    @ViewBuilder private var bottomBar: some View {
        Group {
            if !isPro {
                Button { showPaywall = true } label: {
                    Label("Unlock Pro — ramps, sun & audio", systemImage: "lock.fill")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.proBadge)
            } else if usesPerWheelFlow {
                Button { showInflateGuide = true } label: {
                    Label("Level wheel by wheel", systemImage: "scope").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if !armed {
                Button { armed = true; wasLevel = isLevel } label: {
                    Label("Start levelling", systemImage: "scope").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { armed = false } label: {
                    Label(isLevel ? "Done — you're level" : "Stop",
                          systemImage: isLevel ? "checkmark.circle.fill" : "xmark")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isLevel ? Theme.levelGreen : Color.accentColor)
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
            Divider()
            Button("Toggle Pro (now: \(isPro ? "on" : "off"))") { entitlements.debugToggle() }
        }
    }
    #endif
}
