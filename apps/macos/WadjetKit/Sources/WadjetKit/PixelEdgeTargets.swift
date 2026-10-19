import CoreGraphics

extension Annotation {
    /// The perimeter moved/resized by selection grips. A Magnify's drawable path
    /// describes its separate source and leader; its grips belong to the frame.
    public var pixelSnapBounds: CGRect {
        if case .magnify = kind { return kind.bounds }
        return PathGeometry.path(for: self).boundingBoxOfPath
    }
}

extension CanvasDocument {
    /// The visible unannotated backdrop for one display, at its retained bitmap
    /// resolution. Window layers replace/composite the display as in the Editor;
    /// crop, rounded corners and Annotations must not contribute pixel targets.
    public func snappingImage(for display: CanvasDisplay) throws -> CGImage {
        guard let image = displayImages[display.id] else {
            throw CanvasDocumentError.invalidPackage(display.imageFileName)
        }
        guard windowLayers.contains(where: { $0.frame.intersects(display.frame) }) else { return image }
        var backdrop = self
        backdrop.layerStack = LayerStack()
        backdrop.cornerRadius = 0
        return try backdrop.flatten(crop: display.frame, scale: CGFloat(image.width) / display.frame.width)
    }
}

extension PixelBuffer {
    /// Measure's colour-run boundaries near the moving rectangle's perimeter or
    /// points. `bounds` positions this top-down bitmap in bottom-up Canvas/screen
    /// points; its size supplies the pixel scale, including retained SDR Canvases.
    /// Scans stop just beyond `range`, never traversing the rest of the image.
    public func snapTargets(rect: CGRect? = nil, points: [CGPoint] = [],
                            bounds: CGRect, range: CGFloat, tolerance: Int = 30) -> [SnapTarget] {
        guard range >= 0, width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let sx = CGFloat(width) / bounds.width, sy = CGFloat(height) / bounds.height
        var xs: [Int: ClosedRange<CGFloat>] = [:], ys: [Int: ClosedRange<CGFloat>] = [:]
        func merge(_ old: ClosedRange<CGFloat>?, _ span: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
            guard let old else { return span }
            return min(old.lowerBound, span.lowerBound)...max(old.upperBound, span.upperBound)
        }
        func scan(_ anchor: CGFloat, span: ClosedRange<CGFloat>, horizontal: Bool) {
            let scale = horizontal ? sx : sy
            let count = horizontal ? width : height
            let otherCount = horizontal ? height : width
            let position = horizontal ? (anchor - bounds.minX) * sx : (bounds.maxY - anchor) * sy
            guard position >= -range * scale, position <= CGFloat(count) + range * scale else { return }
            let seed = min(count - 1, max(0, Int(floor(position))))
            let lo = horizontal ? (bounds.maxY - span.upperBound) * sy : (span.lowerBound - bounds.minX) * sx
            let hi = horizontal ? (bounds.maxY - span.lowerBound) * sy : (span.upperBound - bounds.minX) * sx
            guard hi >= 0, lo < CGFloat(otherCount) else { return }
            let first = max(0, Int(floor(lo))), last = min(otherCount - 1, Int(floor(hi)))
            guard first <= last else { return }
            let limit = Int(ceil(range * scale)) + 1
            for cross in first...last {
                let run = self.run(through: horizontal ? seed : cross, horizontal ? cross : seed,
                                   along: horizontal ? .horizontal : .vertical,
                                   tolerance: tolerance, maxDistance: limit)
                for edge in [run.lowerBound, run.upperBound] {
                    // Image borders belong to display snapping. The extra pixel
                    // keeps an artificial bounded-run end outside the snap range.
                    guard edge > 0, edge < count, abs(CGFloat(edge) - position) <= range * scale else { continue }
                    let pixelSpan: ClosedRange<CGFloat> = horizontal
                        ? (bounds.maxY - CGFloat(cross + 1) / sy)...(bounds.maxY - CGFloat(cross) / sy)
                        : (bounds.minX + CGFloat(cross) / sx)...(bounds.minX + CGFloat(cross + 1) / sx)
                    if horizontal { xs[edge] = merge(xs[edge], pixelSpan) }
                    else { ys[edge] = merge(ys[edge], pixelSpan) }
                }
            }
        }
        if let rect, !rect.isNull {
            let r = rect.standardized
            for x in [r.minX, r.maxX] { scan(x, span: r.minY...r.maxY, horizontal: true) }
            for y in [r.minY, r.maxY] { scan(y, span: r.minX...r.maxX, horizontal: false) }
        }
        for p in points {
            scan(p.x, span: p.y...p.y, horizontal: true)
            scan(p.y, span: p.x...p.x, horizontal: false)
        }
        return xs.keys.sorted().map { .x(bounds.minX + CGFloat($0) / sx, span: xs[$0]) }
            + ys.keys.sorted().map { .y(bounds.maxY - CGFloat($0) / sy, span: ys[$0]) }
    }
}
