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

// (TopVanSilhouette was deleted 2026-07-16 — defined since the first dial build but never
// referenced; the dial draws the real VanTop image instead. See redesign-audit-2026-07-13.md.)
