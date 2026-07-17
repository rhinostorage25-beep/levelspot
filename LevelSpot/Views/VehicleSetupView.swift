import SwiftUI
import SwiftData

/// First-run / edit onboarding as a paged wizard: language → measure → sit-side → ramps → sun →
/// calibrate. One clear thing per page, Back/Next at the bottom. The old single scrolling form is
/// gone. Reached from the dial's gear menu.
struct VehicleSetupView: View {
    /// `.firstRun` = the five-step onboarding (measure → side → ramps → sun → calibrate;
    /// language lives ONLY in Settings — it was here once and read as a duplicate).
    /// `.editActive` = single-page edit + Save, deep-linked from a Settings row via `startStep`.
    /// `.addNew` (Pro multi-vehicle) starts blank at the measure step and inserts alongside.
    enum SetupMode { case firstRun, editActive, addNew }
    let mode: SetupMode
    /// Steps run 1–5; there is no step 0 any more.
    private let firstStep = 1

    init(mode: SetupMode = .editActive, startStep: Int? = nil) {
        self.mode = mode
        _step = State(initialValue: min(max(startStep ?? 1, 1), 5))
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(MotionService.self) private var motion
    // Newest updatedAt first — .first is the ACTIVE vehicle (matches RootView's ordering).
    @Query(sort: \VehicleConfig.updatedAt, order: .reverse) private var existingConfigs: [VehicleConfig]
    private let ref = ReferenceStore.shared.data

    @State private var step: Int
    @State private var vehicleName = ""
    @State private var wheelbase = ""
    @State private var trackFront = ""
    @State private var trackRear = ""
    @State private var rearDiffers = false
    @State private var rampProfileId = "default"
    @State private var customSteps = [40, 70, 100]
    @State private var livingSide: LivingSide?
    @State private var showShop = false
    @State private var activeMeasure: MeasureTarget?
    @State private var didPrefill = false

    private let lastStep = 5

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Edits are single-page (deep-linked from Settings) — progress only makes sense
            // when there's an actual journey.
            if mode != .editActive { SetupProgress(step: step, total: lastStep).padding(.top, 10) }
            Group {
                switch step {
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
        .navigationTitle(mode == .editActive ? "Edit vehicle" : "Add vehicle")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: step)
        .sheet(isPresented: $showShop) { RampShopSheet(neededMM: nil) }
        .fullScreenCover(item: $activeMeasure) { target in
            ARMeasureView(kind: target.kind) { mm in applyMeasurement(target, mm) }
        }
        // onAppear fires AGAIN when the AR-measure fullScreenCover dismisses — prefill must run
        // once, or it wipes the value the camera just measured (didPrefill guards it).
        .onAppear { motion.start(); prefillFromExisting() }
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

    // MARK: - Step 1 · Measure

    private var measureStep: some View {
        ScrollView {
            VStack(spacing: 18) {
                stepHeader("Add your vehicle", "Add two measurements for accurate wheel-by-wheel guidance.")
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Vehicle name") {
                        TextField("My motorhome", text: $vehicleName)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                measureField(diagram: AnyView(VanPhoto("VanSide", fallback: AnyView(WheelbaseDiagram()))),
                             label: "Wheelbase (mm)", placeholder: "e.g. 3400",
                             text: $wheelbase, target: .wheelbase,
                             hint: "Measure between the centres of the front and rear wheels.")
                measureField(diagram: AnyView(VanPhoto("VanFront", fallback: AnyView(TrackDiagram()))),
                             label: "Front track width (mm)", placeholder: "e.g. 1800",
                             text: $trackFront, target: .trackFront,
                             hint: "Measure between the centres of the front wheels.")
                Toggle("Use a different rear track width", isOn: $rearDiffers.animation())
                    .padding(.horizontal)
                if rearDiffers {
                    measureField(diagram: AnyView(VanPhoto("VanFront", fallback: AnyView(TrackDiagram()))),
                                 label: "Rear track width (mm)", placeholder: "e.g. 1980",
                                 text: $trackRear, target: .trackRear,
                                 hint: "Measure between the centres of the rear wheels.")
                }
            }
            .padding(.vertical)
        }
    }

    /// What a real vehicle can measure (§12 plausibility). Warn outside these, never block —
    /// the user knows their vehicle; a silent typo corrupting every lift figure is the enemy.
    private func plausibleRange(for target: MeasureTarget) -> ClosedRange<Int> {
        target == .wheelbase ? 1800...5500 : 1200...2400
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
            if let value = Int(text.wrappedValue), !plausibleRange(for: target).contains(value) {
                Label("This looks unusual — check the measurement.", systemImage: "questionmark.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.needsRamp)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: - Step 2 · Sit side

    private var sitSideStep: some View {
        VStack(spacing: 16) {
            stepHeader("Which side is your awning on?", "Choose the side where the awning opens.")
            // Buttons at the top; the diagram below just shows the awning opening on that side.
            Picker("Side", selection: sideBinding) {
                ForEach(LivingSide.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            // Without this, a meaningful share of users pick the mirror image.
            Text("Left and right are viewed from inside the vehicle, facing forward.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
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
                stepHeader("Choose your levelling equipment", "Guidance will match the lift your equipment provides.")
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
                    Label("Find levelling equipment", systemImage: "cart").frame(maxWidth: .infinity)
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
                stepHeader("Plan for sun or shade", "LevelSpot shows which way to face the vehicle for morning, midday or evening.")
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 46)).foregroundStyle(Theme.sun)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    sunPoint("location.north.line.fill", "It reads the sun's position and your compass, then shows which way to face the vehicle.")
                    sunPoint("arrow.triangle.2.circlepath", "Turn the vehicle until the sun marker locks green at the top.")
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                Text("You can change this any time from the sun button.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
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
                stepHeader("Calibrate your phone", "You normally only need to do this once.")
                PhoneFlatDiagram().frame(height: 150).accessibilityHidden(true)
                Text("Place the phone screen-up on known level ground, with its top pointing toward the front of the vehicle.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                // ONE calibration implementation, shared with the dial's Calibrate sheet —
                // the two surfaces can't drift apart again.
                CalibrationPanel()
                    .padding(.horizontal)
                Text("It saves automatically after the countdown. You can also do this later from the dial.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    // MARK: - Nav bar

    private var navBar: some View {
        HStack(spacing: 12) {
            if mode == .editActive {
                // Deep-linked single-page edit: everything else is prefilled, so change the
                // one thing and Save — no marching through the remaining steps to get out.
                Button("Save") { finish() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(!canFinish)
            } else {
                if step > firstStep {
                    Button("Back") { step -= 1 }.buttonStyle(.bordered)
                }
                Button(step == lastStep ? "Finish setup" : "Continue") {
                    if step == lastStep { finish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!canAdvance)
            }
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

    /// The whole config must be saveable, whichever single page an edit landed on.
    private var canFinish: Bool {
        Int(wheelbase) != nil && Int(trackFront) != nil
            && (!rearDiffers || Int(trackRear) != nil) && livingSide != nil
    }

    // MARK: - Save

    private var sideBinding: Binding<LivingSide?> {
        Binding(get: { livingSide }, set: { livingSide = $0 })
    }

    private func finish() {
        guard let side = livingSide, let config = buildConfig(side: side) else { return }
        // INSERT before DELETE, then save explicitly. SwiftData flushes lazily — a force-quit
        // right after Save could discard the pending transaction, and delete-first ordering
        // makes the worst partial outcome "no vehicle at all" (which we appear to have hit
        // in the field). Insert-first + explicit save means the worst case is a duplicate,
        // which self-heals (newest updatedAt wins everywhere).
        modelContext.insert(config)
        if mode != .addNew, let active = existingConfigs.first, active !== config {
            modelContext.delete(active)
        }
        try? modelContext.save()
        dismiss()
    }

    private func buildConfig(side: LivingSide) -> VehicleConfig? {
        guard let wb = Int(wheelbase), let front = Int(trackFront) else { return nil }
        let rear = rearDiffers ? (Int(trackRear) ?? front) : front
        let trimmedName = vehicleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = mode == .addNew ? "Vehicle \(existingConfigs.count + 1)" : "My vehicle"
        return VehicleConfig(presetId: nil, genId: nil,
                             displayName: trimmedName.isEmpty ? fallbackName : trimmedName,
                             wheelbaseMM: wb, trackFrontMM: front, trackRearMM: rear,
                             chassisKind: .measured, livingSide: side,
                             rampProfileId: rampProfileId, customStepsMM: customSteps,
                             usingTypicalDims: false)
    }

    private func prefillFromExisting() {
        guard !didPrefill else { return }
        didPrefill = true
        guard mode == .editActive, let existing = existingConfigs.first else { return }
        vehicleName = existing.displayName
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

    /// MEASURED from van-top.png (1448×1086; drawn van occupies x 112–1378, y 228–774) — the
    /// awnings hug the van as DRAWN, not the image's whitespace. Previous versions eyeballed
    /// these against the frame and were ~2× off (the fitted image never fills the frame).
    /// The PNG is 4:3 with the front on the RIGHT; on screen it's rotated −90° (front up).
    /// Everything is a fraction of `vanW`, the on-screen width of the image box across the van.
    private enum M {
        static let aspect: CGFloat = 1448.0 / 1086.0
        static let visW: CGFloat = 0.503      // visible van width  = 546/1086 of the box height
        static let visH: CGFloat = 1.166      // visible van length = (1266/1448) · aspect
        static let centerDX: CGFloat = -0.039  // drawn-van centre offset from the box centre
        static let centerDY: CGFloat = -0.019  // (post-rotation screen coords)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // As big as fits. Bounds derived from the worst open-awning extents: sideways the
            // van+open awning spans ≈1.69×vanW (needs vanW ≤ 0.59·w); a front/rear awning's far
            // edge reaches ≈1.0×vanW from centre (needs vanW ≤ 0.49·h). On tall phones the width
            // term binds (≈240pt on a 430pt screen); the height term only guards short layouts.
            let vanW = min(w * 0.56, h * 0.48, 270)
            let cx = w / 2, cy = h / 2
            let vanCX = cx + M.centerDX * vanW
            let vanCY = cy + M.centerDY * vanW
            let halfW = M.visW * vanW / 2    // centre → the van's visible side edge
            let halfH = M.visH * vanW / 2    // centre → the visible nose/tail
            ZStack {
                // All four awnings live here but only the SELECTED one is open (scaled to 1); the
                // rest are collapsed at the van edge (scale 0). Selection change animates the swap.
                ForEach(LivingSide.allCases, id: \.self) { side in
                    awning(side, vanCX: vanCX, vanCY: vanCY, halfW: halfW, halfH: halfH)
                }
                Image("VanTop")
                    .resizable().scaledToFit()
                    .frame(width: vanW * M.aspect, height: vanW)   // box == image aspect: fills exactly
                    .rotationEffect(.degrees(-90))                  // front (image right) → up
                    .frame(width: vanW, height: vanW * M.aspect)
                    .blendMode(.multiply)                           // drop the white box into the page
                    .position(x: cx, y: cy)
            }
            .frame(width: w, height: h)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: selection)
        }
        .allowsHitTesting(false)   // selection is via the buttons above — the diagram is display-only
    }

    private func awning(_ side: LivingSide, vanCX: CGFloat, vanCY: CGFloat,
                        halfW: CGFloat, halfH: CGFloat) -> some View {
        let selected = selection == side
        let horizontal = (side == .left || side == .right)
        // Roll-out distance ≈ a real cassette awning: roughly the van's width when out.
        let reach: CGFloat = horizontal ? halfW * 2.2 : halfW * 1.6
        // Side awnings run the full visible roof; front/rear span the visible van width.
        let thickness: CGFloat = horizontal ? halfH * 2 * 0.97 : halfW * 2 * 0.95
        let cw = horizontal ? reach : thickness
        let ch = horizontal ? thickness : reach
        // The canopy's inner edge sits ON the drawn van's edge — measured, not guessed.
        let px: CGFloat = side == .left ? vanCX - halfW - reach / 2
            : side == .right ? vanCX + halfW + reach / 2 : vanCX
        let py: CGFloat = side == .front ? vanCY - halfH - reach / 2
            : side == .rear ? vanCY + halfH + reach / 2 : vanCY
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
                        // Stripes run ALONG the roll-out direction: horizontal for a left/right
                        // awning, vertical for a front/rear one.
                        .frame(width: horizontal ? g.size.width : g.size.width / CGFloat(n),
                               height: horizontal ? g.size.height / CGFloat(n) : g.size.height)
                        .position(x: horizontal ? g.size.width / 2 : g.size.width / CGFloat(n) * (CGFloat(i) + 0.5),
                                  y: horizontal ? g.size.height / CGFloat(n) * (CGFloat(i) + 0.5) : g.size.height / 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(label.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
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
