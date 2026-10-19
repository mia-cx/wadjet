import CoreGraphics
import Foundation

/// Builds each Annotation's drawable path and hit-tests it: stroked kinds hit
/// on their widened outline, filled kinds anywhere inside. Strokes have round
/// caps and joins, as the Markup panels draw them.
public enum PathGeometry {
    /// the geometry's path in screen coordinates — drawn and hit-tested
    /// through the Annotation's transform
    public static func path(for a: Annotation) -> CGPath {
        let p = CGMutablePath()
        switch a.kind {
        case let .line(start, end):
            p.move(to: start); p.addLine(to: end)
        case let .censor(rect, _):
            p.addRect(rect)
        }
        var t = a.affineTransform
        return p.copy(using: &t) ?? p
    }
    /// whether `point` hits the Annotation: a filled kind contains it, a stroked
    /// kind's outline widened by `tolerance` on each side does
    public static func hitTest(_ a: Annotation, at point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        let p = path(for: a)
        switch a.kind {
        case .censor:
            return p.contains(point) || (tolerance > 0 && p.copy(strokingWithWidth: 2 * tolerance,
                lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point))
        case .line:
            return p.copy(strokingWithWidth: a.style.width + 2 * tolerance,
                          lineCap: .round, lineJoin: .round, miterLimit: 10)
                .contains(point)
        }
    }
}
