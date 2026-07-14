import SwiftUI
import SwiftData
import LevelSpotCore

// The "Perfect Pitch" Pro pack — sun presets, sleep tilt, and pitch memory. All of it is
// comfort-layer: nothing here is on the free money path (coaching/shop stay free).

// MARK: - Sun presets (Pro)

/// A moment of the day the sun planner aims at. Each preset pairs a time with a sun/shade
/// preference so the menu stays one flat list (no two-axis picker). `.now` tracks the clock.
enum SunMoment: String, CaseIterable, Identifiable {
    case now, morningSun, middayShade, eveningSun
    var id: String { rawValue }

    // Time labels are uniform ("Now/Morning/Midday/Evening"); the RESULT (sun vs shade) is
    // described separately in the guidance line — mixing "Morning sun" with "Midday shade"
    // in one list made the picker describe two different kinds of thing.
    var label: String {
        switch self {
        case .now: return "Now"
        case .morningSun: return "Morning"
        case .middayShade: return "Midday"
        case .eveningSun: return "Evening"
        }
    }

    var icon: String {
        switch self {
        case .now: return "sun.max"
        case .morningSun: return "sunrise"
        case .middayShade: return "cloud.sun"
        case .eveningSun: return "sunset"
        }
    }

    /// Midday is when you want the awning's SHADE; morning/evening you chase the sun itself.
    var preference: SunPreference { self == .middayShade ? .shade : .sun }

    /// Caption fragment: "Facing <goal> — good spot".
    var goal: String {
        switch self {
        case .now: return "the sun"
        case .morningSun: return "morning sun"
        case .middayShade: return "midday shade"
        case .eveningSun: return "evening sun"
        }
    }

    /// The instant to aim the planner at (today, local time).
    func date() -> Date {
        let hourMinute: (Int, Int)?
        switch self {
        case .now: hourMinute = nil
        case .morningSun: hourMinute = (8, 30)
        case .middayShade: hourMinute = (13, 30)
        case .eveningSun: hourMinute = (18, 30)
        }
        guard let (h, m) = hourMinute else { return Date() }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }
}

// MARK: - Sleep setup (Pro)

/// Where the bed's HEAD end is. When set, the level target shifts ~0.5° so the head ends up a
/// touch high (~15mm over a 2m bed) — imperceptible to a fridge, noticeable to a sleeper.
/// Sign conventions match the core maths: pitch > 0 = nose high, roll > 0 = left high.
enum SleepHeadEnd: String, CaseIterable, Identifiable {
    case off, front, rear, left, right
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off — dead level"
        case .front: return "Head at the front"
        case .rear: return "Head at the rear"
        case .left: return "Head on the left"
        case .right: return "Head on the right"
        }
    }

    var icon: String {
        switch self {
        case .off: return "minus.circle"
        case .front: return "arrow.up.to.line"
        case .rear: return "arrow.down.to.line"
        case .left: return "arrow.left.to.line"
        case .right: return "arrow.right.to.line"
        }
    }

    /// How high (deg) the head end should sit above true level.
    static let tiltDeg = 0.5

    var pitchTargetDeg: Double {
        switch self {
        case .front: return Self.tiltDeg
        case .rear: return -Self.tiltDeg
        default: return 0
        }
    }

    var rollTargetDeg: Double {
        switch self {
        case .left: return Self.tiltDeg
        case .right: return -Self.tiltDeg
        default: return 0
        }
    }
}

// MARK: - Settings (the gear — ONE tap to everything)

/// What a Settings row wants the Level screen to do after the sheet closes. Runs from the
/// sheet's onDismiss so the navigation push / paywall never races the sheet's dismissal.
enum SettingsAction {
    case openWizard(VehicleSetupView.SetupMode, startStep: Int)
    case shop
    case paywall
    case testWindAlert   // beta-only row — see proPreviewSection
}

/// The gear's ONE-TAP settings screen. Everything actionable is either done right here
/// (switch vehicle, sleep tilt, language) or one row-tap away at the exact wizard step
/// (measurements / awning side / ramps) — the full six-step wizard only runs on first
/// setup or when adding a vehicle. Free users see the locked Pro rows: honest upsell.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementStore.self) private var entitlements
    @Query(sort: \VehicleConfig.updatedAt, order: .reverse) private var vehicles: [VehicleConfig]
    @AppStorage("sleepHeadEnd") private var sleepHeadEndRaw = SleepHeadEnd.off.rawValue
    @AppStorage("appLanguageCode") private var languageCode = "en"

    let onAction: (SettingsAction) -> Void

    /// LIVE, not a frozen init parameter — flipping the Pro-preview toggle below must unlock
    /// the sleep and add-vehicle rows in THIS open sheet, not the next one.
    private var isPro: Bool { entitlements.isPro }

    private let languages: [(code: String, name: String, flag: String)] = [
        ("en", "English", "🇬🇧"), ("de", "Deutsch", "🇩🇪"), ("fr", "Français", "🇫🇷"),
        ("it", "Italiano", "🇮🇹"), ("es", "Español", "🇪🇸"), ("nl", "Nederlands", "🇳🇱"),
    ]

    var body: some View {
        NavigationStack {
            List {
                vehicleSection
                sleepSection
                windSection
                shopSection
                languageSection
                proPreviewSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Vehicle

    @ViewBuilder private var vehicleSection: some View {
        if vehicles.isEmpty {
            Section {
                Button { act(.openWizard(.firstRun, startStep: 1)) } label: {
                    Label("Measure your van", systemImage: "ruler")
                }
            } footer: {
                Text("Two measurements, your awning side and your ramps — unlocks exact figures instead of ≈ estimates.")
            }
        } else {
            Section("Vehicle") {
                // Switcher (Pro adds more vehicles; switching is instant, right here).
                // Display order is alphabetical and STABLE — the query sorts by updatedAt,
                // and switching touches updatedAt, so iterating the query directly would
                // reshuffle the rows under the user's finger. Active still = query's first.
                ForEach(vehicles.sorted(by: { $0.displayName < $1.displayName })) { v in
                    Button {
                        v.updatedAt = .now   // newest updatedAt = active (no schema change)
                        try? modelContext.save()
                    } label: {
                        HStack {
                            Text(v.displayName).foregroundStyle(.primary)
                            Spacer()
                            if v.persistentModelID == vehicles.first?.persistentModelID {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                Button {
                    if isPro { act(.openWizard(.addNew, startStep: 1)) } else { act(.paywall) }
                } label: {
                    Label(isPro ? "Add another vehicle" : "Add another vehicle — Pro",
                          systemImage: isPro ? "plus" : "lock.fill")
                }
            }
            if let active = vehicles.first {
                Section("Edit \(active.displayName)") {
                    // Deep links: straight to the RIGHT wizard step — no six-step march.
                    settingsRow("ruler", "Size & measurements",
                                "\(active.wheelbaseMM)mm wheelbase · \(active.trackFrontMM)mm track") {
                        act(.openWizard(.editActive, startStep: 1))
                    }
                    settingsRow("beach.umbrella", "Awning side", active.livingSide.label) {
                        act(.openWizard(.editActive, startStep: 2))
                    }
                    settingsRow("arrow.up.to.line.compact", "Ramps", rampName(active)) {
                        act(.openWizard(.editActive, startStep: 3))
                    }
                }
            }
        }
    }

    private func rampName(_ config: VehicleConfig) -> String {
        config.rampProfileId == "custom"
            ? "Custom steps"
            : ReferenceStore.shared.rampProfile(id: config.rampProfileId)?.name ?? "Generic 3-step"
    }

    private func settingsRow(_ icon: String, _ title: String, _ value: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(.primary)
                Spacer()
                Text(value).font(.footnote).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Sleep (inline — two taps, not a buried sheet)

    @ViewBuilder private var sleepSection: some View {
        Section {
            if isPro {
                Picker(selection: $sleepHeadEndRaw) {
                    ForEach(SleepHeadEnd.allCases) { end in
                        Text(end.label).tag(end.rawValue)
                    }
                } label: {
                    Label("Sleep tilt", systemImage: "bed.double.fill")
                }
                .pickerStyle(.menu)
            } else {
                Button { act(.paywall) } label: {
                    HStack {
                        Label("Sleep tilt — Pro", systemImage: "lock.fill").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Comfort")
        } footer: {
            Text("Tilts the level target half a degree toward your pillow (~15mm over a 2m bed) — the dial, degrees and ramp coaching all aim at it. Still fridge-safe.")
        }
    }

    // MARK: Language

    private var languageSection: some View {
        Section {
            Picker(selection: $languageCode) {
                ForEach(languages, id: \.code) { lang in
                    Text("\(lang.flag)  \(lang.name)").tag(lang.code)
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
            .pickerStyle(.menu)
        } footer: {
            Text("The app is in English for now — the other languages are coming soon.")
        }
    }

    // MARK: Wind alerts

    @AppStorage("windAlertsOn") private var windAlertsOn = true

    /// Awning wind alerts (Pro): warn before forecast gusts get awning-threatening.
    private var windSection: some View {
        Section {
            if isPro {
                Toggle(isOn: $windAlertsOn) {
                    Label("Wind alerts", systemImage: "wind")
                }
            } else {
                Button { act(.paywall) } label: {
                    HStack {
                        Label("Wind alerts — Pro", systemImage: "lock.fill").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
            }
        } footer: {
            Text("Warns you — in app and by notification — when gusts forecast at your pitch could threaten the awning (25 mph+). Weather data by [Apple Weather](https://weatherkit.apple.com/legal-attribution.html).")
        }
    }

    // MARK: Shop

    /// The shop shouldn't need hunting for — it's a permanent, honest storefront row here,
    /// and the coaching card on the dial deep-links in with the exact height needed.
    private var shopSection: some View {
        Section {
            Button { act(.shop) } label: {
                HStack {
                    Label("Shop levelling ramps", systemImage: "cart").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("Real UK ramps, cheapest first. The coaching on the dial links here with the exact height your pitch needs.")
        }
    }

    // MARK: TestFlight Pro preview

    /// ⚠️ BETA-ONLY LEVER — the whole section MUST be deleted before App Store submission
    /// (see the levelspot-pro-test-unlock memory note). Replaces the old hidden long-press on
    /// the calibrate icon, which was undiscoverable and broke the moment the toolbar changed.
    /// Real purchases always win over this flag (see EntitlementStore.updateEntitlement).
    private var proPreviewSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { entitlements.previewProOn },
                set: { entitlements.setPreviewPro($0) }
            )) {
                Label("Pro preview", systemImage: "wand.and.stars")
            }
            Button { act(.testWindAlert) } label: {
                Label("Test wind alert", systemImage: "wind")
            }
        } header: {
            Text("TestFlight testing")
        } footer: {
            Text("Beta-only tools, removed before App Store release. Pro preview flips every Pro feature on without a purchase. Test wind alert fakes a 38 mph warning — capsule on the dial immediately, notification about 5 seconds later (needs Pro preview + Wind alerts on).")
        }
    }

    private func act(_ action: SettingsAction) {
        onAction(action)
        dismiss()
    }
}

// MARK: - Pitch memory (Pro)

/// What "Done — you're level" hands to the save sheet: where we are + the levelling recipe
/// captured when the user tapped Start (by Done, the tilt reads ~zero, so we snapshot early).
struct SavePitchData: Identifiable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
    let heading: Int?
    let fl: Double
    let fr: Double
    let rl: Double
    let rr: Double
}

enum PitchRecipe {
    /// "Front Left ~70mm · Rear Left ~40mm", or the honest zero-case.
    static func summary(fl: Double, fr: Double, rl: Double, rr: Double) -> String {
        let corners: [(String, Double)] = [
            ("Front Left", fl), ("Front Right", fr), ("Rear Left", rl), ("Rear Right", rr),
        ]
        let ramped = corners.filter { $0.1 >= 10 }
        guard !ramped.isEmpty else { return "Dead level — no ramps needed." }
        return ramped.map { "\($0.0) ~\(Int($0.1.rounded()))mm" }.joined(separator: " · ")
    }

    static func summary(_ pitch: PitchRecord) -> String {
        summary(fl: pitch.cornerFLmm, fr: pitch.cornerFRmm, rl: pitch.cornerRLmm, rr: pitch.cornerRRmm)
    }
}

/// Pro sheet offered after "Done — you're level": name the pitch, keep the recipe for next time.
struct SavePitchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let data: SavePitchData
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 40)).foregroundStyle(Color.accentColor)
                Text("Save this pitch?").font(.title2.weight(.bold))
                Text("Next time you're back, LevelSpot recalls exactly what it took to get level here.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                Label(PitchRecipe.summary(fl: data.fl, fr: data.fr, rl: data.rl, rr: data.rr),
                      systemImage: "arrow.up.circle")
                    .font(.footnote.weight(.semibold))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                TextField("Name it — e.g. Lakeside pitch 14", text: $name)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let record = PitchRecord(
                        latitude: data.latitude, longitude: data.longitude,
                        levelHeading: data.heading,
                        corners: (fl: data.fl, fr: data.fr, rl: data.rl, rr: data.rr),
                        rating: 0,
                        siteName: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    modelContext.insert(record)
                    Haptics.saved()
                    dismiss()
                } label: {
                    Label("Save pitch", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

                Button("Not now") { dismiss() }
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Pro sheet from the "saved pitch nearby" banner: the recipe from last time, plus delete.
struct PitchDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let pitch: PitchRecord

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(Color.accentColor)
                Text(pitch.siteName.isEmpty ? "Saved pitch" : pitch.siteName)
                    .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                Text("Levelled here \(pitch.visitedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What it took last time").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Label(PitchRecipe.summary(pitch), systemImage: "arrow.up.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                Text("Park roughly where you did before and set up the same way — you should land level (or very close) first try.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)

                Button(role: .destructive) {
                    modelContext.delete(pitch)
                    dismiss()
                } label: {
                    Label("Delete this pitch", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }
}
