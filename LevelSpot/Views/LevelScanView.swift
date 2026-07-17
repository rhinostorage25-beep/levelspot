import SwiftUI
import SwiftData
import UIKit
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Pro pack data: the saved pitches (vehicles live in SettingsSheet's own query now).
    @Query private var pitches: [PitchRecord]
    // Sleep tilt — where the bed's head end is. Free tier ignores the stored value.
    @AppStorage("sleepHeadEnd") private var sleepHeadEndRaw = SleepHeadEnd.off.rawValue

    @State private var audio = AudioCoach()
    @State private var wind = WindService()    // awning wind alerts (Pro) — silent unless gusty
    @AppStorage("windAlertsOn") private var windAlertsOn = true
    @State private var sunMoment: SunMoment?   // sun planner is opt-in via the ☀ button; nil = off
    @State private var showSunOptions = false
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
    @State private var pitchTeaserShown = false  // once per session — a mention, not a nag
    @State private var showMovementSafety = false
    // Persisted: the one-time "do not hold the phone while moving" confirmation.
    @AppStorage("movementSafetyShown") private var movementSafetyShown = false
    @State private var savePitchData: SavePitchData?
    @State private var shownPitch: PitchRecord?
    @State private var shopNeededMM: Int?
    @State private var wasLevel = false

    // Wheel markers as SHOWN — decoupled from the live 10Hz plan. Raw sensor wobble sits the
    // tilt right on a ramp-step boundary and the naive markers strobed +40↔+70 ("flicker around
    // way too much to be useful"). The stabiliser below only commits a change once the candidate
    // has held steady for consecutive half-second ticks.
    @State private var shownMarkers: [Marker] = []
    @State private var pendingMarkers: [Marker]?
    @State private var pendingTicks = 0

    @Environment(\.dynamicTypeSize) private var typeSize
    /// The instrument shares the screen with much taller text at accessibility sizes.
    private var dialSize: CGFloat { typeSize.isAccessibilitySize ? 220 : 280 }
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

    /// Kick a wind check when it could matter (Pro + alerts on + a fix). WindService
    /// self-throttles (30 min / 5 km), so calling this from several triggers is fine.
    private func refreshWind() {
        guard isPro, windAlertsOn, let lat = location.latitude, let lon = location.longitude else { return }
        Task { await wind.refreshIfNeeded(lat: lat, lon: lon) }
    }

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
        // A ScrollView that doesn't scroll at standard type sizes (basedOnSize) — the fixed
        // layout holds for everyone else, and accessibility Dynamic Type users can reach the
        // status readout instead of it being clipped under the bottom bar.
        ScrollView {
            // Spacing/padding are tight on purpose: with a two-line sun caption AND the
            // saved-pitch hint showing, the stack must still fit a 6.1-inch screen at
            // default type — a readout half-hidden under the bottom bar reads as broken.
            VStack(spacing: 10) {
                noticeZone
                dial
                sunHint
                levelStatus
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Level")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            motion.start()
            audio.start()                                  // audio is free now
            if isPro { location.requestAndStart() }         // sun planner + pitch memory are Pro-only
            recomputeSunArc()
            refreshWind()
        }
        // The marker stabiliser heartbeat. A plain repeating task (not onChange of the plan)
        // because the whole point is to keep evaluating while the candidate is HOLDING a value —
        // onChange goes quiet exactly when we need to confirm stability. Cancelled with the view.
        // It also feeds the audio coach: while guidance is running, the parking-sensor beeps
        // quicken and rise as the vehicle approaches level — the drive is eyes-free by design.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                stabilizeMarkers()
                pushAudioState()
            }
        }
        // Deliberately NOT stopping motion here: the only push destination is the setup wizard,
        // whose calibrate step needs live readings — and push ordering can fire the wizard's
        // onAppear BEFORE our onDisappear, so a stop() here could freeze the wizard's motion
        // and let Re-calibrate bake a stale offset. Backgrounding suspends CoreMotion anyway.
        .onDisappear { audio.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: isLevel) { _, nowLevel in
            // One success haptic; the audio coach announces the stop tone itself (its ticker
            // chimes once on reaching level while guidance is enabled — no double chime here).
            // The state push happens HERE too, at sensor rate: the 500ms heartbeat alone
            // could deliver the stop tone half a second late, or miss a fast pass entirely.
            if nowLevel && !wasLevel && armed { Haptics.levelReached() }
            wasLevel = nowLevel
            pushAudioState()
        }
        // Eyes-free guidance: the screen must not sleep mid-drive.
        .onChange(of: armed) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        // One success haptic when the sun locks on target.
        .onChange(of: sunAligned) { was, now in
            if now && !was { Haptics.sunAligned() }
        }
        .onChange(of: sunMoment) { _, moment in
            recomputeSunArc()
            // Compass only while the planner's on (see LocationService.startHeading).
            if moment != nil { location.requestAndStart(); location.startHeading() } else { location.stopHeading() }
        }
        .onChange(of: location.latitude) {                       // the first GPS fix arrives async
            recomputeSunArc()
            refreshWind()
        }
        .onChange(of: windAlertsOn) { _, on in
            if on {
                // Ask for notification permission NOW — the user just flipped the toggle, so
                // the prompt has context (vs ambushing them mid-levelling at the first gust).
                Task { await wind.requestPermission() }
                refreshWind()
            } else {
                wind.reset()
            }
        }
        .onChange(of: showSettings) { _, open in
            // Nothing under the Settings sheet needs live tilt, and pausing it makes the
            // sheet's pickers rock-solid (no churn-driven re-renders while a menu is open).
            if open { motion.stop() } else { motion.start() }
        }
        .onChange(of: isPro) { _, pro in
            // Mid-session upgrade (purchase or the TestFlight preview toggle): onAppear already
            // ran, so start location NOW or the just-bought sun planner sits at "Finding your
            // position…" until the next launch. Lapse: a booked wind alert must not outlive Pro.
            if pro { location.requestAndStart(); refreshWind() } else { wind.reset() }
        }
        .sheet(isPresented: $showCalibrate) { CalibrateView() }
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .sheet(isPresented: $showRampShop) { RampShopSheet(neededMM: shopNeededMM) }
        // Settings actions (wizard push / paywall) run AFTER the sheet is gone, so the
        // navigation push never races the sheet dismissal.
        .sheet(isPresented: $showSettings, onDismiss: runPendingSettingsAction) {
            SettingsSheet { pendingSettings = $0 }
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
            "Pro can remember this pitch and recall the exact setup next time you return.",
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
                    // A confirmationDialog, NOT a Menu: the Level screen re-renders with every
                    // sensor tick, and SwiftUI menus rebuilt mid-tap swallow presses (the
                    // "3–4 taps" bug). Alert-backed dialogs are set once at presentation.
                    Button { showSunOptions = true } label: {
                        Image(systemName: sunMoment != nil ? "sun.max.fill" : "sun.max")
                            .accessibilityLabel(sunMoment.map { "Sun and shade — \($0.label) is on" }
                                                ?? "Sun and shade")
                    }
                    .confirmationDialog("Sun and shade", isPresented: $showSunOptions, titleVisibility: .visible) {
                        ForEach(SunMoment.allCases) { moment in
                            // "(on)" not "✓" — VoiceOver reads a literal checkmark as "check mark".
                            Button(sunMoment == moment ? "\(moment.label) (on)" : moment.label) {
                                sunMoment = moment
                            }
                        }
                        if sunMoment != nil {
                            Button("Off", role: .destructive) { sunMoment = nil }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Morning and evening aim the awning at the sun; midday positions it for shade.")
                    }
                } else {
                    // Visible for free — the sun planner shouldn't be a secret. Tap = paywall.
                    Button { showPaywall = true } label: {
                        Image(systemName: "sun.max").accessibilityLabel("Sun and shade — Pro")
                    }
                }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) { simulateMenu }
            #endif
        }
    }

    // MARK: - Notice zone (free for everyone — the ramp/affiliate coaching lives here)

    // MARK: - Coach state machine (the one source of truth for what the screen says)

    /// Every state the Level screen can be in. Exactly one coach message and at most one
    /// primary action render per state — the brief's "one obvious action" rule.
    private enum CoachState: Equatable {
        case phoneInvalid
        case pitchUnsafe(neededMM: Int)                                   // beyond every product
        case equipmentInsufficient(reachMM: Int, neededMM: Int)           // taller ramps exist
        case withinTolerance
        case readyPerWheel
        case rampsRequired(estimated: Bool)
        case moving
        case approachingLevel
        case stopNow
        case levelComplete
    }

    /// Inside this band (but not yet level) the coaching softens to "Almost level".
    private static let approachBandDeg = 2.5

    private var coachState: CoachState {
        guard isPhoneFlatEnough, let plan else { return .phoneInvalid }
        if armed {
            if isLevel { return .stopNow }
            return degOff <= Self.approachBandDeg ? .approachingLevel : .moving
        }
        if isLevel { return .levelComplete }
        if !plan.canLevel {
            let neededMM = plan.wheels.map { $0.liftMM }.max() ?? 0
            return ReferenceStore.shared.rampsReaching(mm: neededMM).isEmpty
                ? .pitchUnsafe(neededMM: neededMM)
                : .equipmentInsufficient(reachMM: effectiveRampSet.ceilingMM, neededMM: neededMM)
        }
        if usesPerWheelFlow { return .readyPerWheel }
        if plan.ramps.isEmpty && shownMarkers.isEmpty { return .withinTolerance }
        return .rampsRequired(estimated: usingRoughDefaults)
    }

    /// The lift figure the coach quotes — the same stabilised value the dial markers show,
    /// rounded to 5 mm so copy never strobes at sensor rate.
    private var coachLiftMM: Int {
        let stabilised = shownMarkers.map(\.mm).max()
        let live = plan.flatMap { p in p.ramps.map { $0.stepMM ?? $0.liftMM }.max() }
        return roundedTo5(stabilised ?? live ?? 0)
    }

    private func roundedTo5(_ mm: Int) -> Int { ((mm + 2) / 5) * 5 }

    @ViewBuilder private var noticeZone: some View {
        VStack(spacing: DS.related) {
            if isPro, windAlertsOn, let warning = wind.warning, !armed {
                // A live gust warning replaces the coach panel — the loudest thing on screen
                // is the thing that matters. NOT while guidance is running: a driver mid-drive
                // must keep the moving/STOP instruction; the warning returns after they stop.
                CoachPanel(role: warning.severe ? .windUrgent : .windWatch,
                           icon: "wind",
                           title: "Gusts to \(warning.peakMPH) mph around \(warning.timeLabel)",
                           message: warning.severe ? "Bring the awning in." : "Keep an eye on the awning.")
                    .accessibilityLabel("Wind warning. Gusts to \(warning.peakMPH) miles per hour around \(warning.timeLabel). \(warning.severe ? "Bring the awning in." : "Keep an eye on the awning.")")
            } else {
                coachPanel(for: coachState)
            }

            // ONE always-reserved sub-slot: the saved-pitch recall, or empty space.
            Group {
                if !armed, let near = nearbyPitch {
                    Button { shownPitch = near.pitch } label: {
                        Label("Saved pitch nearby — \(near.pitch.siteName.isEmpty ? "view last time's setup" : near.pitch.siteName)",
                              systemImage: "mappin.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(height: 22)
        }
    }

    @ViewBuilder private func coachPanel(for state: CoachState) -> some View {
        switch state {
        case .phoneInvalid:
            CoachPanel(role: .neutral, icon: "iphone.gen3",
                       title: "Lay your phone flat",
                       message: "Place it screen-up in the vehicle to measure the pitch.")
        case .rampsRequired(let estimated):
            if estimated {
                CoachPanel(role: .action, icon: "arrow.up.circle.fill",
                           title: "Place ramps at the highlighted wheels",
                           message: "Estimated lift: \(coachLiftMM) mm. Add your vehicle measurements for greater accuracy.",
                           secondaryTitle: "Add measurements",
                           secondaryAction: { setupMode = .firstRun; setupStart = 1; showSetup = true })
            } else {
                CoachPanel(role: .action, icon: "arrow.up.circle.fill",
                           title: "Place ramps at the highlighted wheels",
                           message: "Required lift: about \(coachLiftMM) mm.")
            }
        case .equipmentInsufficient(let reach, let needed):
            // Shopping stays OUT of the instruction: facts first, one separate secondary action.
            CoachPanel(role: .unsafe, icon: "exclamationmark.triangle.fill",
                       title: usingRoughDefaults ? "Typical ramps are not high enough"
                                                 : "Your ramps are not high enough",
                       message: "\(usingRoughDefaults ? "Most reach" : "They reach") \(reach) mm. This pitch requires about \(roundedTo5(needed)) mm. Move to a flatter spot, or use taller ramps.",
                       secondaryTitle: "View suitable ramps",
                       secondaryAction: { shopNeededMM = needed; showRampShop = true })
        case .pitchUnsafe(let needed):
            CoachPanel(role: .unsafe, icon: "exclamationmark.triangle.fill",
                       title: "Move to a flatter spot",
                       message: "Required lift: about \(roundedTo5(needed)) mm — beyond normal levelling-ramp limits.")
        case .withinTolerance:
            CoachPanel(role: .neutral, icon: "checkmark.circle",
                       title: "This is as close as your ramps allow",
                       message: "Your smallest step would not improve the result.")
        case .readyPerWheel:
            CoachPanel(role: .action, icon: "arrow.up.circle.fill",
                       title: "Ready to level",
                       message: "Place your levelling equipment under the highlighted wheels.")
        case .moving:
            CoachPanel(role: .action, icon: "waveform",
                       title: "Move forward slowly",
                       message: "Listen for the stop tone.")
        case .approachingLevel:
            CoachPanel(role: .action, icon: "waveform",
                       title: "Almost level",
                       message: "Continue slowly.")
        case .stopNow:
            CoachPanel(role: .unsafe, icon: "exclamationmark.octagon.fill",
                       title: "STOP",
                       message: "Vehicle level. Stop moving.")
        case .levelComplete:
            CoachPanel(role: .success, icon: "checkmark.circle.fill",
                       title: "Vehicle level",
                       message: "Apply the handbrake before leaving the driver's seat.")
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


    // MARK: - The dial (nothing here changes SIZE; only colours/positions animate)

    /// Red only when the state is genuinely unsafe (too steep / STOP), green only on
    /// confirmed level, neutral the rest of the time — "not level yet" is not an emergency.
    /// STOP is checked BEFORE the level short-circuit: at the stop moment the vehicle IS
    /// level, and the red instruction has to win over the green congratulation.
    private var dialTint: Color {
        if coachState == .stopNow { return .red }
        if isLevel { return .green }
        switch coachState {
        case .pitchUnsafe, .equipmentInsufficient: return .red
        default: return Color(.systemGray)
        }
    }

    private var dial: some View {
        let target = dialTint
        return ZStack {
            // Your van from ABOVE (front up) as a white wireframe on a DARK disc — the circular
            // vehicle instrument is the product's identity; the neon glow around it is not.
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

            // WHAT TO DO, drawn where the eyes already are: the wheels that need ramping light
            // up on the van itself, each with its target height. (The coaching card above says
            // the same thing in words, but the dial dominates attention — testers never saw it.)
            wheelMarkers

            Circle()
                .fill(target)
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 2))
                .offset(x: bubbleOffset.width, y: bubbleOffset.height)
                .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: bubbleOffset)
        }
        .frame(width: dialSize + 18, height: dialSize + 18)
        .frame(maxWidth: .infinity)
        // VoiceOver gets one meaningful instrument summary, not thirty decorative layers.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dialAccessibilitySummary)
    }

    private var dialAccessibilitySummary: String {
        var parts: [String] = []
        parts.append(isLevel ? "Vehicle level."
                             : String(format: "Vehicle %.1f degrees off. %@.", degOff, levelDirection))
        for marker in shownMarkers {
            parts.append("\(marker.name) wheel: raise by \(marker.mm) millimetres.")
        }
        if isPro, sunMoment != nil {
            parts.append(sunAligned ? "Sun marker aligned." : "Sun planner active — turn the vehicle until the sun marker reaches the top.")
        }
        return parts.joined(separator: " ")
    }

    /// The van as drawn on the dial, derived from the same MEASURED png constants as
    /// AwningVan.M, scaled to this layout: the image fits a (dialSize − 2·6% padding) square,
    /// so its pre-rotation drawn height = 0.88 · (1086/1448) · dialSize ≈ 0.6597 · dialSize.
    private enum DialVan {
        static let unit: CGFloat = 0.6597                     // pre-rotation height / dialSize
        static let halfW: CGFloat = 0.503 * unit / 2          // centre → visible van side edge
        static let halfH: CGFloat = 1.166 * unit / 2          // centre → visible nose/tail
        static let centerDX: CGFloat = -0.039 * unit + 0.02   // measured offset + the dial's x nudge
        static let centerDY: CGFloat = -0.019 * unit
        /// Axle positions as fractions of van length from the nose (top view hides the wheels,
        /// so these are typical panel-van proportions — indicator dots, not survey marks).
        static let frontAxle: CGFloat = 0.18
        static let rearAxle: CGFloat = 0.78
    }

    /// A wheel marker as displayed — a value type so the stabiliser can compare frames.
    private struct Marker: Equatable {
        let name: String
        let left: Bool
        let front: Bool
        var mm: Int
    }

    /// What the live plan WOULD show right now. The stabiliser decides when the display follows.
    /// Sorted into a FIXED wheel order — plan.ramps re-sorts by (noisy) liftMM on every access,
    /// so two near-equal wheels swap places tick to tick and every ordered comparison below
    /// would churn on pure re-orderings that mean nothing.
    private var candidateMarkers: [Marker] {
        guard isPhoneFlatEnough, let plan, plan.canLevel else { return [] }
        return plan.ramps.map {
            Marker(name: $0.wheelName, left: $0.side == .left, front: $0.end == .front,
                   mm: $0.stepMM ?? $0.liftMM)
        }
        .sorted { ($0.front ? 0 : 1, $0.left ? 0 : 1) < ($1.front ? 0 : 1, $1.left ? 0 : 1) }
    }

    /// Commit a marker change only once it has survived consecutive half-second ticks: a
    /// candidate that keeps flapping (tilt sat right on a ramp-step boundary) keeps resetting
    /// the clock and the display simply doesn't move. Confirmation windows by transition:
    /// nothing→something = 1 tick (a deliberate test should feel immediate), something→nothing
    /// = 2 (progress feedback as wheels come up), value/set changes = 3 — long enough that a
    /// boundary oscillation aliasing into the 500ms comb (two agreeing samples ~every 1.5s)
    /// almost never sneaks a flap through.
    private func stabilizeMarkers() {
        var candidate = mmSteadied(candidateMarkers, against: shownMarkers)
        if let pending = pendingMarkers {
            // Steady against the pending value too, or continuous (air/wedge/ratchet) sets —
            // whose mm is the raw rounded lift, jittering ±1-2mm per read — would reset the
            // tick count forever and never commit a genuine change.
            candidate = mmSteadied(candidate, against: pending)
        }
        if candidate == shownMarkers { pendingMarkers = nil; return }
        if candidate != pendingMarkers {
            pendingMarkers = candidate
            pendingTicks = 1
        } else {
            pendingTicks += 1
        }
        let needed = shownMarkers.isEmpty ? 1 : (candidate.isEmpty ? 2 : 3)
        if pendingTicks >= needed {
            shownMarkers = candidate
            pendingMarkers = nil
        }
    }

    /// Same wheels, near-same numbers → keep the numbers already on show. Kills the ±few-mm
    /// label jitter on continuous (air/ratchet) sets; stepped sets jump ≥30mm so a real step
    /// change always gets through. Matched by wheel NAME, not position.
    private func mmSteadied(_ candidate: [Marker], against reference: [Marker]) -> [Marker] {
        guard Set(candidate.map(\.name)) == Set(reference.map(\.name)) else { return candidate }
        let refMM = Dictionary(uniqueKeysWithValues: reference.map { ($0.name, $0.mm) })
        return candidate.map { c in
            var m = c
            if let r = refMM[c.name], abs(c.mm - r) < 15 { m.mm = r }
            return m
        }
    }

    /// One glowing dot per wheel that needs a ramp, with its target height — disappears
    /// wheel-by-wheel as the van comes up, which doubles as live progress feedback.
    @ViewBuilder private var wheelMarkers: some View {
        ForEach(shownMarkers, id: \.name) { marker in
            wheelMarker(marker)
        }
    }

    private func wheelMarker(_ wheel: Marker) -> some View {
        let d = dialSize
        let axleFrac = wheel.front ? DialVan.frontAxle : DialVan.rearAxle
        let x = DialVan.centerDX * d + (wheel.left ? -1 : 1) * DialVan.halfW * d
        let y = DialVan.centerDY * d - DialVan.halfH * d + axleFrac * (2 * DialVan.halfH * d)
        let mm = wheel.mm
        let outward: CGFloat = wheel.left ? -1 : 1
        return ZStack {
            if usesPerWheelFlow {
                // Air bags / blocks / ratchets go UNDER the wheel — a pad beneath the dot.
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.needsRamp.opacity(0.85))
                    .frame(width: 26, height: 13)
            } else {
                // Drive-up ramp: the wedge sits on the ground ahead of the wheel, and the
                // chevron says "drive forward onto it" — no reading required. The pulse is
                // skipped under Reduce Motion.
                RampWedge()
                    .fill(Theme.needsRamp)
                    .frame(width: 20, height: 12)
                    .offset(y: -31)
                Image(systemName: "chevron.compact.up")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.needsRamp)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    .offset(y: -17)
            }
            Circle().fill(Theme.needsRamp)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            Text("+\(mm)")
                .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.needsRamp)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.black.opacity(0.55), in: Capsule())
                .offset(x: outward * 36)
        }
        .offset(x: x, y: y)
    }

    /// Opt-in hints — shown BELOW the dial (not overlapping it): the sun caption when the
    /// planner's on, and a small reminder when the sleep tilt is shifting the target.
    /// Guidance must never truncate, so these wrap instead of clipping.
    @ViewBuilder private var sunHint: some View {
        VStack(spacing: 5) {
            if isPro, let moment = sunMoment {
                Text(sunHintText(moment))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(sunAligned ? Theme.levelGreen : Theme.sun)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if sleepHeadEnd != .off {
                Label("Sleep tilt · \(sleepHeadEnd.label.lowercased())", systemImage: "bed.double.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private func sunHintText(_ moment: SunMoment) -> String {
        // Say WHICH thing we're waiting for — a single "finding your position" hid a stuck,
        // never-calibrated compass behind the same words as a pending GPS fix. And the planner
        // literally cannot aim without knowing the awning side, so say THAT when it's the gap.
        if config == nil { return "Measure your vehicle first — the planner needs your awning side." }
        if location.latitude == nil { return "Finding your location…" }
        if let s = sunPosition, !s.isUp {
            // Only really reachable for "Now" at night — the timed presets roll forward
            // to tomorrow (bySettingHour searches ahead), which is what an overnight parker wants.
            return moment == .now
                ? "The sun has set. Choose a time for tomorrow."
                : "The sun is below the horizon for \(moment.goal)."
        }
        if location.headingDeg == nil { return "Calibrating the compass — move the phone in a figure eight." }
        if sunRel == nil { return "Finding your position…" }
        // If the preset's time already passed today, we're planning TOMORROW's sun — say so.
        let planningTomorrow = moment != .now && !Calendar.current.isDateInToday(moment.date())
        let goal = planningTomorrow ? "tomorrow's \(moment.goal)" : moment.goal
        if sunAligned { return "Positioned for \(goal)." }
        return moment == .now
            ? "Turn the vehicle until the sun marker reaches the top."
            : "Turn the vehicle until the sun marker reaches the top — \(goal)."
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

    // MARK: - Level status

    private var levelStatus: some View {
        // One success message per screen: the coach panel announces "Vehicle level", so the
        // instrument shows the state word quietly. STOP is the only permitted capitals.
        let stop = coachState == .stopNow
        return StatusSummary(
            value: stop ? "STOP" : (isLevel ? "Level" : String(format: "%.1f° off", degOff)),
            detail: isLevel ? "" : levelDirection,
            valueColor: stop ? .red : (isLevel ? .green : Color(.label))
        )
    }

    private var levelDirection: String {
        // Sleep-adjusted: "nose high" means high relative to the (possibly shifted) target.
        var parts: [String] = []
        if abs(effPitchDeg) > 0.3 { parts.append(effPitchDeg > 0 ? "nose high" : "nose low") }
        if abs(effRollDeg) > 0.3 { parts.append(effRollDeg > 0 ? "left high" : "right high") }
        guard let first = parts.first else { return "Almost level" }
        return (first.prefix(1).uppercased() + first.dropFirst())
            + (parts.count > 1 ? " · " + parts[1] : "")
    }

    // MARK: - Bottom bar (one primary action per state — or none)

    @ViewBuilder private var bottomBar: some View {
        Group {
            switch coachState {
            case .readyPerWheel:
                PrimaryBottomAction(title: isPro ? "Guide me wheel by wheel" : "Guide me wheel by wheel — Pro",
                                    icon: isPro ? "scope" : "lock.fill") {
                    if isPro { showInflateGuide = true } else { showPaywall = true }
                }
            case .rampsRequired, .withinTolerance:
                PrimaryBottomAction(title: "Start guidance", icon: "scope") {
                    startGuidance()
                }
            case .moving, .approachingLevel:
                PrimaryBottomAction(title: "Stop", icon: "xmark", isProminent: false) {
                    endGuidance()
                }
            case .phoneInvalid where armed:
                // Guidance is running but the phone was picked up — the user must always be
                // able to end an active drive, whatever the sensors say.
                PrimaryBottomAction(title: "Stop", icon: "xmark", isProminent: false) {
                    endGuidance()
                }
            case .stopNow:
                PrimaryBottomAction(title: "Done", icon: "checkmark.circle.fill") {
                    endGuidance()
                }
            default:
                // No valid action in this state (phone not flat, too steep, already level).
                // A hidden ghost of the real button keeps the bar's height IDENTICAL across
                // states at every Dynamic Type size — a fixed number drifts as text scales.
                PrimaryBottomAction(title: "Start guidance", icon: "scope") {}
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
        // One first-run safety confirmation before the first ever guided drive.
        .confirmationDialog(
            "Do not hold or operate the phone while moving the vehicle.",
            isPresented: $showMovementSafety, titleVisibility: .visible
        ) {
            // The warning is only marked as seen when the user CONFIRMS it — cancelling
            // means it shows again next time, not never again.
            Button("Start guidance") { movementSafetyShown = true; arm() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func startGuidance() {
        if movementSafetyShown {
            arm()
        } else {
            showMovementSafety = true
        }
    }

    private func arm() {
        armed = true
        wasLevel = isLevel
        armPlan = plan   // the "recipe" — by Done the tilt reads zero, so snapshot now
        pushAudioState()
    }

    /// Feed the audio coach the current state. Called from the 500ms heartbeat AND at sensor
    /// rate on level-crossings, so the stop tone lands the moment the vehicle reaches level.
    /// Silent when the phone isn't lying flat: plan is nil then, and offMM 0 would otherwise
    /// read as "nearly level" and beep at maximum rate mid-pickup.
    private func pushAudioState() {
        audio.update(offMM: Double(plan?.wheels.map { $0.liftMM }.max() ?? 0),
                     toleranceMM: 20,
                     isLevel: isLevel,
                     beyond: false,
                     enabled: armed && !usesPerWheelFlow && isPhoneFlatEnough)
    }

    private func endGuidance() {
        let finishedLevel = isLevel
        armed = false
        if finishedLevel {
            if isPro {
                maybeOfferPitchSave()
            } else {
                // The one Pro mention on the free path — at the exact moment pitch memory
                // would have earned its keep. Dismissible, shown at most once per session.
                armPlan = nil
                if !pitchTeaserShown {
                    pitchTeaserShown = true
                    showPitchTeaser = true
                }
            }
        } else {
            armPlan = nil
        }
        pushAudioState()   // silence the coach immediately, not at the next heartbeat
    }

    // MARK: - Toolbar menus

    private var calibrateButton: some View {
        // The TestFlight Pro-preview lever moved to an explicit toggle in Settings — the hidden
        // long-press here was undiscoverable and broke the moment the toolbar gained the ☀
        // button next door (testers pressed the wrong icon). Plain calibrate button again.
        Button { showCalibrate = true } label: {
            Image(systemName: motion.isCalibrated ? "scope" : "exclamationmark.triangle")
                .accessibilityLabel(motion.isCalibrated ? "Calibrate" : "Calibrate — not yet calibrated")
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
        case .shop:
            shopNeededMM = nil   // browsing, not fixing a specific deficit — show the lot
            showRampShop = true
        case .paywall:
            showPaywall = true
        case .testWindAlert:
            Task { await wind.simulateWarning() }
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

    /// The ramp marker, drawn as an arrowhead pointing UP the screen = the direction you drive.
    /// (v1 was a side-profile wedge whose slope ran left-to-right — on the top-view van it read
    /// as pointing sideways: "ramps point the wrong way". On a top view the only direction that
    /// exists is travel, so the shape now points that way, in line with the pulsing chevron.)
    private struct RampWedge: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
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
