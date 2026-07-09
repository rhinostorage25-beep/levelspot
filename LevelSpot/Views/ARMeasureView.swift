import SwiftUI
import RealityKit
import ARKit
import AVFoundation

/// Which dimension we're measuring — only changes the on-screen coaching, the maths is identical.
enum MeasureKind {
    case wheelbase, track

    var title: String { self == .wheelbase ? "Measure wheelbase" : "Measure track width" }

    func instruction(placingFirst: Bool) -> String {
        switch (self, placingFirst) {
        case (.wheelbase, true):  return "Aim the cross at where the FRONT wheel meets the ground, then tap Set."
        case (.wheelbase, false): return "Walk to the REAR wheel (keep the van in view), aim where it meets the ground, then tap Set."
        case (.track, true):      return "Stand back so both wheels on one axle show. Aim at the base of one wheel, then tap Set."
        case (.track, false):     return "Aim at the base of the OTHER wheel on the same axle, then tap Set."
        }
    }
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
        Image(systemName: "plus")
            .font(.system(size: 36, weight: .thin))
            .foregroundStyle(model.hasHit ? Color.green : Color.white)
            .shadow(radius: 3)
    }

    private var controls: some View {
        VStack {
            Text(model.phase == .done
                 ? "Happy with it? Use the figure, or redo."
                 : kind.instruction(placingFirst: model.phase == .first))
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.top, 8)

            Spacer()

            if let mm = model.phase == .done ? model.resultMM : model.liveMM {
                Text(Self.format(mm))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
            } else if !model.hasHit {
                Text("Move the phone slowly to find the surface…")
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
                    .padding(8).background(.black.opacity(0.45), in: Capsule())
            }

            buttonRow.padding().padding(.bottom, 8)
        }
    }

    @ViewBuilder private var buttonRow: some View {
        if model.phase == .done, let mm = model.resultMM {
            HStack(spacing: 12) {
                Button("Redo") { model.redo() }
                    .buttonStyle(.bordered).tint(.white)
                Button("Use \(mm) mm") { onConfirm(mm); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        } else {
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered).tint(.white)
                Button(model.phase == .first ? "Set first point" : "Set second point") { model.place() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasHit)
            }
            .controlSize(.large)
        }
    }

    private var unsupported: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.unknown").font(.largeTitle).foregroundStyle(.secondary)
            Text("Camera measuring isn't available on this device.").font(.headline)
            Text("No problem — type the figure in by hand instead. A tape measure between the centre of the two wheels does the job.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(.borderedProminent).padding(.top, 4)
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let arView else { return }
        let hit = centreHit(in: arView)
        DispatchQueue.main.async {
            self.hasHit = hit != nil
            if self.phase == .second, let p1 = self.p1, let hit {
                self.liveMM = Int((simd_distance(p1, hit) * 1000).rounded())
            }
        }
    }

    func place() {
        guard let arView, let point = centreHit(in: arView) else { return }
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
        guard let r = arView.raycast(from: centre, allowing: .estimatedPlane, alignment: .any).first else { return nil }
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
