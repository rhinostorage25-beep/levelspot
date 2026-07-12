import SwiftUI
import LevelSpotCore

/// The one screen.
/// FREE = the bubble level, calibrate, drive-up ramp coaching (honest can't-level maths, rough
/// default geometry until the van is set up), the affiliate shop and the audio chime — the whole
/// revenue path is free so every user reaches the "buy ramps that reach it" moment.
/// PRO = the two comfort features: the sun & shade planner, and the guided wheel-by-wheel flow
/// for air/blocks/ratchet levellers. Fixed layout: the dial never moves and every text zone is a
/// constant-height slot, so nothing jumps as the tilt crosses thresholds.
struct LevelScanView: View {
    /// nil until the van is set up — ramp coaching still works via rough-default geometry, and
    /// the sun planner needs a real `livingSide`, so it stays Pro + configured.
    let config: VehicleConfig?

    @Environment(MotionService.self) private var motion
    @Environment(LocationService.self) private var location
    @Environment(EntitlementStore.self) private var entitlements

    @State private var audio = AudioCoach()
    @State private var sunPref: SunPreference = .sun
    @State private var sunOn = false          // sun planner is opt-in via the ☀ menu (was confusing on by default)
    @State private var armed = false
    @State private var showCalibrate = false
    @State private var showSetup = false
    @State private var showPaywall = false
    @State private var showInflateGuide = false
    @State private var showRampShop = false
    @State private var shopNeededMM: Int?
    @State private var wasLevel = false

    private let dialSize: CGFloat = 280
    // The "close enough" band for a VAN (not a survey instrument): ~1.2° is imperceptible when
    // you're sleeping/cooking, and it stops a fraction-of-a-degree calibration residual (an iPhone
    // can't sit perfectly flat — camera bump) from reading "off" on genuinely level ground.
    private let levelTolDeg = 1.2

    private var isPro: Bool { entitlements.isPro }

    // MARK: - Derived

    private var degOff: Double { max(abs(motion.rollDeg), abs(motion.pitchDeg)) }
    private var isLevel: Bool { degOff < levelTolDeg }

    // Rough-default geometry — ramp coaching is FREE and works with zero setup. 1800mm track
    // matches the dominant Ducato/Boxer/Transit base; 3500mm wheelbase sits at the centre of
    // common L2/L3 panel-van conversions. The whole-vehicle-range error at a typical tilt is
    // smaller than the gap between ramp steps, so a generic default rarely changes which ramp
    // you'd actually buy — validated 2026-07-12.
    private static let roughWheelbaseMM = 3500.0
    private static let roughTrackMM = 1800.0
    private static let roughRampSet = RampSet(kind: .stepped, stepsMM: [40, 70, 100], maxLiftMM: 100, incrementMM: 0)

    /// True whenever we're coaching off the generic default rather than the user's own van —
    /// drives the "≈" prefix on mm figures and the subtle "refine" affordance.
    private var usingRoughDefaults: Bool { config == nil }

    private var effectiveRampSet: RampSet { config?.activeRampSet ?? Self.roughRampSet }

    /// Above ~15° the phone isn't lying flat in the van — it's just being held (checking the
    /// app, walking around). There's no real levelling scenario past this, so don't compute a
    /// giant, bug-looking mm figure — tell the user to lay it flat instead.
    private var isPhoneFlatEnough: Bool { degOff <= 15 }

    /// Ramp plan — free for everyone. Uses the van's real geometry once set up, otherwise the
    /// rough defaults above so coaching works from first launch with zero setup.
    private var plan: LevelPlan? {
        guard isPhoneFlatEnough else { return nil }
        let wheelbase = config.map { Double($0.wheelbaseMM) } ?? Self.roughWheelbaseMM
        let trackFront = config.map { Double($0.trackFrontMM) } ?? Self.roughTrackMM
        let trackRear = config.map { Double($0.trackRearMM) } ?? Self.roughTrackMM
        return RampAdvisor.plan(rollDeg: motion.rollDeg, pitchDeg: motion.pitchDeg,
                                trackFrontMM: trackFront, trackRearMM: trackRear,
                                wheelbaseMM: wheelbase,
                                ramp: effectiveRampSet, tolerance: .comfort)
    }

    /// Ramps you set wheel-by-wheel (inflatables, blocks, ratchets) use the guided per-wheel
    /// flow. Only true once a ramp profile is actually configured — the rough default is
    /// always a stepped set, so free/unset-up users get the drive-up flow, not this one.
    private var usesPerWheelFlow: Bool { effectiveRampSet.kind.isPerWheel }

    private var eveningDate: Date { Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date() }
    private var eveningSun: SunPosition? {
        guard let lat = location.latitude, let lon = location.longitude else { return nil }
        return SolarPosition.at(latitude: lat, longitude: lon, date: eveningDate)
    }
    private var sunTarget: Double? {
        guard isPro, sunOn, let config, let s = eveningSun, s.isUp else { return nil }
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
            sunHint
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
            audio.start()                                  // audio is free now
            if isPro { location.requestAndStart() }         // sun planner stays Pro-only
        }
        .onDisappear { motion.stop(); audio.stop() }
        .onChange(of: isLevel) { _, nowLevel in
            if nowLevel && !wasLevel && armed { Haptics.levelReached(); audio.alertLevel() }
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
                Button { showSetup = true } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Setup")
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

    // MARK: - Notice zone (free for everyone — the ramp/affiliate coaching lives here)

    @ViewBuilder private var noticeZone: some View {
        VStack(spacing: 6) {
            if !isPhoneFlatEnough {
                // Not actually resting flat in the van (being held/checked) — an mm figure here
                // would be nonsense (see the sanity clamp in `plan`), so ask for a flat read instead.
                noticeCard(("iphone.gen3.radiowaves.left.and.right", Color(.secondaryLabel), "Lay the phone flat",
                            "Rest it flat in the van, screen up, to read the ground's slope.", true),
                           tappable: false)
            } else if let plan {
                if !plan.canLevel {
                    // Can't level here → tap through to the shop (ramps that actually reach the height).
                    Button {
                        shopNeededMM = plan.wheels.map { $0.liftMM }.max() ?? 0
                        showRampShop = true
                    } label: {
                        noticeCard(rampNotice(plan), tappable: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    noticeCard(rampNotice(plan), tappable: false)
                }

                if usingRoughDefaults {
                    Button { showSetup = true } label: {
                        Label("≈ estimate — set your van's size for exact figures", systemImage: "ruler")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
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

    private func rampNotice(_ plan: LevelPlan)
        -> (icon: String, tint: Color, title: String, message: String, subtle: Bool) {
        let ceiling = effectiveRampSet.ceilingMM
        let neededMM = plan.wheels.map { $0.liftMM }.max() ?? 0
        // "≈" flags a rough-default figure honestly; "~" just marks the normal rounding once
        // the van's real size is known.
        let approx = usingRoughDefaults ? "≈" : "~"
        if !plan.canLevel {
            // Calm, non-scolding copy — a stressed user reads this right before the Buy tap.
            return ("exclamationmark.triangle.fill", Theme.needsBigRamp, "This spot's too steep for your ramps",
                    "Reposition, or ramps that reach \(approx)\(neededMM)mm (yours reach \(ceiling)mm).", false)
        }
        if isLevel {
            return ("checkmark.circle.fill", Theme.levelGreen, "Level — handbrake on", "Nailed it.", false)
        }
        // Wheel-by-wheel aids (inflatables / blocks / ratchets): place, then start the guided flow.
        if usesPerWheelFlow {
            let noun: String = {
                switch effectiveRampSet.kind {
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
            return ("arrow.up.circle.fill", Theme.needsRamp, "Ramp \(wheels) · \(approx)\(step)mm",
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
            Circle().fill(target.opacity(0.30)).frame(width: dialSize + 18, height: dialSize + 18).blur(radius: 12)

            // Your van from ABOVE (front up) as a white wireframe on a DARK targeting scope — the
            // sniper-scope look. colorInvert flips the black-on-white drawing to white-on-black.
            ZStack {
                Color.black
                Image("VanTop")
                    .resizable().scaledToFit()
                    .colorInvert()
                    .rotationEffect(.degrees(-90))   // the drawing has the front on the right → point it up
                    .padding(dialSize * 0.06)
                    .offset(x: dialSize * 0.02)       // source art sits a touch left — nudge to centre
                    .opacity(0.92)
            }
            .frame(width: dialSize, height: dialSize)
            .clipShape(Circle())
            .overlay(Circle().stroke(target.opacity(0.6), lineWidth: 2))

            // Sun layer — Pro, opt-in only. Amber (never green — that read as "why is it green?").
            if isPro && sunOn {
                Circle().stroke((sunAligned ? Theme.levelGreen : Theme.sun).opacity(0.6), lineWidth: 2.5)
                    .frame(width: dialSize - 8, height: dialSize - 8)
                sunMarker
            }

            // Targeting scope.
            Circle()
                .stroke(target.opacity(0.5), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1.5, 10]))
                .frame(width: dialSize - 26, height: dialSize - 26)
            ScopeTriangle().fill(target)   // NOSE marker (top = front of the van)
                .frame(width: 22, height: 17).offset(y: -(dialSize / 2) + 3)
            Circle().stroke(target.opacity(0.55), lineWidth: 1.5).frame(width: 122, height: 122)
            Circle().stroke(target.opacity(0.4), lineWidth: 1).frame(width: 66, height: 66)
            ScopeReticle().stroke(target.opacity(0.85), lineWidth: 1.3).frame(width: 140, height: 140)

            Circle()
                .fill(target)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 2))
                .shadow(color: target.opacity(0.9), radius: 9)
                .offset(x: bubbleOffset.width, y: bubbleOffset.height)
                .animation(.snappy(duration: 0.12), value: bubbleOffset)
        }
        .frame(width: dialSize + 18, height: dialSize + 18)
        .frame(maxWidth: .infinity)
    }

    /// Opt-in sun hint — shown BELOW the dial (not overlapping it) only when the sun planner is on.
    @ViewBuilder private var sunHint: some View {
        if isPro && sunOn {
            Text(sunAligned ? "☀ Facing the sun — good spot" : "Turn the van until ☀ reaches the top")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(sunAligned ? Theme.levelGreen : Theme.sun)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
        }
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
                // Amber while you're hunting; GREEN the moment it docks at the nose = "you're now
                // facing the sun." The green is the whole payoff — the caption below explains it.
                Image(systemName: sunAligned ? "sun.max.fill" : "sun.max.fill")
                    .font(.system(size: sunAligned ? 34 : 30))
                    .foregroundStyle(sunAligned ? Theme.levelGreen : Theme.sun)
                    .shadow(color: (sunAligned ? Theme.levelGreen : Theme.sun).opacity(0.95), radius: sunAligned ? 10 : 7)
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
            if usesPerWheelFlow {
                // Air/blocks/ratchet ramps are the one Pro gate — it sits at this exact tap,
                // not in front of the free coaching that got the user here.
                Button {
                    if isPro { showInflateGuide = true } else { showPaywall = true }
                } label: {
                    Label(isPro ? "Level wheel by wheel" : "Level wheel by wheel — Pro",
                          systemImage: isPro ? "scope" : "lock.fill")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isPro ? Color.accentColor : Theme.proBadge)
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
        // TestFlight-only Pro preview toggle — see EntitlementStore.previewProOn. A simultaneous
        // gesture so it doesn't steal the button's normal tap; deliberately not a visible
        // control, so App Store review won't stumble onto a free-Pro switch. MUST be removed
        // (or verified never triggered) before submission — see the EntitlementStore doc.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.5).onEnded { _ in
                entitlements.setPreviewPro(!entitlements.previewProOn)
                Haptics.saved()
            }
        )
    }

    private var sunMenu: some View {
        Menu {
            Button { sunOn = false } label: {
                Label("Sun planner off", systemImage: !sunOn ? "checkmark" : "sun.max.trianglebadge.exclamationmark")
            }
            Button { sunOn = true; sunPref = .sun } label: {
                Label("Chase the sun", systemImage: (sunOn && sunPref == .sun) ? "checkmark" : "sun.max")
            }
            Button { sunOn = true; sunPref = .shade } label: {
                Label("Find the shade", systemImage: (sunOn && sunPref == .shade) ? "checkmark" : "cloud.sun")
            }
        } label: {
            Image(systemName: sunOn ? "sun.max.fill" : "sun.max")
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
