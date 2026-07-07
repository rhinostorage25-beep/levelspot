import SwiftUI
import SwiftData

struct VehicleSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementStore.self) private var entitlements
    @Query private var existingConfigs: [VehicleConfig]

    private let ref = ReferenceStore.shared.data

    // Selection state (mirrors the design handoff's state model)
    @State private var regInput = ""
    @State private var regResultText: String?
    @State private var regLookupFailed = false
    @State private var lookupInFlight = false
    @State private var selectedPresetId: String?
    @State private var isManual = false
    @State private var manualWheelbase = ""
    @State private var manualTrack = ""
    @State private var wheelbaseIndex = 0
    @State private var chassisAnswer: ChassisAnswer?
    @State private var chassisManualTrack = ""
    @State private var chassisExpanded = false
    @State private var rampsExpanded = false
    @State private var rampProfileId = "default"
    @State private var customSteps = [40, 70, 100]
    @State private var livingSide: LivingSide?
    @State private var showPaywall = false
    @State private var showPairing = false

    enum ChassisAnswer: String { case standard, alko, notSure }

    var body: some View {
        List {
            Section {
                registrationCard
            } header: {
                Text("Look up by registration")
            } footer: {
                Text("This lookup service is occasionally unavailable — you can always choose your vehicle from the list below instead.")
            }

            Section("Choose your vehicle") {
                ForEach(ref.setupPresets) { preset in
                    presetRow(preset)
                }
                manualRow
                if isManual { manualFields }
                if let wb = selectedWheelbases, wb.count > 1 { wheelbasePicker(wb) }
            } footer: {
                if usingTypicalDims, let name = selectedPresetName {
                    Text("Using typical dimensions for \(name) — readings will be labelled **Estimated**. Choose \"Enter manually\" and measure your own for an exact fit.")
                }
            }

            if showChassisQuestion {
                Section {
                    chassisSummaryRow
                    if chassisExpanded { chassisOptions }
                } header: {
                    Text("Chassis type")
                } footer: {
                    Text("Coachbuilt motorhomes often sit on a widened rear chassis for extra stability — enough to change which ramp step we'd recommend. Usually named in the handbook or brochure (\"AL-KO chassis\").")
                }
            }

            Section {
                SideDiagram(selection: $livingSide)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                Picker("Living side", selection: sideBinding) {
                    ForEach(LivingSide.allCases, id: \.self) { side in
                        Text(side.label).tag(Optional(side))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Which side do you sit out on?")
            } footer: {
                Text("We say Driver's / Passenger side rather than nearside/offside — those flip meaning between left- and right-hand-drive markets.")
            }

            Section("Your levelling ramps") {
                rampSummaryRow
                if rampsExpanded { rampOptions }
            }

            Section {
                Button {
                    showPairing = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen1.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Spare-Device Sensor").foregroundStyle(.primary)
                            Text(existingConfigs.first?.spareDeviceName.map { "Paired · \($0)" } ?? "Not set up")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } footer: {
                Text("LevelSpot works fully offline, no account needed. Sign in only to sync your pitch history across your own devices.")
            }

            Section {
                Button(action: continueTapped) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("Vehicle Setup")
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .navigationDestination(isPresented: $showPairing) { PairingView() }
        .onAppear(perform: prefillFromExisting)
    }

    // MARK: - Registration lookup

    private var registrationCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                Text("GB")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 44)
                    .background(Color(red: 0, green: 0.2, blue: 0.6))
                TextField("AB12 CDE", text: $regInput)
                    .font(.system(size: 19, weight: .bold))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .frame(height: 44)
                    .background(Color(red: 1, green: 0.82, blue: 0))
                    .foregroundStyle(.black)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.8), lineWidth: 1.5))

            Button(action: { Task { await lookup() } }) {
                if lookupInFlight {
                    Text("Looking up…").frame(maxWidth: .infinity)
                } else {
                    Text("Look Up").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(regInput.trimmingCharacters(in: .whitespaces).isEmpty || lookupInFlight)

            if let result = regResultText {
                Label(result, systemImage: "checkmark")
                    .font(.footnote)
                    .foregroundStyle(Theme.levelGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if regLookupFailed {
                Text("Couldn't match that registration — pick your vehicle from the list below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    private func lookup() async {
        lookupInFlight = true
        regLookupFailed = false
        regResultText = nil
        defer { lookupInFlight = false }
        do {
            let result = try await SupabaseAPI.lookupRegistration(regInput)
            guard result.found, let make = result.make else {
                regLookupFailed = true // expected for coachbuilts registered under the converter's make
                return
            }
            if let preset = ReferenceStore.shared.matchPreset(make: make, model: result.model, year: result.manufactureYear) {
                selectPreset(preset.id)
                let year = result.manufactureYear.map(String.init) ?? ""
                regResultText = "Matched: \(make) \(result.model ?? "") \(year)"
            } else {
                regResultText = "Found \(make)\(result.manufactureYear.map { ", \($0)" } ?? "") — confirm your exact vehicle below."
            }
        } catch {
            regLookupFailed = true
        }
    }

    // MARK: - Vehicle list

    private func presetRow(_ preset: SetupPreset) -> some View {
        Button {
            selectPreset(preset.id)
        } label: {
            HStack(spacing: 12) {
                VanSilhouette(kind: preset.silhouette)
                    .frame(width: 46, height: 26)
                    .foregroundStyle(.secondary)
                Text(preset.name).foregroundStyle(.primary)
                Spacer()
                SelectionRing(selected: selectedPresetId == preset.id)
            }
        }
        .buttonStyle(.plain)
    }

    private var manualRow: some View {
        Button {
            isManual = true
            selectedPresetId = nil
            chassisAnswer = nil
            chassisManualTrack = ""
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ruler")
                    .frame(width: 46)
                    .foregroundStyle(.secondary)
                Text("Enter manually").foregroundStyle(.primary)
                Spacer()
                SelectionRing(selected: isManual)
            }
        }
        .buttonStyle(.plain)
    }

    private var manualFields: some View {
        Group {
            LabeledContent("Wheelbase (mm)") {
                TextField("e.g. 3400", text: $manualWheelbase)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Track width (mm)") {
                TextField("e.g. 1800", text: $manualTrack)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func wheelbasePicker(_ variants: [Int]) -> some View {
        Picker("Wheelbase", selection: $wheelbaseIndex) {
            ForEach(Array(variants.enumerated()), id: \.offset) { index, mm in
                Text("\(mm)mm").tag(index)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Chassis question (collapsed row pattern)

    private var showChassisQuestion: Bool {
        guard let id = selectedPresetId,
              let preset = ref.setupPresets.first(where: { $0.id == id }) else { return false }
        return preset.silhouette == "hightop" // Ducato, Sprinter/Crafter — the coachbuilt donor platforms
    }

    private var chassisSummaryRow: some View {
        Button {
            chassisExpanded.toggle()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(chassisSummaryTitle).foregroundStyle(.primary)
                    Text(chassisSummarySubtitle)
                        .font(.caption)
                        .foregroundStyle(chassisIncomplete ? Theme.needsRamp : Color.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(chassisExpanded ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    private var chassisOptions: some View {
        Group {
            chassisOption(.standard, "Standard chassis", "Same as the base van you picked above")
            chassisOption(.alko, "Widened (AL-KO) chassis", "Common on coachbuilt motorhomes — check your handbook")
            chassisOption(.notSure, "Not sure", "We'll ask you to measure your rear track")
            if chassisAnswer == .alko || chassisAnswer == .notSure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chassisAnswer == .notSure
                         ? "Rear track (mm) — measure between the centre of the rear tyres"
                         : "Exact rear track (mm) — optional, we'll use a typical AL-KO figure if left blank")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(chassisAnswer == .notSure ? "e.g. 1980" : "typical: \(ref.alkoTypicalRearTrackMM)",
                              text: $chassisManualTrack)
                        .keyboardType(.numberPad)
                }
            }
        }
    }

    private func chassisOption(_ answer: ChassisAnswer, _ title: String, _ subtitle: String) -> some View {
        Button {
            chassisAnswer = answer
            // A complete answer collapses back; one needing a follow-up figure stays open.
            chassisExpanded = (answer != .standard)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SelectionRing(selected: chassisAnswer == answer)
            }
        }
        .buttonStyle(.plain)
    }

    private var chassisIncomplete: Bool {
        showChassisQuestion && (chassisAnswer == nil || (chassisAnswer == .notSure && chassisManualTrack.isEmpty))
    }

    private var chassisSummaryTitle: String {
        switch chassisAnswer {
        case .standard: return "Standard chassis"
        case .alko: return "Widened (AL-KO) chassis"
        case .notSure: return "Not sure"
        case nil: return "Chassis type"
        }
    }

    private var chassisSummarySubtitle: String {
        switch chassisAnswer {
        case .standard: return "Same as the base van"
        case .alko:
            return chassisManualTrack.isEmpty
                ? "Using a typical \(ref.alkoTypicalRearTrackMM)mm rear track"
                : "Rear track: \(chassisManualTrack)mm"
        case .notSure:
            return chassisManualTrack.isEmpty
                ? "Measurement needed before you continue"
                : "Rear track measured: \(chassisManualTrack)mm"
        case nil: return "Tap to check — needed for this vehicle"
        }
    }

    // MARK: - Ramps (collapsed row pattern)

    private var rampSummaryRow: some View {
        Button {
            rampsExpanded.toggle()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(activeRampProfile?.name ?? "Custom").foregroundStyle(.primary)
                        if activeRampProfile?.pro == true { ProPill() }
                    }
                    Text(rampSummarySubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(rampsExpanded ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
    }

    private var rampOptions: some View {
        Group {
            ForEach(ref.rampProfiles) { profile in
                rampRow(profile)
            }
            rampRowCustom
            if rampProfileId == "custom" {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        TextField("Step \(i + 1)", value: $customSteps[i], format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private func rampRow(_ profile: RampProfileRef) -> some View {
        let locked = profile.pro && !entitlements.isPro
        return Button {
            if locked {
                showPaywall = true
            } else {
                rampProfileId = profile.id
                rampsExpanded = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(profile.name).foregroundStyle(.primary)
                        if profile.pro { ProPill() }
                    }
                    Text(profile.stepsMm.map(String.init).joined(separator: " / ") + "mm")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if locked {
                    Image(systemName: "lock").foregroundStyle(.tertiary)
                } else {
                    SelectionRing(selected: rampProfileId == profile.id)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var rampRowCustom: some View {
        Button {
            rampProfileId = "custom" // needs its step inputs — stays open
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Custom").foregroundStyle(.primary)
                    Text("Enter your own steps").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SelectionRing(selected: rampProfileId == "custom")
            }
        }
        .buttonStyle(.plain)
    }

    private var activeRampProfile: RampProfileRef? {
        ReferenceStore.shared.rampProfile(id: rampProfileId)
    }

    private var rampSummarySubtitle: String {
        if rampProfileId == "custom" {
            return customSteps.map(String.init).joined(separator: " / ") + "mm"
        }
        return activeRampProfile.map { $0.stepsMm.map(String.init).joined(separator: " / ") + "mm" } ?? ""
    }

    // MARK: - Continue

    private var sideBinding: Binding<LivingSide?> {
        Binding(get: { livingSide }, set: { livingSide = $0 })
    }

    private var selectedPresetName: String? {
        selectedPresetId.flatMap { id in ref.setupPresets.first { $0.id == id }?.name }
    }

    private var selectedGeneration: GenerationRef? {
        selectedPresetId
            .flatMap { id in ref.setupPresets.first { $0.id == id } }
            .flatMap { ReferenceStore.shared.generation(id: $0.genId) }
    }

    private var selectedWheelbases: [Int]? {
        selectedGeneration?.wheelbasesMm
    }

    private var usingTypicalDims: Bool { selectedPresetId != nil && !isManual }

    private var canContinue: Bool {
        guard livingSide != nil else { return false }
        if isManual {
            return Int(manualWheelbase) != nil && Int(manualTrack) != nil && !chassisIncomplete
        }
        return selectedPresetId != nil && !chassisIncomplete
    }

    private func selectPreset(_ id: String) {
        selectedPresetId = id
        isManual = false
        wheelbaseIndex = 0
        chassisAnswer = nil
        chassisManualTrack = ""
        chassisExpanded = false
    }

    private func continueTapped() {
        // The one hard-block: an unanswered chassis question on an AL-KO-eligible vehicle.
        // Surface it (expand the row) rather than silently refusing to navigate.
        if chassisIncomplete {
            chassisExpanded = true
            return
        }
        guard let side = livingSide, let config = buildConfig(side: side) else { return }
        for old in existingConfigs { modelContext.delete(old) }
        modelContext.insert(config)
        if !existingConfigs.isEmpty { dismiss() } // edit mode returns; first run switches via RootView
    }

    private func buildConfig(side: LivingSide) -> VehicleConfig? {
        if isManual {
            guard let wb = Int(manualWheelbase), let track = Int(manualTrack) else { return nil }
            return VehicleConfig(presetId: nil, genId: nil, displayName: "Custom vehicle",
                                 wheelbaseMM: wb, trackFrontMM: track, trackRearMM: track,
                                 chassisKind: .measured, livingSide: side,
                                 rampProfileId: rampProfileId, customStepsMM: customSteps,
                                 usingTypicalDims: false)
        }
        guard let gen = selectedGeneration, let name = selectedPresetName,
              let front = gen.trackFrontMm, let rearStandard = gen.trackRearMm else { return nil }
        let wheelbase = gen.wheelbasesMm.indices.contains(wheelbaseIndex)
            ? gen.wheelbasesMm[wheelbaseIndex] : gen.wheelbasesMm[0]
        let (rear, kind): (Int, ChassisKind) = {
            switch chassisAnswer {
            case .alko:
                return (Int(chassisManualTrack) ?? ref.alkoTypicalRearTrackMM, .alko)
            case .notSure:
                return (Int(chassisManualTrack) ?? rearStandard, .measured)
            default:
                return (rearStandard, .standard)
            }
        }()
        // Any preset keeps the ESTIMATED tag even when the rear track was hand-measured —
        // wheelbase and front track are still the generation's typical figures.
        return VehicleConfig(presetId: selectedPresetId, genId: gen.genId, displayName: name,
                             wheelbaseMM: wheelbase, trackFrontMM: front, trackRearMM: rear,
                             chassisKind: kind, livingSide: side,
                             rampProfileId: rampProfileId, customStepsMM: customSteps,
                             usingTypicalDims: true)
    }

    private func prefillFromExisting() {
        guard let existing = existingConfigs.first else { return }
        selectedPresetId = existing.presetId
        isManual = existing.presetId == nil
        if isManual {
            manualWheelbase = String(existing.wheelbaseMM)
            manualTrack = String(existing.trackRearMM)
        }
        if let wbs = selectedWheelbases, let idx = wbs.firstIndex(of: existing.wheelbaseMM) {
            wheelbaseIndex = idx
        }
        livingSide = existing.livingSide
        rampProfileId = existing.rampProfileId
        if existing.customStepsMM.count == 3 { customSteps = existing.customStepsMM }
        switch existing.chassisKind {
        case .standard: chassisAnswer = .standard
        case .alko: chassisAnswer = .alko
        case .measured: chassisAnswer = existing.presetId == nil ? nil : .notSure
        }
        if existing.chassisKind != .standard { chassisManualTrack = String(existing.trackRearMM) }
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

/// Custom flat side-profile silhouettes — the brief's one deliberate exception to
/// SF-Symbols-only, since no built-in symbol distinguishes a van body shape. Three shapes
/// cover every preset (low-top / high-top LWB / compact panel).
struct VanSilhouette: View {
    let kind: String

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var body = Path()
            switch kind {
            case "hightop":
                body.addRoundedRect(in: CGRect(x: 1, y: 1, width: w - 2, height: h * 0.82), cornerSize: CGSize(width: 4, height: 4))
            case "compact":
                body.move(to: CGPoint(x: 2, y: h * 0.9))
                body.addLine(to: CGPoint(x: 2, y: h * 0.55))
                body.addQuadCurve(to: CGPoint(x: w * 0.28, y: h * 0.28), control: CGPoint(x: w * 0.05, y: h * 0.3))
                body.addLine(to: CGPoint(x: w * 0.82, y: h * 0.22))
                body.addQuadCurve(to: CGPoint(x: w - 2, y: h * 0.5), control: CGPoint(x: w - 2, y: h * 0.25))
                body.addLine(to: CGPoint(x: w - 2, y: h * 0.9))
                body.closeSubpath()
            default: // lowtop
                body.move(to: CGPoint(x: 2, y: h * 0.9))
                body.addLine(to: CGPoint(x: 2, y: h * 0.45))
                body.addQuadCurve(to: CGPoint(x: w * 0.18, y: h * 0.28), control: CGPoint(x: w * 0.04, y: h * 0.3))
                body.addLine(to: CGPoint(x: w * 0.8, y: h * 0.28))
                body.addQuadCurve(to: CGPoint(x: w - 2, y: h * 0.55), control: CGPoint(x: w - 2, y: h * 0.3))
                body.addLine(to: CGPoint(x: w - 2, y: h * 0.9))
                body.closeSubpath()
            }
            context.stroke(body, with: .style(.secondary), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            let wheelY = h * 0.9
            for x in [w * 0.22, w * 0.78] {
                let wheel = Path(ellipseIn: CGRect(x: x - 3.5, y: wheelY - 3.5, width: 7, height: 7))
                context.fill(wheel, with: .style(.secondary))
            }
        }
    }
}

/// Top-down van diagram with four independently tappable edges — front / driver / rear /
/// passenger — mirroring the segmented control beneath it.
struct SideDiagram: View {
    @Binding var selection: LivingSide?

    var body: some View {
        HStack(spacing: 10) {
            edgeLabel(.passenger).rotationEffect(.degrees(-90)).fixedSize()
            VStack(spacing: 4) {
                edgeLabel(.front)
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(.tertiaryLabel), lineWidth: 1.6)
                        .frame(width: 76, height: 132)
                    VStack {
                        bar(.front, horizontal: true)
                        Spacer()
                        bar(.rear, horizontal: true)
                    }
                    .padding(6)
                    HStack {
                        bar(.passenger, horizontal: false)
                        Spacer()
                        bar(.driver, horizontal: false)
                    }
                    .padding(6)
                }
                .frame(width: 96, height: 148)
                edgeLabel(.rear)
            }
            edgeLabel(.driver).rotationEffect(.degrees(90)).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    private func bar(_ side: LivingSide, horizontal: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(selection == side ? Color.accentColor : Color(.tertiaryLabel))
            .frame(width: horizontal ? 48 : 8, height: horizontal ? 8 : 84)
            .contentShape(Rectangle().inset(by: -8))
            .onTapGesture { selection = side }
    }

    private func edgeLabel(_ side: LivingSide) -> some View {
        Text(side.label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(selection == side ? Color.accentColor : Color(.tertiaryLabel))
            .onTapGesture { selection = side }
    }
}
