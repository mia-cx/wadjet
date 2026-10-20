import AppKit
import WadjetKit

/// Attaching a point dragged with Direct Select — a Line's end or bend, a
/// path's end or node — to another Annotation: while it drags, the
/// Annotation under it shows its attach spots and the point snaps to the
/// nearest; the drop attaches it. Control suppresses attaching, as it
/// suppresses snapping, and so does ⌘ while Select or Direct Select is the
/// armed Tool — with any other Tool armed, ⌘ is what turns it into Select.
extension MarkupController {
    /// how near, in on-screen points, a dragged end snaps to an attach spot or outline
    static let attachRadius: CGFloat = 8

    /// a held or released modifier changes what a drag in flight does
    /// (Control and ⌘ suppress attaching, ⇧ constrains), so the drag re-runs
    /// at the same pointer — true for the drags that attach
    var attachDragInFlight: Bool { attachHover != nil || draggingAttachable }

    /// whether the keys held now keep a dragged end from attaching
    var attachSuppressed: Bool {
        let f = NSEvent.modifierFlags
        return f.contains(.control) || (f.contains(.command) && (armed == .select || armed == .directSelect))
    }

    /// the one attachable point a Direct Select drag carries, if it carries
    /// exactly one: several anchors moving together attach nothing
    var draggedAttachPoint: (id: Annotation.ID, point: AttachPoint)? {
        switch gesture {
        case let .anchors(starts, _):
            guard starts.count == 1, let (id, m) = starts.first, m.indices.count == 1, let i = m.indices.first,
                  let point = m.start.attachPoint(forAnchor: i) else { return nil }
            return (id, point)
        case let .handle(h, start, _):
            return start.attachPoint(for: h).map { (start.id, $0) }
        default:
            return nil
        }
    }

    /// after an anchor drag's step: the one dragged point snaps onto the
    /// attach spot it's over
    func attachAnchorDrag(constrained: Bool) {
        guard let (id, point) = draggedAttachPoint, let moved = stack.annotations.first(where: { $0.id == id })
        else { attachHover = nil; render(); return }
        let (snapped, hover) = attaching(moved, point: point, constrained: constrained)
        attachHover = hover
        if snapped != moved { mutateUnrecorded { $0.replace(snapped) } }
        // the hover can change while the geometry doesn't: draw it either way
        render()
    }

    /// `moved`, the grip drag's result, with the dragged end snapped onto the
    /// attach spot it's over, and what it's over — nil for grips that don't
    /// attach, while attaching is suppressed, and while Shift holds the end
    /// on its 45° ray — a spot would pull it off
    func attaching(_ moved: Annotation, point: AttachPoint?, constrained: Bool) -> (Annotation, AttachHover?) {
        guard !attachSuppressed, !constrained, let point,
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
            layer?.insertSublayer(l, above: guidesLayer)
        }
        // an Editor's recrop moves the Canvas region; follow the guides' space
        l.bounds = guidesLayer.bounds
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
