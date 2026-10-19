import CoreGraphics

/// Geometry for the colour control's hue ring and saturation/lightness
/// triangle. Unit space: centre at the origin, y UP, triangle circumradius 1 —
/// the app's view converts screen points (y down) into it. A hue of h degrees
/// sits at unit angle h, counter-clockwise from +x: red at +x, yellow 60°,
/// green 120°. The triangle's vertices for a hue are H (pure hue, S=1 L=0.5)
/// at angle h, W (white) at h+120°, and K (black) at h+240° on the unit circle.
public enum ColourWheel {
    /// the hue under a unit-space point: atan2 → degrees normalised into 0..<360
    public static func hue(at p: CGPoint) -> Double {
        var h = (atan2(p.y, p.x) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h == 360 ? 0 : h
    }

    /// the unit-space point for an S/L pair at a hue. Barycentric weights
    /// hw·H + ww·W + kw·K with colour = hw·pure + ww·white give
    /// C = (1 − |2L − 1|)·S, hw = C, ww = L − C/2.
    public static func point(saturation: Double, lightness: Double, hue: Double) -> CGPoint {
        let (H, W, K) = (vertex(hue), vertex(hue + 120), vertex(hue + 240))
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hw = c, ww = lightness - c / 2, kw = 1 - hw - ww
        return CGPoint(x: hw * H.x + ww * W.x + kw * K.x,
                       y: hw * H.y + ww * W.y + kw * K.y)
    }

    /// S/L under a unit-space point at a hue: the point's barycentric weights
    /// give C = hw and L = hw/2 + ww, then S = C / (1 − |2L − 1|). A point
    /// outside the triangle clamps to the nearest point on an edge first.
    public static func saturationLightness(at p: CGPoint, hue: Double) -> (saturation: Double, lightness: Double) {
        let (H, W, K) = (vertex(hue), vertex(hue + 120), vertex(hue + 240))
        var (hw, ww, _) = barycentric(p, H, W, K)
        if hw < 0 || ww < 0 || hw + ww > 1 {
            (hw, ww, _) = barycentric(nearestOnTriangle(p, H, W, K), H, W, K)
        }
        // corner float noise otherwise divides a phantom chroma by ~0
        hw = max(0, hw); ww = max(0, ww)
        let l = min(1, max(0, hw / 2 + ww))
        let d = 1 - abs(2 * l - 1)
        // at the black/white corners chroma and its bound vanish together —
        // float noise would otherwise give a junk saturation
        let s = d < 1e-12 ? 0 : min(1, max(0, hw / d))
        return (s, l)
    }

    private static func vertex(_ deg: Double) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: cos(a), y: sin(a))
    }

    /// weights (a, b, c) summing to 1; a negative weight means p is outside
    private static func barycentric(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> (Double, Double, Double) {
        let d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
        let wa = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / d
        let wb = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / d
        return (wa, wb, 1 - wa - wb)
    }

    /// the closest point to p on the triangle's three edges
    private static func nearestOnTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPoint {
        [nearestOnSegment(p, a, b), nearestOnSegment(p, b, c), nearestOnSegment(p, c, a)]
            .min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) } ?? a
    }

    private static func nearestOnSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    }
}
