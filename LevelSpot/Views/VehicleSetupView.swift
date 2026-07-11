import SwiftUI
import SwiftData

/// Setup is deliberately vehicle-agnostic: no make/model, no registration lookup, no country-specific
/// data. Levelling only needs the physical dimensions (wheelbase + track) plus which side you sit out
/// on (for the sun planner) and your ramps — the same physics anywhere in the world. Measure once.
struct VehicleSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementStore.self) private var entitlements
    @Query private var existingConfigs: [VehicleConfig]

    private let ref = ReferenceStore.shared.data

    @State private var wheelbase = ""
    @State private var trackFront = ""
    @State private var trackRear = ""
    @State private var rearDiffers = false
    @State private var rampsExpanded = false
    @State private var rampProfileId = "default"
    @State private var customSteps = [40, 70, 100]
    @State private var livingSide: LivingSide?
    @State private var showPaywall = false
    @State private var showShop = false
    @State private var activeMeasure: MeasureTarget?

    /// Which measurement the AR camera flow should fill in.
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

    var body: some View {
        List {
            Section {
                measureField(diagram: AnyView(VanPhoto("VanSide", fallback: AnyView(WheelbaseDiagram()))),
                             label: "Wheelbase (mm)", placeholder: "e.g. 3400",
                             text: $wheelbase, target: .wheelbase,
                             hint: "Centre of the front tyre to centre of the rear tyre.")
                measureField(diagram: AnyView(VanPhoto("VanFront", fallback: AnyView(TrackDiagram()))),
                             label: "Track width (mm)", placeholder: "e.g. 1800",
                             text: $trackFront, target: .trackFront,
                             hint: "Centre to centre of the two FRONT tyres, across the van.")
                Toggle("Rear track is different", isOn: $rearDiffers.animation())
                if rearDiffers {
                    measureField(diagram: AnyView(VanPhoto("VanFront", fallback: AnyView(TrackDiagram()))),
                                 label: "Rear track (mm)", placeholder: "e.g. 1980",
                                 text: $trackRear, target: .trackRear,
                                 hint: "Centre to centre of the two REAR tyres — wider on some chassis.")
                }
            } header: {
                Text("Measure your van")
            } footer: {
                Text("Just two measurements — no make or model needed, so LevelSpot works for any vehicle, anywhere. Measure with the camera or type them in. All figures in millimetres.")
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
                Text("Used by the sun & shade planner to work out which way to face the van. Driver's / Passenger side, so it reads the same in left- and right-hand-drive countries.")
            }

            Section("Your levelling ramps") {
                rampSummaryRow
                if rampsExpanded { rampOptions }
                Button { showShop = true } label: {
                    Label("Shop levelling ramps", systemImage: "cart")
                }
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
        .navigationTitle("Set up")
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .sheet(isPresented: $showShop) { RampShopSheet(neededMM: nil) }
        .fullScreenCover(item: $activeMeasure) { target in
            ARMeasureView(kind: target.kind) { mm in applyMeasurement(target, mm) }
        }
        .onAppear(perform: prefillFromExisting)
    }

    // MARK: - Measurement row

    /// One measurement: the hint diagram, a typed field, a "measure with camera" button, and the
    /// centre-of-tyre reminder — the mistake being measuring edge-to-edge (reads short).
    private func measureField(diagram: AnyView, label: String, placeholder: String,
                              text: Binding<String>, target: MeasureTarget, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            diagram
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            LabeledContent(label) {
                TextField(placeholder, text: text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            Button { activeMeasure = target } label: {
                Label("Measure with camera", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
                    Text(profile.capacityLabel)
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
        return activeRampProfile.map { $0.capacityLabel } ?? ""
    }

    // MARK: - Continue

    private var sideBinding: Binding<LivingSide?> {
        Binding(get: { livingSide }, set: { livingSide = $0 })
    }

    private var canContinue: Bool {
        guard livingSide != nil,
              Int(wheelbase) != nil, Int(trackFront) != nil else { return false }
        if rearDiffers { return Int(trackRear) != nil }
        return true
    }

    private func continueTapped() {
        guard let side = livingSide, let config = buildConfig(side: side) else { return }
        for old in existingConfigs { modelContext.delete(old) }
        modelContext.insert(config)
        dismiss() // always pushed from the dial now — pop back to it
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
                    // Same top-view van image as the Level dial (front pointing up).
                    Image("VanTop")
                        .resizable().scaledToFit()
                        .rotationEffect(.degrees(-90))
                        .frame(width: 128, height: 208)
                    VStack {
                        bar(.front, horizontal: true)
                        Spacer()
                        bar(.rear, horizontal: true)
                    }
                    .padding(4)
                    HStack {
                        bar(.passenger, horizontal: false)
                        Spacer()
                        bar(.driver, horizontal: false)
                    }
                    .padding(4)
                }
                .frame(width: 150, height: 224)
                edgeLabel(.rear)
            }
            edgeLabel(.driver).rotationEffect(.degrees(90)).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    private func bar(_ side: LivingSide, horizontal: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(selection == side ? Color.accentColor : Color(.tertiaryLabel))
            .frame(width: horizontal ? 72 : 10, height: horizontal ? 10 : 128)
            .contentShape(Rectangle().inset(by: -10))
            .onTapGesture { selection = side }
    }

    private func edgeLabel(_ side: LivingSide) -> some View {
        Text(side.label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(selection == side ? Color.accentColor : Color(.tertiaryLabel))
            .onTapGesture { selection = side }
    }
}
