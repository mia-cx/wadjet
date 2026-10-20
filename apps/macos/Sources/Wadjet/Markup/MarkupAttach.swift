import AppKit
import WadjetKit

/// Attaching a dragged Line or Pen end to another Annotation: while the grip
/// drags, the Annotation under it shows its attach spots and the end snaps to
/// the nearest; the drop attaches it. Control suppresses attaching, as it
/// suppresses snapping, and so does ⌘ while Select is the armed Tool —
/// with any other Tool armed, ⌘ is what turns it into Select for the drag.
extension MarkupController {
    /// how near, in on-screen points, a dragged end snaps to an attach spot or outline
    static let attachRadius: CGFloat = 8

    /// whether the keys held now keep a dragged end from attaching
    var attachSuppressed: Bool {
        let f = NSEvent.modifierFlags
        return f.contains(.control) || (f.contains(.command) && armed == .select)
    }

    /// `moved`, the grip drag's result, with the dragged end snapped onto the
    /// attach spot it's over, and what it's over — nil for grips that don't
    /// attach, and while attaching is suppressed
    func attaching(_ moved: Annotation, grip h: SelectionHandle) -> (Annotation, AttachHover?) {
        guard !attachSuppressed, let point = moved.attachPoint(for: h),
              let at = moved.position(of: point),
              let hover = AttachFinder.hover(at: at, in: stack, attaching: moved.id, point,
                                             radius: Self.attachRadius / zoom) else { return (moved, nil) }
        guard let spot = hover.snapped else { return (moved, hover) }
        return (moved.moving(point, to: spot.at), hover)
    }
}

extension MarkupView {
    /// the attach target's outline and spots in malachite, the snapped spot
    /// filled; nil clears them. Sizes stay constant on screen at any zoom.
    func showAttach(_ hover: AttachHover?) {
        let l: CAShapeLayer
        if let existing = layer?.sublayers?.first(where: { $0.name == "attach" }) as? CAShapeLayer {
            l = existing
        } else {
            l = CAShapeLayer()
            l.name = "attach"
            l.anchorPoint = .zero
            l.position = .zero
            l.bounds = guidesLayer.bounds
            layer?.insertSublayer(l, above: guidesLayer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        l.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let hover else { l.path = nil; return }
        let z = controller.zoom, p = CGMutablePath()
        p.addPath(AttachFinder.outline(of: hover.target))
        for s in hover.spots {
            p.addEllipse(in: CGRect(x: s.at.x - 3 / z, y: s.at.y - 3 / z, width: 6 / z, height: 6 / z))
        }
        l.path = p
        l.fillColor = nil
        l.strokeColor = accent
        l.lineWidth = 1.5 / z
        l.contentsScale = scale
        // the spot the drop attaches to: a filled ring around the end
        if let s = hover.snapped {
            let dot = CAShapeLayer()
            dot.path = CGPath(ellipseIn: CGRect(x: s.at.x - 5 / z, y: s.at.y - 5 / z, width: 10 / z, height: 10 / z),
                              transform: nil)
            dot.fillColor = accent.copy(alpha: 0.5)
            dot.strokeColor = accent
            dot.lineWidth = 1.5 / z
            dot.contentsScale = scale
            l.addSublayer(dot)
        }
    }
}
