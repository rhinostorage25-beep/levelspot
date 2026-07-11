import SwiftUI
import SwiftData

/// First-run / edit onboarding as a paged wizard: language → measure → sit-side → ramps → sun →
/// calibrate. One clear thing per page, Back/Next at the bottom. The old single scrolling form is
/// gone. Reached from the dial's gear (Pro) or the "set up your van" prompt.
struct VehicleSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(MotionService.self) private var motion
    @Environment(EntitlementStore.self) private var entitlements
    @Query private var existingConfigs: [VehicleConfig]
    @AppStorage("appLanguageCode") private var languageCode = "en"

    private let ref = ReferenceStore.shared.data

    @State private var step = 0
    @State private var wheelbase = ""
    @State private var trackFront = ""
    @State private var trackRear = ""
    @State private var rearDiffers = false
    @State private var rampProfileId = "default"
    @State private var customSteps = [40, 70, 100]
    @State private var livingSide: LivingSide?
    @State private var showPaywall = false
    @State private var showShop = false
    @State private var activeMeasure: MeasureTarget?

    private let lastStep = 5

    private let languages: [(code: String, name: String, flag: String)] = [
        ("en", "English", "🇬🇧"), ("de", "Deutsch", "🇩🇪"), ("fr", "Français", "🇫🇷"),
        ("it", "Italiano", "🇮🇹"), ("es", "Español", "🇪🇸"), ("nl", "Nederlands", "🇳🇱"),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            progressDots
            Group {
                switch step {
                case 0: languageStep
                case 1: measureStep
                case 2: sitSideStep
                case 3: rampsStep
                case 4: sunStep
                default: calibrateStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            navBar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Set up")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: step)
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .sheet(isPresented: $showShop) { RampShopSheet(neededMM: nil) }
        .fullScreenCover(item: $activeMeasure) { target in
            ARMeasureView(kind: target.kind) { mm in applyMeasurement(target, mm) }
        }
        .onAppear { motion.start(); prefillFromExisting() }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0...lastStep, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color(.tertiaryLabel))
                    .frame(width: i == step ? 22 : 8, height: 8)
            }
        }
        .padding(.top, 10)
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Step 0 · Language

    private var languageStep: some View {
        ScrollView {
            VStack(spacing: 14) {
                stepHeader("Choose your language", "You can change this any time in Set up.")
                VStack(spacing: 10) {
                    ForEach(languages, id: \.code) { lang in
                        Button { languageCode = lang.code } label: {
                            HStack(spacing: 12) {
                                Text(lang.flag).font(.title2)
                                Text(lang.name).font(.body).foregroundStyle(.primary)
                                Spacer()
                                if languageCode == lang.code {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                Text("The app is in English for now — the other languages are coming soon.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    // MARK: - Step 1 · Measure

    private var measureStep: some View {
        ScrollView {
            VStack(spacing: 18) {
                stepHeader("Measure your van", "No make or model needed — just two measurements, so LevelSpot works for any vehicle, anywhere.")
                measureField(diagram: AnyView(VanPhoto("VanSide", fallback: AnyView(WheelbaseDiagram()))),
                             label: "Wheelbase (mm)", placeholder: "e.g. 3400",
                             text: $wheelbase, target: .wheelbase,
                             hint: "Centre of the front tyre to centre of the rear tyre.")
                measureField(diagram: AnyView(VanPhoto("VanFront", fallback: AnyView(TrackDiagram()))),
                             label: "Track width (mm)", placeholder: "e.g. 1800",
                             text: $trackFront, target: .trackFront,
                             hint: "Centre to centre of the two FRONT tyres, across the van.")
                Toggle("Rear track is different", isOn: $rearDiffers.animation())
                    .padding(.horizontal)
                if rearDiffers {
                    measureField(diagram: AnyView(VanPhoto("VanFront", fallback: AnyView(TrackDiagram()))),
                                 label: "Rear track (mm)", placeholder: "e.g. 1980",
                                 text: $trackRear, target: .trackRear,
                                 hint: "Centre to centre of the two REAR tyres — wider on some chassis.")
                }
            }
            .padding(.vertical)
        }
    }

    private func measureField(diagram: AnyView, label: String, placeholder: String,
                              text: Binding<String>, target: MeasureTarget, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            diagram.frame(height: 170).frame(maxWidth: .infinity).accessibilityHidden(true)
            LabeledContent(label) {
                TextField(placeholder, text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            Button { activeMeasure = target } label: {
                Label("Measure with camera", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.bordered).controlSize(.small)
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: - Step 2 · Sit side

    private var sitSideStep: some View {
        VStack(spacing: 16) {
            stepHeader("Which side do you sit out on?", "Pick your awning side — the sun & shade planner uses it to face the van the right way.")
            // Buttons at the top; the diagram below just shows the awning opening on that side.
            Picker("Side", selection: sideBinding) {
                ForEach(LivingSide.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            AwningVan(selection: livingSide)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .padding(.top, 4)
    }

    // MARK: - Step 3 · Ramps

    private var rampsStep: some View {
        ScrollView {
            VStack(spacing: 12) {
                stepHeader("Your levelling ramps", "Pick what you've got — it decides the ramp coaching. Or shop a set that fits.")
                ForEach(ref.rampProfiles) { profile in rampCard(profile) }
                rampCardCustom
                if rampProfileId == "custom" {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { i in
                            TextField("Step \(i + 1)", value: $customSteps[i], format: .number)
                                .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.horizontal)
                }
                Button { showShop = true } label: {
                    Label("Shop levelling ramps", systemImage: "cart").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).padding(.horizontal).padding(.top, 4)
            }
            .padding(.vertical)
        }
    }

    private func rampCard(_ profile: RampProfileRef) -> some View {
        Button {
            rampProfileId = profile.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.body).foregroundStyle(.primary)
                    Text(profile.capacityLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SelectionRing(selected: rampProfileId == profile.id)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).padding(.horizontal)
    }

    private var rampCardCustom: some View {
        Button { rampProfileId = "custom" } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom").font(.body).foregroundStyle(.primary)
                    Text("Enter your own steps").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SelectionRing(selected: rampProfileId == "custom")
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).padding(.horizontal)
    }

    // MARK: - Step 4 · Sun & shade

    private var sunStep: some View {
        ScrollView {
            VStack(spacing: 22) {
                stepHeader("Sun & shade planner", "A Pro extra — don't miss it.")
                HStack(spacing: 28) {
                    VStack(spacing: 8) {
                        Image(systemName: "sun.max.fill").font(.system(size: 46)).foregroundStyle(Theme.sun)
                        Text("Chase the sun").font(.subheadline.weight(.semibold))
                    }
                    VStack(spacing: 8) {
                        Image(systemName: "cloud.sun.fill").font(.system(size: 46)).foregroundStyle(.secondary)
                        Text("Find the shade").font(.subheadline.weight(.semibold))
                    }
                }
                .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 12) {
                    sunPoint("location.north.line.fill", "It reads the sun's position and your compass, then shows which way to face the van.")
                    sunPoint("arrow.triangle.2.circlepath", "Turn the van until the ☀ locks green at the top — that's the awning-perfect direction.")
                    sunPoint("sunrise.fill", "Set it to chase the evening sun, or find shade under the awning on a hot day.")
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                Text("Toggle it any time from the ☀ button on the Level screen.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func sunPoint(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(Theme.sun).frame(width: 26)
            Text(text).font(.subheadline)
        }
    }

    // MARK: - Step 5 · Calibrate

    private var calibrateStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                stepHeader("Calibrate — one time", "Zero the phone so the level is spot-on. You only do this once.")
                PhoneFlatDiagram().frame(height: 150).accessibilityHidden(true)
                Text("Lay the phone exactly where it'll sit while you level — flat, screen up, top toward the front — on ground you KNOW is level. Then tap below.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                VStack(spacing: 4) {
                    Text(String(format: "%.1f°", calibDegOff))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(calibDegOff > 8 ? Theme.needsBigRamp : Color(.label))
                        .contentTransition(.numericText())
                    Text("reading right now").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    motion.calibrateHere(); Haptics.saved()
                } label: {
                    Label(motion.isCalibrated ? "Re-set level here" : "Set level here", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)
                if motion.isCalibrated {
                    Label("Calibrated", systemImage: "checkmark.seal.fill").font(.footnote).foregroundStyle(Theme.levelGreen)
                }
                Text("You can skip this and calibrate later from the dial — but it's quick, and worth it.")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private var calibDegOff: Double { max(abs(motion.rollDeg), abs(motion.pitchDeg)) }

    // MARK: - Nav bar

    private var navBar: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { step -= 1 }.buttonStyle(.bordered)
            }
            Button(step == lastStep ? "Finish" : "Next") {
                if step == lastStep { finish() } else { step += 1 }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(!canAdvance)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private var canAdvance: Bool {
        switch step {
        case 1: return Int(wheelbase) != nil && Int(trackFront) != nil && (!rearDiffers || Int(trackRear) != nil)
        case 2: return livingSide != nil
        default: return true
        }
    }

    // MARK: - Save

    private var sideBinding: Binding<LivingSide?> {
        Binding(get: { livingSide }, set: { livingSide = $0 })
    }

    private func finish() {
        guard let side = livingSide, let config = buildConfig(side: side) else { return }
        for old in existingConfigs { modelContext.delete(old) }
        modelContext.insert(config)
        dismiss()
    }

    private func buildConfig(side: LivingSide) -> VehicleConfig? {
        guard let wb = Int(wheelbase), let front = Int(trackFront) else { return nil }
        let rear = rearDiffers ? (Int(trackRear) ?? front) : front
        return VehicleConfig(presetId: nil, genId: nil, displayName: "My van",
                             wheelbaseMM: wb, trackFrontMM: front, trackRearMM: rear,
                             chassisKind: .measured, livingSide: side,
                             rampProfileId: rampProfileId, customStepsMM: customSteps,
                             usingTypicalDims: false)
    }

    private func prefillFromExisting() {
        guard let existing = existingConfigs.first else { return }
        wheelbase = String(existing.wheelbaseMM)
        trackFront = String(existing.trackFrontMM)
        if existing.trackRearMM != existing.trackFrontMM {
            rearDiffers = true
            trackRear = String(existing.trackRearMM)
        }
        livingSide = existing.livingSide
        rampProfileId = existing.rampProfileId
        if existing.customStepsMM.count == 3 { customSteps = existing.customStepsMM }
    }

    /// Which Setup field the AR camera measurement should fill in.
    enum MeasureTarget: String, Identifiable {
        case wheelbase, trackFront, trackRear
        var id: String { rawValue }
        var kind: MeasureKind { self == .wheelbase ? .wheelbase : .track }
    }

    private func applyMeasurement(_ target: MeasureTarget, _ mm: Int) {
        switch target {
        case .wheelbase: wheelbase = String(mm)
        case .trackFront: trackFront = String(mm)
        case .trackRear:  trackRear = String(mm)
        }
    }
}

// MARK: - Awning picker (the big interactive sit-side diagram)

/// Big top-view van with an awning on each side that ROLLS OUT when you tap it — the fun way to say
/// "this is the side I sit out on." Front points up (matches the Level dial).
struct AwningVan: View {
    let selection: LivingSide?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let vanW = min(w * 0.28, 120)
            let vanH = min(h * 0.86, vanW * 3.3)
            let cx = w / 2, cy = h / 2
            ZStack {
                // All four awnings live here but only the SELECTED one is open (scaled to 1); the
                // rest are collapsed at the van edge (scale 0). Selection change animates the swap.
                ForEach(LivingSide.allCases, id: \.self) { side in
                    awning(side, cx: cx, cy: cy, vanW: vanW, vanH: vanH)
                }
                Image("VanTop")
                    .resizable().scaledToFit()
                    .frame(width: vanH, height: vanW)     // sized landscape...
                    .rotationEffect(.degrees(-90))         // ...then stood up, front to the top
                    .frame(width: vanW, height: vanH)
                    .position(x: cx, y: cy)
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: selection)
        }
        .allowsHitTesting(false)   // selection is via the buttons above — the diagram is display-only
    }

    private func awning(_ side: LivingSide, cx: CGFloat, cy: CGFloat, vanW: CGFloat, vanH: CGFloat) -> some View {
        let selected = selection == side
        let horizontal = (side == .left || side == .right)
        let reach: CGFloat = horizontal ? vanW * 0.95 : vanH * 0.24    // how far it opens out
        let thickness: CGFloat = horizontal ? vanH * 0.6 : vanW * 0.96 // fitted to the van's edge length
        let cw = horizontal ? reach : thickness
        let ch = horizontal ? thickness : reach
        let px: CGFloat = side == .left ? cx - vanW / 2 - reach / 2
            : side == .right ? cx + vanW / 2 + reach / 2 : cx
        let py: CGFloat = side == .front ? cy - vanH / 2 - reach / 2
            : side == .rear ? cy + vanH / 2 + reach / 2 : cy
        let anchor: UnitPoint = side == .left ? .trailing : side == .right ? .leading
            : side == .front ? .bottom : .top

        return AwningCanopy(selected: selected, horizontal: horizontal, label: side.label)
            .frame(width: cw, height: ch)
            .scaleEffect(x: horizontal ? (selected ? 1 : 0) : 1,
                         y: horizontal ? 1 : (selected ? 1 : 0),
                         anchor: anchor)
            .position(x: px, y: py)
    }
}

/// The awning canopy itself — accent-coloured with fabric stripes and a leading valance bar.
private struct AwningCanopy: View {
    let selected: Bool
    let horizontal: Bool
    let label: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.9))
            // Stripes
            GeometryReader { g in
                let n = 6
                ForEach(0..<n, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white.opacity(i.isMultiple(of: 2) ? 0.18 : 0))
                        .frame(width: horizontal ? g.size.width / CGFloat(n) : g.size.width,
                               height: horizontal ? g.size.height : g.size.height / CGFloat(n))
                        .position(x: horizontal ? g.size.width / CGFloat(n) * (CGFloat(i) + 0.5) : g.size.width / 2,
                                  y: horizontal ? g.size.height / 2 : g.size.height / CGFloat(n) * (CGFloat(i) + 0.5))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(label.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(horizontal ? 0 : 0))
        }
        .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 4, y: 2)
    }
}

// MARK: - Shared bits

struct SelectionRing: View {
    let selected: Bool
    var body: some View {
        Circle()
            .strokeBorder(selected ? Color.accentColor : Color(.tertiaryLabel), lineWidth: 1.6)
            .background(Circle().fill(selected ? Color.accentColor : .clear).padding(3))
            .frame(width: 22, height: 22)
    }
}

struct ProPill: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.proBadge, in: RoundedRectangle(cornerRadius: 4))
    }
}
