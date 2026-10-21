import CoreGraphics

/// Region maths for the live sampler's area-scoped streams.
public enum LiveSampling {
    /// union of `rects` (global points) clipped to `display`, rounded outward to whole points; nil when none touch it
    public static func union(of rects: [CGRect], on display: CGRect) -> CGRect? {
        let area = rects.filter { $0.intersects(display) }
            .reduce(nil as CGRect?) { u, r in u?.union(r.intersection(display)) ?? r.intersection(display) }
        guard let area, !area.isNull, !area.isEmpty else { return nil }
        return area.integral
    }
    /// a global (bottom-left) rect as SCStreamConfiguration.sourceRect: display-local points, top-left origin
    public static func sourceRect(_ rect: CGRect, on display: CGRect) -> CGRect {
        CGRect(x: rect.minX - display.minX,
               y: display.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
}
