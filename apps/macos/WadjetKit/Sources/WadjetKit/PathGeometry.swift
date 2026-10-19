import CoreGraphics
import Foundation

/// Builds each Annotation's drawable path and hit-tests its stroked outline.
/// Strokes have round caps and joins, as the Markup panels draw them.
public enum PathGeometry {
    public static func path(for a: Annotation) -> CGPath {
        switch a.kind {
        case let .line(start, end):
            let p = CGMutablePath()
            p.move(to: start); p.addLine(to: end)
            return p
        }
    }
    /// whether `point` lands on the stroked outline, widened by `tolerance` on each side
    public static func hitTest(_ a: Annotation, at point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        path(for: a)
            .copy(strokingWithWidth: a.style.width + 2 * tolerance,
                  lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point)
    }
}
