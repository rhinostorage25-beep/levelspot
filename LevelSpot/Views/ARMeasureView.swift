import SwiftUI
import RealityKit
import ARKit
import AVFoundation

/// Which dimension we're measuring — only changes the on-screen coaching, the maths is identical.
enum MeasureKind {
    case wheelbase, track

    var title: String { self == .wheelbase ? "Measure wheelbase" : "Measure track width" }

    /// "Front wheel · 1 of 2" — which point the user is placing, said plainly.
    func stepLabel(placingFirst: Bool) -> String {
        switch (self, placingFirst) {
        case (.wheelbase, true):  return "Front wheel · 1 of 2"
        case (.wheelbase, false): return "Rear wheel · 2 of 2"
        case (.track, true):      return "First wheel · 1 of 2"
        case (.track, false):     return "Other wheel · 2 of 2"
        }
    }

    func instruction(placingFirst: Bool) -> String {
        switch (self, placingFirst) {
        case (.wheelbase, true):  return "Scan the ground, then aim directly below the centre of the front wheel."
        case (.wheelbase, false): return "Move to the rear wheel and aim directly below its centre."
        case (.track, true):      return "Aim directly below the centre of one wheel on this axle."
        case (.track, false):     return "Move to the other wheel on this axle and aim directly below its centre."
        }
    }

    var resultLabel: String { self == .wheelbase ? "Wheelbase measured" : "Track width measured" }
}

/// Point-to-point AR measurement (ARKit world tracking + plane raycast — the Apple Measure app
/// technique). No LiDAR needed. Returns millimetres; the caller pre-fills a Setup field with it.
/// Fails safe: on an unsupported device it tells the owner to type the figure instead.
struct ARMeasureView: View {
    let kind: MeasureKind
    let onConfirm: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ARMeasureModel()

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                ARMeasureContainer(model: model).ignoresSafeArea()
                reticle
                controls
            } else {
                unsupported
            }
        }
        .onDisappear { model.pause() }
    }

    private var reticle: some View {
        let color: Color = model.hasHit ? Color.green : Color.white
        return ZStack {
            Circle().stroke(color.opacity(0.42), lineWidth: 1).frame(width: 132, height: 132)
            Circle().stroke(color.opacity(0.75), lineWidth: 1.5).frame(width: 92, height: 92)
            ScopeReticle().stroke(color, lineWidth: 1.6).frame(width: 140, height: 140)
            Circle().stroke(color, lineWidth: 1.6).frame(width: 14, height: 14)
            Circle().fill(color).frame(width: 4, height: 4)
        }
        // A soft shadow keeps the reticle legible over any camera background.
        .shadow(color: .black.opacity(0.7), radius: 2)
        .animation(.easeOut(duration: 0.15), value: model.hasHit)
    }

    private var controls: some View {
        VStack {
            VStack(spacing: 8) {
                // The hint diagram — the same annotated van image (red caliper on the tyre centres)
                // as Setup, so it's clear you measure tyre-centre to tyre-centre, not edge-to-edge.
                Image(kind == .wheelbase ? "VanSide" : "VanFront")
                    .resizable().scaledToFit()
                    .frame(height: 78)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                if model.phase != .done {
                    Text(kind.stepLabel(placingFirst: model.phase == .first))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(model.phase == .done
                     ? kind.resultLabel
                     : kind.instruction(placingFirst: model.phase == .first))
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if model.phase == .done {
                    // Honest precision: this is a camera estimate, not a tape measure.
                    Text("Camera estimate · approximately ±20 mm")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            // Fixed-height status zone — a constant slot so the capture button never shifts
            // position under the user's thumb as the readout appears/changes.
            Group {
                if let mm = model.phase == .done ? model.resultMM : model.liveMM {
                    Text(Self.format(mm))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                } else if model.hasHit {
                    Text("Ground found")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.45), in: Capsule())
                } else {
                    Text("Keep scanning — move the phone slowly over the ground")
                        .font(.footnote).foregroundStyle(.white.opacity(0.85))
                        .padding(8).background(.black.opacity(0.45), in: Capsule())
                }
            }
            .frame(height: 52)

            buttonRow.padding().padding(.bottom, 8)
        }
    }

    /// What a real vehicle can measure (§12 plausibility): outside this, warn — but let the
    /// user decide. A compact camper and an American RV both fit; two taps on the same wheel
    /// don't.
    private var plausibleRange: ClosedRange<Int> { kind == .wheelbase ? 1800...5500 : 1200...2400 }

    @ViewBuilder private var buttonRow: some View {
        if model.phase == .done, let mm = model.resultMM {
            VStack(spacing: 10) {
                if !plausibleRange.contains(mm) {
                    Text("This looks unusual for a \(kind == .wheelbase ? "wheelbase" : "track width") — check the measurement.")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 12) {
                    Button("Measure again") { model.redo() }
                        .buttonStyle(.bordered).tint(.white)
                    Button("Use \(mm) mm") { onConfirm(mm); dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        } else {
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered).tint(.white)
                Button(kind == .wheelbase
                       ? (model.phase == .first ? "Set front point" : "Set rear point")
                       : (model.phase == .first ? "Set first point" : "Set second point")) { model.place() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasHit)
            }
            .controlSize(.large)
        }
    }

    private var unsupported: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown").font(.largeTitle).foregroundStyle(.secondary)
            Text("Camera measurement unavailable").font(.headline)
            Text("Enter the measurement manually instead. Measure between the centres of the wheels.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Enter manually") { dismiss() }.buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .padding(32)
    }

    static func format(_ mm: Int) -> String {
        "\(mm) mm  ·  \(String(format: "%.2f", Double(mm) / 1000)) m"
    }
}

/// Owns the ARKit session state. `ObservableObject` (not `@Observable`) because it also has to be
/// the `ARSessionDelegate`, and it publishes at frame rate.
final class ARMeasureModel: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase { case first, second, done }

    @Published var phase: Phase = .first
    @Published var liveMM: Int?     // running distance while aiming the second point
    @Published var resultMM: Int?   // the confirmed measurement
    @Published var hasHit = false   // is the cross currently resting on a surface

    weak var arView: ARView?
    private var p1: SIMD3<Float>?
    private var lastHit: SIMD3<Float>?
    private var missFrames = 0

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let arView else { return }
        let hit = centreHit(in: arView)
        DispatchQueue.main.async {
            if let hit {
                self.lastHit = hit
                self.missFrames = 0
                if !self.hasHit { self.hasHit = true }
                if self.phase == .second, let p1 = self.p1 {
                    self.liveMM = Int((simd_distance(p1, hit) * 1000).rounded())
                }
            } else {
                // Grace period: a raycast dropping out for a frame or two must NOT flicker the
                // reticle green→white or disable the capture button under the user's thumb.
                self.missFrames += 1
                if self.missFrames > 15 {
                    self.lastHit = nil
                    if self.hasHit { self.hasHit = false }
                }
            }
        }
    }

    func place() {
        // Use the last good hit, so a tap during a momentary raycast drop-out still lands.
        guard let arView, let point = lastHit ?? centreHit(in: arView) else { return }
        addMarker(at: point, in: arView)
        switch phase {
        case .first:
            p1 = point
            phase = .second
        case .second:
            if let a = p1 { resultMM = Int((simd_distance(a, point) * 1000).rounded()) }
            phase = .done
        case .done:
            break
        }
    }

    func redo() {
        arView?.scene.anchors.removeAll()
        p1 = nil; liveMM = nil; resultMM = nil; phase = .first
    }

    func pause() {
        arView?.session.pause()
        // Release the audio session the camera grabbed, so the level-scan beeps can re-claim it.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// World-space point under the centre reticle, via an estimated-plane raycast (works even
    /// before a full plane is detected, from feature points).
    private func centreHit(in arView: ARView) -> SIMD3<Float>? {
        let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Once ARKit has found the GROUND plane, extend it to infinity and raycast against THAT —
        // so the cross lands on the ground even when it's aimed over a featureless black tyre
        // (the tyre has no trackable features, but the tarmac/grass around it does). Fall back to
        // an estimated plane from feature points before the ground plane is established.
        let ground = arView.raycast(from: centre, allowing: .existingPlaneInfinite, alignment: .horizontal).first
        guard let r = ground ?? arView.raycast(from: centre, allowing: .estimatedPlane, alignment: .any).first
        else { return nil }
        let c = r.worldTransform.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    private func addMarker(at point: SIMD3<Float>, in arView: ARView) {
        let anchor = AnchorEntity(world: point)
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.012),
                                 materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)])
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
    }
}

private struct ARMeasureContainer: UIViewRepresentable {
    let model: ARMeasureModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none
        view.session.delegate = model
        view.session.run(config)
        model.arView = view
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
