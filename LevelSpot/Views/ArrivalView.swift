import SwiftUI
import SwiftData
import MapKit

struct ArrivalView: View {
    let config: VehicleConfig

    @Environment(LocationService.self) private var location
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(EntitlementStore.self) private var entitlements
    @Query(sort: \PitchRecord.visitedAt, order: .reverse) private var pitches: [PitchRecord]

    @State private var showSetup = false
    @State private var showPaywall = false

    /// Match against the user's OWN history only, within a tight radius — falls back to a
    /// live scan when nothing is found. Local haversine so this works with zero signal.
    private var matchedPitch: (pitch: PitchRecord, distanceM: Int)? {
        guard let lat = location.latitude, let lon = location.longitude else { return nil }
        let candidates = pitches
            .map { ($0, $0.distanceM(latitude: lat, longitude: lon)) }
            .filter { $0.1 <= 25 }
            .sorted { $0.1 < $1.1 }
        return candidates.first.map { ($0.0, Int($0.1.rounded())) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !connectivity.isOnline {
                    infoBanner("wifi.slash", "No signal — showing your saved pitch data")
                }
                if let match = matchedPitch {
                    matchedContent(match.pitch, distanceM: match.distanceM)
                } else {
                    newPitchCard
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("LevelSpot")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSetup = true } label: {
                    Image(systemName: "car.side").accessibilityLabel("Vehicle settings")
                }
            }
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                Button(entitlements.isPro ? "⭐" : "🔒") { entitlements.debugToggle() }
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                LevelScanView(config: config)
            } label: {
                Text("Start Level Scan").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
        .navigationDestination(isPresented: $showSetup) { VehicleSetupView() }
        .sheet(isPresented: $showPaywall) { PaywallSheet() }
        .onAppear { location.requestAndStart() }
    }

    // MARK: - Matched pitch

    @ViewBuilder
    private func matchedContent(_ pitch: PitchRecord, distanceM: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pitch.siteName.isEmpty ? "Saved pitch" : pitch.siteName)
                .font(.title3.weight(.semibold))
            Text("your visit, matched \(distanceM)m away · \(pitch.rating) star\(pitch.rating == 1 ? "" : "s")")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        pitchMap(pitch)

        VStack(spacing: 0) {
            headingRow(color: Theme.levelGreen, title: "Level position",
                       detail: pitch.levelHeading.map { "Heading \($0)° · matches this pitch" } ?? "Corner data saved",
                       locked: false)
            Divider().padding(.leading, 52)
            headingRow(color: Theme.sun, title: "Best sun",
                       detail: headingDetail(pitch.sunHeading, thing: "sun"),
                       locked: !entitlements.isPro,
                       capture: canLog(pitch.sunHeading) ? { logHeading(pitch, \.sunHeading) } : nil)
            Divider().padding(.leading, 52)
            headingRow(color: Theme.view, title: "Best view",
                       detail: headingDetail(pitch.viewHeading, thing: "view"),
                       locked: !entitlements.isPro,
                       capture: canLog(pitch.viewHeading) ? { logHeading(pitch, \.viewHeading) } : nil)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

        if entitlements.isPro, conflictExists(pitch) {
            infoBanner("exclamationmark.triangle", "Sun and view face a different way to level — from your own past visits here.")
        }
    }

    private func pitchMap(_ pitch: PitchRecord) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: pitch.latitude, longitude: pitch.longitude)
        return Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0012, longitudeDelta: 0.0012)))) {
            UserAnnotation()
            Annotation("Level", coordinate: coordinate) {
                pin(color: Theme.levelGreen, symbol: "checkmark", locked: false)
            }
            if pitch.sunHeading != nil || !entitlements.isPro {
                Annotation("Sun", coordinate: offset(coordinate, headingDeg: pitch.sunHeading ?? 95)) {
                    pin(color: Theme.sun, symbol: "sun.max.fill", locked: !entitlements.isPro)
                }
            }
            if pitch.viewHeading != nil || !entitlements.isPro {
                Annotation("View", coordinate: offset(coordinate, headingDeg: pitch.viewHeading ?? 210)) {
                    pin(color: Theme.view, symbol: "mountain.2.fill", locked: !entitlements.isPro)
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .allowsHitTesting(false)
    }

    private func pin(color: Color, symbol: String, locked: Bool) -> some View {
        Image(systemName: locked ? "lock.fill" : symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(locked ? Color(.systemGray2) : color, in: Circle())
            .shadow(radius: 2)
    }

    private func offset(_ base: CLLocationCoordinate2D, headingDeg: Int) -> CLLocationCoordinate2D {
        let rad = Double(headingDeg) * .pi / 180
        let d = 0.0004
        return CLLocationCoordinate2D(latitude: base.latitude + cos(rad) * d,
                                      longitude: base.longitude + sin(rad) * d)
    }

    private func headingRow(color: Color, title: String, detail: String, locked: Bool,
                            capture: (() -> Void)? = nil) -> some View {
        Button {
            if locked { showPaywall = true }
            else { capture?() }
        } label: {
            HStack(spacing: 12) {
                Circle().fill(locked ? Color(.systemGray3) : color).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    // Locked, not hidden: the row stays visible so a free user can see the
                    // data exists — the value itself is redacted until Pro.
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .redacted(reason: locked ? .placeholder : [])
                }
                Spacer()
                if locked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock").font(.caption2)
                        Text("Pro").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                } else if capture != nil {
                    // Pro user, value not logged yet: a live "Log" affordance.
                    HStack(spacing: 4) {
                        Image(systemName: "location.north.line").font(.caption2)
                        Text("Log").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .disabled(!locked && capture == nil)
    }

    private func canLog(_ value: Int?) -> Bool {
        entitlements.isPro && value == nil && location.headingDeg != nil
    }

    private func headingDetail(_ value: Int?, thing: String) -> String {
        if let v = value { return "Heading \(v)°" }
        if entitlements.isPro {
            return location.headingDeg == nil
                ? "Point at the \(thing) to log — waiting for the compass"
                : "Tap Log — point the phone at the \(thing)"
        }
        return "Log on your next visit"
    }

    private func logHeading(_ pitch: PitchRecord, _ keyPath: ReferenceWritableKeyPath<PitchRecord, Int?>) {
        guard let h = location.headingDeg else { return }
        pitch[keyPath: keyPath] = h
        pitch.synced = false          // mark for re-upload on the next sync pass
        Haptics.saved()
    }

    private func conflictExists(_ pitch: PitchRecord) -> Bool {
        guard let level = pitch.levelHeading else { return false }
        let diffs = [pitch.sunHeading, pitch.viewHeading].compactMap { $0 }.map {
            let d = abs($0 - level) % 360
            return min(d, 360 - d)
        }
        return diffs.contains { $0 > 45 }
    }

    // MARK: - New pitch

    private var newPitchCard: some View {
        VStack(spacing: 12) {
            Image(systemName: location.latitude == nil ? "location" : "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(location.latitude == nil ? "Finding your position…" : "New pitch")
                .font(.headline)
            Text(location.latitude == nil
                 ? "GPS works without any signal — this only needs a moment."
                 : "You haven't levelled here before. Run a live scan and save it for next time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func infoBanner(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
