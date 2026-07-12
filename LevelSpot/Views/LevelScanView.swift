import SwiftUI
import SwiftData
import LevelSpotCore

/// The one screen.
/// FREE = the bubble level, calibrate, drive-up ramp coaching (honest can't-level maths, rough
/// default geometry until the van is set up), the affiliate shop and the audio chime — the whole
/// revenue path is free so every user reaches the "buy ramps that reach it" moment.
/// PRO = the "Perfect Pitch" pack (see pro-pack-spec.md): all-day sun & shade planning with the
/// day arc, pitch memory, sleep tilt, multi-vehicle, and the guided wheel-by-wheel flow for
/// air/blocks/ratchet levellers. Fixed layout: the dial never moves and every text zone is a
/// constant-height slot, so nothing jumps as the tilt crosses thresholds.
struct LevelScanView: View {
    /// nil until the van is set up — ramp coaching still works via rough-default geometry, and
    /// the sun planner needs a real `livingSide`, so it stays Pro + configured.
    let config: VehicleConfig?

    @Environment(MotionService.self) private var motion
    @Environment(LocationService.self) private var location
    @Environment(EntitlementStore.self) private var entitlements

    // Pro pack data: the saved pitches (vehicles live in SettingsSheet's own query now).
    @Query private var pitches: [PitchRecord]
    // Sleep tilt — where the bed's head end is. Free tier ignores the stored value.
    @AppStorage("sleepHeadEnd") private var sleepHeadEndRaw = SleepHeadEnd.off.rawValue

    @State private var audio = AudioCoach()
    @State private var sunMoment: SunMoment?   // sun planner is opt-in via the ☀ menu; nil = off
    @State private var sunArcAzimuths: [Double] = []   // today's hourly sun azimuths (sun-up only)
    @State private var armed = false
    @State private var armPlan: LevelPlan?     // the plan when Start was tapped — the pitch "recipe"
    @State private var showCalibrate = false
    @State private var showSetup = false
    @State private var setupMode: VehicleSetupView.SetupMode = .editActive
    @State private var setupStart: Int?
    @State private var showSettings = false
    @State private var pendingSettings: SettingsAction?
    @State private var showPaywall = false
    @State private var showInflateGuide = false
    @State private var showRampShop = false
    @State private var showPitchTeaser = false   // free tier: the "Pro would remember this" moment
    @State private var pitchTeaserShown = false  // once per session — a tease, not a nag
    @State private var savePitchData: SavePitchData?
    @State private var shownPitch: PitchRecord?
    @State private var shopNeededMM: Int?
    @State private var wasLevel = false
    @State private var proToggleFired = false   // long-press fired — swallow the button tap once

    private let dialSize: CGFloat = 280
    // The "close enough" band for a VAN (not a survey instrument): ~1.2° is imperceptible when
    // you're sleeping/cooking, and it stops a fraction-of-a-degree calibration residual (an iPhone
    // can't sit perfectly flat — camera bump) from reading "off" on genuinely level ground.
    private let levelTolDeg = 1.2

    private var isPro: Bool { entitlements.isPro }

    // MARK: - Derived

    /// Sleep tilt (Pro): the whole screen — dial, degrees, coaching — aims at a target that sits
    /// `tiltDeg` high at the bed's head end, so "LEVEL" means "level, with your pillow up a touch".
    private var sleepHeadEnd: SleepHeadEnd {
        isPro ? (SleepHeadEnd(rawValue: sleepHeadEndRaw) ?? .off) : .off
    }
    private var effRollDeg: Double { motion.rollDeg - sleepHeadEnd.rollTargetDeg }
    private var effPitchDeg: Double { motion.pitchDeg - sleepHeadEnd.pitchTargetDeg }

    private var degOff: Double { max(abs(effRollDeg), abs(effPitchDeg)) }
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
    /// rough defaults above so coaching works from first launch with zero setup. Fed the
    /// sleep-adjusted attitude so ramp targets land on the same shifted "level" as the dial.
    private var plan: LevelPlan? {
        guard isPhoneFlatEnough else { return nil }
        let wheelbase = config.map { Double($0.wheelbaseMM) } ?? Self.roughWheelbaseMM
        let trackFront = config.map { Double($0.trackFrontMM) } ?? Self.roughTrackMM
        let trackRear = config.map { Double($0.trackRearMM) } ?? Self.roughTrackMM
        return RampAdvisor.plan(rollDeg: effRollDeg, pitchDeg: effPitchDeg,
                                trackFrontMM: trackFront, trackRearMM: trackRear,
                                wheelbaseMM: wheelbase,
                                ramp: effectiveRampSet, tolerance: .comfort)
    }

    /// Ramps you set wheel-by-wheel (inflatables, blocks, ratchets) use the guided per-wheel
    /// flow. Only true once a ramp profile is actually configured — the rough default is
    /// always a stepped set, so free/unset-up users get the drive-up flow, not this one.
    private var usesPerWheelFlow: Bool { effectiveRampSet.kind.isPerWheel }

    /// Sun position at the chosen moment (Pro sun planner). nil when the planner is off or
    /// there's no location fix yet.
    private var sunPosition: SunPosition? {
        guard let moment = sunMoment, let lat = location.latitude, let lon = location.longitude else { return nil }
        return SolarPosition.at(latitude: lat, longitude: lon, date: moment.date())
    }
    private var sunTarget: Double? {
        guard isPro, let moment = sunMoment, let config, let s = sunPosition, s.isUp else { return nil }
        return SolarPosition.vanHeadingForAwning(sunAzimuthDeg: s.azimuthDeg,
                                                 awningOffsetDeg: config.livingSide.awningOffsetDeg,
                                                 preference: moment.preference)
    }
    private var sunRel: Double? {
        guard let t = sunTarget, let cur = location.headingDeg else { return nil }
        return Self.signedDelta(t - Double(cur))
    }
    private var sunAligned: Bool { sunRel.map { abs($0) < 10 } ?? false }

    /// Wrap a bearing difference into −180…180.
    private static func signedDelta(_ raw: Double) -> Double {
        var d = raw.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Today's hourly sun azimuths (sun-up hours only) for the day arc. Azimuths don't depend on
    /// the compass heading, so this is computed once per appearance / preset change / first fix —
    /// the per-frame cost of heading updates stays a handful of subtractions.
    private func recomputeSunArc() {
        guard isPro, sunMoment != nil, let lat = location.latitude, let lon = location.longitude else {
            sunArcAzimuths = []
            return
        }
        var azimuths: [Double] = []
        for hour in 5...21 {
            guard let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { continue }
            let p = SolarPosition.at(latitude: lat, longitude: lon, date: d)
            if p.isUp { azimuths.append(p.azimuthDeg) }
        }
        sunArcAzimuths = azimuths
    }

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
            if isPro { location.requestAndStart() }         // sun planner + pitch memory are Pro-only
            recomputeSunArc()
        }
        // Deliberately NOT stopping motion here: the only push destination is the setup wizard,
        // whose calibrate step needs live readings — and push ordering can fire the wizard's
        // onAppear BEFORE our onDisappear, so a stop() here could freeze the wizard's motion
        // and let Re-calibrate bake a stale offset. Backgrounding suspends CoreMotion anyway.
        .onDisappear { audio.stop() }
        .onChange(of: isLevel) { _, nowLevel in
            if nowLevel && !wasLevel && armed { Haptics.levelReached(); audio.alertLevel() }
            wasLevel = nowLevel
        }
        .onChange(of: sunMoment) { recomputeSunArc() }
        .onChange(of: location.latitude) { recomputeSunArc() }   // the first GPS fix arrives async
        .onChange(of: isPro) { _, pro in
            // Mid-session upgrade (purchase or the TestFlight preview toggle): onAppear already
            // ran, so start location NOW or the just-bought sun planner sits at "Finding your
            // position…" until the next launch.
            if pro { location.requestAndStart() }
        }
        .sheet(isPresented: $showCalibrate) { CalibrateView() }
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .sheet(isPresented: $showRampShop) { RampShopSheet(neededMM: shopNeededMM) }
        // Settings actions (wizard push / paywall) run AFTER the sheet is gone, so the
        // navigation push never races the sheet dismissal.
        .sheet(isPresented: $showSettings, onDismiss: runPendingSettingsAction) {
            SettingsSheet(isPro: isPro) { pendingSettings = $0 }
        }
        .sheet(item: $savePitchData) { data in SavePitchSheet(data: data) }
        .sheet(item: $shownPitch) { pitch in PitchDetailSheet(pitch: pitch) }
        .fullScreenCover(isPresented: $showInflateGuide) {
            if let config { InflationGuideView(config: config) }
        }
        .navigationDestination(isPresented: $showSetup) {
            VehicleSetupView(mode: setupMode, startStep: setupStart)
        }
        // The free "why buy Pro" moment — offered exactly when Pro would have helped.
        .confirmationDialog(
            "Nice — you're level. Pro remembers this pitch and hands you the exact ramp recipe next time you're back.",
            isPresented: $showPitchTeaser, titleVisibility: .visible
        ) {
            Button("See what Pro does") { showPaywall = true }
            Button("Not now", role: .cancel) {}
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { calibrateButton }
            ToolbarItem(placement: .topBarTrailing) {
                if isPro {
                    sunMenu
                } else {
                    // Visible for free — the sun planner shouldn't be a secret. Tap = paywall.
                    Button { showPaywall = true } label: {
                        Image(systemName: "sun.max").accessibilityLabel("Sun & shade planner — Pro")
                    }
                }
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

            }

            // ONE always-reserved, constant-height sub-slot (fixed-layout contract: the dial
            // must never move as tilt/GPS/armed state changes). At most one hint shows at a
            // time — the pitch recall outranks the refine nudge; empty states keep the space.
            Group {
                if !armed, let near = nearbyPitch {
                    // Pitch memory (Pro): you've levelled near here before — tap for the recipe.
                    Button { shownPitch = near.pitch } label: {
                        Label("Saved pitch nearby — \(near.pitch.siteName.isEmpty ? "tap for last time's setup" : near.pitch.siteName)",
                              systemImage: "mappin.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else if isPhoneFlatEnough && usingRoughDefaults {
                    // Straight to the measure step — no vehicle exists yet, but nobody needs
                    // the language page to type two numbers.
                    Button { setupMode = .firstRun; setupStart = 1; showSetup = true } label: {
                        Label("≈ estimate — set your van's size for exact figures", systemImage: "ruler")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(height: 22)
        }
    }

    /// The nearest saved pitch within ~250m (Pro). GPS scatter plus "roughly the same spot on the
    /// same site" makes a tighter radius miss real returns; the sheet shows the name so a
    /// neighbouring pitch's recipe is easy to recognise and ignore.
    private var nearbyPitch: (pitch: PitchRecord, distance: Double)? {
        guard isPro, let lat = location.latitude, let lon = location.longitude, !pitches.isEmpty else { return nil }
        let scored = pitches.map { ($0, $0.distanceM(latitude: lat, longitude: lon)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= 250 else { return nil }
        return (best.0, best.1)
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
            if isPro, let moment = sunMoment {
                Circle().stroke((sunAligned ? Theme.levelGreen : Theme.sun).opacity(0.6), lineWidth: 2.5)
                    .frame(width: dialSize - 8, height: dialSize - 8)
                sunArc(moment)
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

    /// Opt-in hints — shown BELOW the dial (not overlapping it): the sun caption when the
    /// planner's on, and a small reminder when the sleep tilt is shifting the target.
    @ViewBuilder private var sunHint: some View {
        VStack(spacing: 5) {
            if isPro, let moment = sunMoment {
                Text(sunHintText(moment))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(sunAligned ? Theme.levelGreen : Theme.sun)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if sleepHeadEnd != .off {
                Label("Sleep tilt — \(sleepHeadEnd.label.lowercased())", systemImage: "bed.double.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private func sunHintText(_ moment: SunMoment) -> String {
        if let s = sunPosition, !s.isUp {
            // Only really reachable for "Sun now" at night — the timed presets roll forward
            // to tomorrow (bySettingHour searches ahead), which is what an overnight parker wants.
            return moment == .now
                ? "Sun's set — pick Morning sun to plan tomorrow's pitch"
                : "Sun's below the horizon for \(moment.goal)"
        }
        if sunRel == nil { return "Finding your position…" }
        // If the preset's time already passed today, we're planning TOMORROW's sun — say so.
        let planningTomorrow = moment != .now && !Calendar.current.isDateInToday(moment.date())
        let goal = planningTomorrow ? "tomorrow's \(moment.goal)" : moment.goal
        if sunAligned { return "☀ Facing \(goal) — good spot" }
        return moment == .now
            ? "Turn the van until ☀ reaches the top"
            : "Turn the van until ☀ reaches the top — \(goal)"
    }

    private var bubbleOffset: CGSize {
        let scale: CGFloat = 15
        let cap: CGFloat = 48
        // Sleep-adjusted, so the bubble centres exactly when the shifted target is met.
        let x = min(max(CGFloat(-effRollDeg) * scale, -cap), cap)
        let y = min(max(CGFloat(-effPitchDeg) * scale, -cap), cap)
        return CGSize(width: x, height: y)
    }

    /// The sun's whole-day path as small amber dots on the ring — each dot is "where the ☀ marker
    /// would sit for that hour of today". Rotate the van and the whole day swings with you: park
    /// so your chosen moment docks at the top, and you can see where the sun goes afterwards.
    @ViewBuilder private func sunArc(_ moment: SunMoment) -> some View {
        if let config, let cur = location.headingDeg {
            let awningOffset = config.livingSide.awningOffsetDeg
            ForEach(Array(sunArcAzimuths.enumerated()), id: \.offset) { _, azimuth in
                let target = SolarPosition.vanHeadingForAwning(sunAzimuthDeg: azimuth,
                                                               awningOffsetDeg: awningOffset,
                                                               preference: moment.preference)
                Circle()
                    .fill(Theme.sun.opacity(0.45))
                    .frame(width: 5, height: 5)
                    .offset(y: -(dialSize / 2) + 6)
                    .rotationEffect(.degrees(Self.signedDelta(target - Double(cur))))
            }
        }
    }

    @ViewBuilder private var sunMarker: some View {
        if let rel = sunRel {
            ZStack {
                // Amber while you're hunting; GREEN the moment it docks at the nose = "you're now
                // facing the sun." The green is the whole payoff — the caption below explains it.
                Image(systemName: "sun.max.fill")
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
        // Sleep-adjusted: "nose high" means high relative to the (possibly shifted) target.
        var parts: [String] = []
        if abs(effPitchDeg) > 0.3 { parts.append(effPitchDeg > 0 ? "nose high" : "nose low") }
        if abs(effRollDeg) > 0.3 { parts.append(effRollDeg > 0 ? "left high" : "right high") }
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
                Button {
                    armed = true
                    wasLevel = isLevel
                    armPlan = plan   // the "recipe" — by Done the tilt reads zero, so snapshot now
                } label: {
                    Label("Start levelling", systemImage: "scope").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    let finishedLevel = isLevel
                    armed = false
                    if finishedLevel {
                        if isPro {
                            maybeOfferPitchSave()
                        } else {
                            // The one Pro tease on the free path — at the exact moment pitch
                            // memory would have earned its keep. Dismissible, shown at most
                            // once per session, zero cost to the funnel.
                            armPlan = nil
                            if !pitchTeaserShown {
                                pitchTeaserShown = true
                                showPitchTeaser = true
                            }
                        }
                    } else {
                        armPlan = nil
                    }
                } label: {
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
        Button {
            // A Button still fires on touch-up after a long hold, so without this flag every
            // Pro toggle would ALSO open the calibrate sheet on finger-lift.
            if proToggleFired { proToggleFired = false } else { showCalibrate = true }
        } label: {
            Image(systemName: motion.isCalibrated ? "scope" : "exclamationmark.triangle")
        }
        // TestFlight-only Pro preview toggle — see EntitlementStore.previewProOn. A simultaneous
        // gesture so it doesn't steal the button's normal tap; deliberately not a visible
        // control, so App Store review won't stumble onto a free-Pro switch. MUST be removed
        // (or verified never triggered) before submission — see the EntitlementStore doc.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.5).onEnded { _ in
                proToggleFired = true
                entitlements.setPreviewPro(!entitlements.previewProOn)
                Haptics.saved()
                // If the tap never lands (finger dragged off), don't swallow the NEXT tap.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    proToggleFired = false
                }
            }
        )
    }

    /// Sun planner presets (Pro) — one flat list: each moment pairs a time of day with the
    /// sun/shade preference that makes sense for it.
    private var sunMenu: some View {
        Menu {
            Button { sunMoment = nil } label: {
                Label("Sun planner off", systemImage: sunMoment == nil ? "checkmark" : "poweroff")
            }
            Divider()
            ForEach(SunMoment.allCases) { moment in
                Button { sunMoment = moment } label: {
                    Label(moment.label, systemImage: sunMoment == moment ? "checkmark" : moment.icon)
                }
            }
        } label: {
            Image(systemName: sunMoment != nil ? "sun.max.fill" : "sun.max")
        }
    }

    /// Runs whatever a Settings row asked for, once the sheet is fully gone.
    private func runPendingSettingsAction() {
        guard let action = pendingSettings else { return }
        pendingSettings = nil
        switch action {
        case .openWizard(let mode, let startStep):
            setupMode = mode
            setupStart = startStep
            showSetup = true
        case .paywall:
            showPaywall = true
        }
    }

    /// After a successful "Done — you're level" (Pro): offer to keep this pitch + its recipe.
    /// Requires a REAL snapshot — if the phone was in-hand (>15° → plan nil) when Start was
    /// tapped there is no recipe, and persisting four zero corners would tell the user next
    /// year that this pitch "needed nothing". No snapshot → no save offer.
    private func maybeOfferPitchSave() {
        defer { armPlan = nil }
        guard isPro, let recipe = armPlan,
              let lat = location.latitude, let lon = location.longitude else { return }
        // Wheels come back in the fixed order FL, FR, RL, RR (see LevelPlan).
        let lifts = recipe.wheels.map { Double($0.liftMM) }
        guard lifts.count == 4 else { return }
        savePitchData = SavePitchData(latitude: lat, longitude: lon,
                                      heading: location.headingDeg.map { Int($0) },
                                      fl: lifts[0], fr: lifts[1], rl: lifts[2], rr: lifts[3])
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
