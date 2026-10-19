import CoreGraphics
import Foundation

/// Builds each Annotation's drawable path and hit-tests its stroked outline.
/// Strokes have round caps and joins, as the Markup panels draw them.
public enum PathGeometry {
    /// the geometry's path in screen coordinates — drawn and hit-tested
    /// through the Annotation's transform
    public static func path(for a: Annotation) -> CGPath {
        let p = CGMutablePath()
        switch a.kind {
        case let .line(start, end):
            p.move(to: start); p.addLine(to: end)
        }
        var t = a.affineTransform
        return p.copy(using: &t) ?? p
    }
    /// whether `point` lands on the stroked outline, widened by `tolerance` on each side
    public static func hitTest(_ a: Annotation, at point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        path(for: a)
            .copy(strokingWithWidth: a.style.width + 2 * tolerance,
                  lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point)
    }
}
