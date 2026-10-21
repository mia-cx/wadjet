import CoreGraphics
import Foundation

/// Eraser's variants, picked from its menu's tile row and cycled by scroll:
/// the round eraser, and the Knife which cuts Annotations apart along a line
public enum EraserVariant: String, CaseIterable, Sendable {
    case eraser, knife
    public var title: String { self == .eraser ? "Eraser" : "Knife" }
    /// SF Symbol
    public var symbol: String { self == .eraser ? "eraser" : "scissors" }
    public var variant: ToolVariant { ToolVariant(id: rawValue, title: title, symbol: symbol) }
}

/// One Eraser drag over a stack: the round eraser's swept path, and the
/// visible, unlocked Annotations whose painted area (PathGeometry.coverage) it touched
public struct EraserSweep {
    /// a press that drags less than this is a click: it marks only the
    /// front-most Annotation under the eraser
    public static let clickSlop: CGFloat = 2
    private let radius: CGFloat
    private let press: CGPoint
    private var last: CGPoint
    private var moved = false
    /// the click target — the front-most candidate the press circle touched
    private var click: Annotation.ID?
    private var touched = Set<Annotation.ID>()
    /// candidates not yet touched, in stack order; the path and its paint
    /// bounds are precomputed once so a drag only pays for new intersections
    private var rest: [(id: Annotation.ID, coverage: CGPath, box: CGRect)] = []

    public init(stack: LayerStack, at point: CGPoint, radius: CGFloat) {
        self.radius = radius
        press = point
        last = point
        let ring = CGPath(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                            width: 2 * radius, height: 2 * radius),
                          transform: nil)
        for a in stack.annotations where !a.hidden && !a.locked {
            let coverage = PathGeometry.coverage(for: a)
            let box = coverage.boundingBoxOfPath
            if !coverage.isEmpty, box.intersects(ring.boundingBox),
               coverage.intersects(ring, using: .winding) {
                // stack order — the last touched candidate is the front-most
                touched.insert(a.id)
                click = a.id
            } else {
                rest.append((a.id, coverage, box))
            }
        }
    }

    /// one pointer sample: the circle sweeps the segment from the last point,
    /// so a fast drag with sparse samples still catches everything between
    public mutating func drag(to point: CGPoint) {
        defer { last = point }
        if !moved, hypot(point.x - press.x, point.y - press.y) >= Self.clickSlop { moved = true }
        guard point != last else { return }
        let seg = CGMutablePath()
        seg.move(to: last)
        seg.addLine(to: point)
        let swept = seg.copy(strokingWithWidth: 2 * radius,
                             lineCap: .round, lineJoin: .round, miterLimit: 10)
        let box = swept.boundingBoxOfPath
        rest.removeAll { c in
            guard c.box.intersects(box), c.coverage.intersects(swept, using: .winding) else {
                return false
            }
            touched.insert(c.id)
            return true
        }
    }

    /// what release removes: until the pointer moves `clickSlop` from the press,
    /// only the front-most Annotation under the eraser (a click); after, every
    /// Annotation the swept path touched
    public var marked: Set<Annotation.ID> {
        moved ? touched : click.map { [$0] } ?? []
    }
}

extension LayerStack {
    /// removes the Annotations as one change; counters renumber as with
    /// remove(id:) — sequential, so renumbering walks the stack that survives
    /// each removal, not the one the batch started from
    public mutating func erase(_ ids: Set<Annotation.ID>) {
        for id in ids { remove(id: id) }
    }
}
