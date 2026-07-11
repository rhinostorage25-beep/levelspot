import SwiftUI

// Shared "targeting-scope" primitives — used by the Level dial (LevelScanView) and the
// AR camera-measure reticle (ARMeasureView) so the two instruments read as one set.

/// The fixed targeting crosshair: four capped arms on the N/E/S/W axes, drawn around the centre.
/// Arm radii are absolute points, so the look stays consistent regardless of the frame size.
struct ScopeReticle: Shape {
    var inner: CGFloat = 16
    var outer: CGFloat = 48
    var cap: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        for deg in stride(from: 0.0, through: 270.0, by: 90.0) {
            let a = deg * .pi / 180
            let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
            let p1 = CGPoint(x: c.x + dx * inner, y: c.y + dy * inner)
            let p2 = CGPoint(x: c.x + dx * outer, y: c.y + dy * outer)
            p.move(to: p1); p.addLine(to: p2)
            let px = -dy, py = dx                       // perpendicular, for the end cap
            p.move(to: CGPoint(x: p2.x + px * cap, y: p2.y + py * cap))
            p.addLine(to: CGPoint(x: p2.x - px * cap, y: p2.y - py * cap))
        }
        return p
    }
}

/// An upward-pointing triangle — the compass nose marker and the needle's arrowhead.
struct ScopeTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A top-down van silhouette, FRONT AT THE TOP — sits under the Level dial so it's obvious which
/// way the van points on the leveller (the nose marker and the windscreen both sit at the top).
struct TopVanSilhouette: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // Wheels first (so the body sits over them), sticking slightly past the sides.
            let wheelW = w * 0.11, wheelH = h * 0.12
            for (cx, cy) in [(w * 0.12, h * 0.24), (w * 0.88, h * 0.24),
                             (w * 0.12, h * 0.80), (w * 0.88, h * 0.80)] {
                let wheel = Path(roundedRect: CGRect(x: cx - wheelW / 2, y: cy - wheelH / 2, width: wheelW, height: wheelH),
                                 cornerSize: CGSize(width: 3, height: 3))
                ctx.fill(wheel, with: .color(.black.opacity(0.6)))
            }
            // Body — rounded, nose (front) at the top.
            let body = Path(roundedRect: CGRect(x: w * 0.16, y: h * 0.03, width: w * 0.68, height: h * 0.94),
                            cornerSize: CGSize(width: w * 0.24, height: w * 0.24))
            ctx.fill(body, with: .color(.white.opacity(0.5)))
            ctx.stroke(body, with: .color(.white.opacity(0.75)), lineWidth: 1)
            // Windscreen band across the top = the front.
            let wind = Path(roundedRect: CGRect(x: w * 0.23, y: h * 0.08, width: w * 0.54, height: h * 0.09),
                            cornerSize: CGSize(width: 4, height: 4))
            ctx.fill(wind, with: .color(.black.opacity(0.32)))
        }
    }
}
