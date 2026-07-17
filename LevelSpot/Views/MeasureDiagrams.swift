import SwiftUI
import UIKit

// MARK: - Hint diagrams
//
// Simple line-art van outlines with a dimension caliper drawn between the CENTRE of the tyres —
// the measurement the levelling maths actually needs (tape from tyre-centre to tyre-centre), and
// the one people get wrong: measuring edge-to-edge reads short and throws every ramp figure out.
// Kept deliberately plain so they read at a glance over a form row or a live camera feed.

/// Filled arrowhead at `p`, pointing left (`pointingLeft`) or right.
private func arrowhead(_ ctx: GraphicsContext, at p: CGPoint, pointingLeft: Bool, color: Color) {
    let s: CGFloat = 5
    let dir: CGFloat = pointingLeft ? 1 : -1
    var a = Path()
    a.move(to: p)
    a.addLine(to: CGPoint(x: p.x + dir * s, y: p.y - s * 0.6))
    a.addLine(to: CGPoint(x: p.x + dir * s, y: p.y + s * 0.6))
    a.closeSubpath()
    ctx.fill(a, with: .color(color))
}

/// A tyre-centre marker: a small ring + dot in the accent tint, so "measure to HERE" is unmistakable.
private func centreMark(_ ctx: GraphicsContext, at p: CGPoint, color: Color) {
    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color), lineWidth: 1.4)
    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(color))
}

/// Side view — the wheelbase caliper, front tyre centre → rear tyre centre.
struct WheelbaseDiagram: View {
    var line: Color = .secondary
    var tint: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let ground = h * 0.66
            let bodyTop = h * 0.16
            let r = min(w, h) * 0.11
            let rearX = w * 0.26, frontX = w * 0.74      // tyre centres

            // High-top panel-van body (a plain bread-loaf reads as this van's shape).
            let body = Path(roundedRect: CGRect(x: w * 0.06, y: bodyTop, width: w * 0.88, height: ground - bodyTop),
                            cornerSize: CGSize(width: 8, height: 8))
            ctx.stroke(body, with: .color(line), lineWidth: 2)
            // A cab window near the front for orientation.
            let win = Path(roundedRect: CGRect(x: w * 0.74, y: bodyTop + 6, width: w * 0.16, height: (ground - bodyTop) * 0.32),
                           cornerSize: CGSize(width: 3, height: 3))
            ctx.stroke(win, with: .color(line.opacity(0.6)), lineWidth: 1.3)

            for x in [rearX, frontX] {
                let wheel = Path(ellipseIn: CGRect(x: x - r, y: ground - r, width: r * 2, height: r * 2))
                ctx.fill(wheel, with: .color(line.opacity(0.18)))
                ctx.stroke(wheel, with: .color(line), lineWidth: 1.6)
            }

            // Caliper beneath, between the two tyre centres.
            let capY = h * 0.92
            var dim = Path()
            dim.move(to: CGPoint(x: rearX, y: ground)); dim.addLine(to: CGPoint(x: rearX, y: capY))
            dim.move(to: CGPoint(x: frontX, y: ground)); dim.addLine(to: CGPoint(x: frontX, y: capY))
            dim.move(to: CGPoint(x: rearX, y: capY)); dim.addLine(to: CGPoint(x: frontX, y: capY))
            ctx.stroke(dim, with: .color(tint), lineWidth: 1.6)
            arrowhead(ctx, at: CGPoint(x: rearX, y: capY), pointingLeft: false, color: tint)
            arrowhead(ctx, at: CGPoint(x: frontX, y: capY), pointingLeft: true, color: tint)
            centreMark(ctx, at: CGPoint(x: rearX, y: ground), color: tint)
            centreMark(ctx, at: CGPoint(x: frontX, y: ground), color: tint)
        }
    }
}

/// Front view — the track caliper, left tyre centre → right tyre centre.
struct TrackDiagram: View {
    var line: Color = .secondary
    var tint: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let ground = h * 0.66
            let bodyTop = h * 0.10
            let r = min(w, h) * 0.11
            let leftX = w * 0.30, rightX = w * 0.70      // tyre centres

            let body = Path(roundedRect: CGRect(x: w * 0.22, y: bodyTop, width: w * 0.56, height: ground - bodyTop),
                            cornerSize: CGSize(width: 8, height: 8))
            ctx.stroke(body, with: .color(line), lineWidth: 2)
            // Windscreen band across the top.
            let win = Path(roundedRect: CGRect(x: w * 0.26, y: bodyTop + 6, width: w * 0.48, height: (ground - bodyTop) * 0.26),
                           cornerSize: CGSize(width: 3, height: 3))
            ctx.stroke(win, with: .color(line.opacity(0.6)), lineWidth: 1.3)

            for x in [leftX, rightX] {
                let wheel = Path(ellipseIn: CGRect(x: x - r, y: ground - r, width: r * 2, height: r * 2))
                ctx.fill(wheel, with: .color(line.opacity(0.18)))
                ctx.stroke(wheel, with: .color(line), lineWidth: 1.6)
            }

            let capY = h * 0.92
            var dim = Path()
            dim.move(to: CGPoint(x: leftX, y: ground)); dim.addLine(to: CGPoint(x: leftX, y: capY))
            dim.move(to: CGPoint(x: rightX, y: ground)); dim.addLine(to: CGPoint(x: rightX, y: capY))
            dim.move(to: CGPoint(x: leftX, y: capY)); dim.addLine(to: CGPoint(x: rightX, y: capY))
            ctx.stroke(dim, with: .color(tint), lineWidth: 1.6)
            arrowhead(ctx, at: CGPoint(x: leftX, y: capY), pointingLeft: false, color: tint)
            arrowhead(ctx, at: CGPoint(x: rightX, y: capY), pointingLeft: true, color: tint)
            centreMark(ctx, at: CGPoint(x: leftX, y: ground), color: tint)
            centreMark(ctx, at: CGPoint(x: rightX, y: ground), color: tint)
        }
    }
}

/// Side view — a phone lying flat on a level surface, with a centred bubble, for the calibrate screen.
struct PhoneFlatDiagram: View {
    var line: Color = .secondary
    var tint: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let surfaceY = h * 0.66

            // The surface it's resting on.
            var surface = Path()
            surface.move(to: CGPoint(x: w * 0.08, y: surfaceY)); surface.addLine(to: CGPoint(x: w * 0.92, y: surfaceY))
            ctx.stroke(surface, with: .color(line.opacity(0.5)), lineWidth: 2)
            // Little hatch ticks under it, to read as "ground".
            for i in 0..<7 {
                let x = w * (0.14 + Double(i) * 0.12)
                var t = Path(); t.move(to: CGPoint(x: x, y: surfaceY)); t.addLine(to: CGPoint(x: x - 6, y: surfaceY + 7))
                ctx.stroke(t, with: .color(line.opacity(0.35)), lineWidth: 1.2)
            }

            // The phone, flat.
            let phone = Path(roundedRect: CGRect(x: w * 0.24, y: surfaceY - h * 0.12, width: w * 0.52, height: h * 0.12),
                             cornerSize: CGSize(width: 5, height: 5))
            ctx.stroke(phone, with: .color(line), lineWidth: 2)
            // A bubble vial on top, bubble dead-centre = level.
            let vial = Path(roundedRect: CGRect(x: w * 0.40, y: surfaceY - h * 0.09, width: w * 0.20, height: h * 0.05),
                            cornerSize: CGSize(width: h * 0.025, height: h * 0.025))
            ctx.stroke(vial, with: .color(line.opacity(0.6)), lineWidth: 1.2)
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.485, y: surfaceY - h * 0.082, width: h * 0.035, height: h * 0.035)),
                     with: .color(tint))

            // "Top → front" arrow above the phone.
            let ay = surfaceY - h * 0.20
            var arr = Path()
            arr.move(to: CGPoint(x: w * 0.44, y: ay)); arr.addLine(to: CGPoint(x: w * 0.60, y: ay))
            ctx.stroke(arr, with: .color(tint), lineWidth: 1.6)
            arrowhead(ctx, at: CGPoint(x: w * 0.60, y: ay), pointingLeft: true, color: tint)
        }
    }
}

/// Shows a bundled van illustration (the clean drawings in Assets.xcassets: VanSide / VanFront) for
/// the measure hints. Falls back to the line-art diagram until the PNG is dropped into the imageset,
/// so the screen is never blank.
struct VanPhoto: View {
    let asset: String
    let fallback: AnyView

    init(_ asset: String, fallback: AnyView) {
        self.asset = asset
        self.fallback = fallback
    }

    var body: some View {
        if UIImage(named: asset) != nil {
            Image(asset).resizable().scaledToFit()
        } else {
            fallback
        }
    }
}

// MARK: - Calibrate as its own complete screen

/// Zeroing the phone/mount tilt — its own focused screen (not a toolbar alert). Essential on modern
/// phones: the camera bump means a phone laid face-up on genuinely flat ground still reads a couple
/// of degrees until it's calibrated here.
struct CalibrateView: View {
    @Environment(MotionService.self) private var motion
    @Environment(\.dismiss) private var dismiss
    // Value-critical text scales with Dynamic Type like every other reading in the app.
    @ScaledMetric(relativeTo: .largeTitle) private var tiltValueSize: CGFloat = 32

    private var degOff: Double { max(abs(motion.rollDeg), abs(motion.pitchDeg)) }
    private var looksOff: Bool { degOff > 8 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    PhoneFlatDiagram()
                        .frame(height: 150)
                        .padding(.top, 14)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("Calibrate your phone")
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("Place the phone screen-up on known level ground, with its top pointing toward the front of the vehicle. This cancels the tilt from the phone's camera bump and your mount.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal)

                    VStack(spacing: 4) {
                        Text(String(format: "Current tilt: %.1f°", degOff))
                            .font(.system(size: tiltValueSize, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(looksOff ? Theme.needsBigRamp : Color(.label))
                            .contentTransition(.numericText())
                        if !looksOff {
                            Text("Surface appears level.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if !looksOff, motion.isCalibrated {
                        Label("Already calibrated", systemImage: "checkmark.seal.fill")
                            .font(.footnote).foregroundStyle(Theme.levelGreen)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    // The reason lives NEXT TO the disabled button — at accessibility type
                    // sizes the scroll content is several screens tall, and a dimmed primary
                    // button with its explanation below the fold explains nothing.
                    if looksOff {
                        Text(motion.isCalibrated
                             ? "Move the phone to level ground — or reset the calibration if this surface is level."
                             : "Move the phone to level ground before calibrating.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Disabled while clearly invalid: saving a 28° "calibration" would bake
                    // the tilt into every future reading.
                    Button {
                        motion.calibrateHere(); Haptics.saved(); dismiss()
                    } label: {
                        Label("Calibrate here", systemImage: "scope").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(looksOff)
                    .accessibilityHint(looksOff ? "Disabled until the phone is on level ground." : "")
                    if motion.isCalibrated {
                        Button(role: .destructive) { motion.resetCalibration() } label: {
                            Text("Reset calibration")
                                .font(.footnote)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding().background(.bar)
            }
            .navigationTitle("Calibrate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { motion.start() }
        }
    }
}
