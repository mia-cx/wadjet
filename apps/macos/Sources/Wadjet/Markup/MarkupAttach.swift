import AppKit
import WadjetKit

/// Attaching to another Annotation: a point dragged with Direct Select (a
/// Line's end or bend, a path's end or node), or a whole Annotation moved
/// with ⇧⌘ held. While it drags, the Annotation under it shows its attach
/// spots and it snaps to the nearest; the drop attaches it there exactly. An
/// end dropped inside an Annotation, away from its spots, attaches loosely:
/// the whole outline glows. Control stops attaching, ⌘ stops snapping
/// (DragModifiers).
extension DragModifiers {
    init(_ f: NSEvent.ModifierFlags) {
        self.init(shift: f.contains(.shift), command: f.contains(.command), control: f.contains(.control))
    }

    /// the keys held now
    static var held: DragModifiers { DragModifiers(NSEvent.modifierFlags) }
}

extension MarkupController {
    /// how near, in on-screen points, a dragged end snaps to an attach spot or outline
    static let attachRadius: CGFloat = 8

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
        // rebasing: a whole attachment must not undo part of the snap
        if snapped != moved { mutateUnrecorded { $0.replaceRebasing(snapped) } }
        // the hover can change while the geometry doesn't: draw it either way
        render()
    }

    /// `moved`, the grip drag's result, with the dragged end snapped onto the
    /// attach spot it's over, and what it's over — nil for grips that don't
    /// attach, under Control, and while Shift holds the end on its 45° ray
    /// (a spot would pull it off it). An end over the inside of an Annotation,
    /// away from its spots, stays where it is and attaches loosely; with ⌘
    /// held nothing snaps, so that's the only way it attaches.
    func attaching(_ moved: Annotation, point: AttachPoint?, constrained: Bool) -> (Annotation, AttachHover?) {
        let mods = DragModifiers.held
        guard mods.attachesPoints, !constrained, let point,
              let at = moved.position(of: point),
              let hover = AttachFinder.hover(at: at, in: stack, attaching: moved.id, point,
                                             radius: Self.attachRadius / zoom, snapping: mods.snaps)
        else { return (moved, nil) }
        if let spot = hover.snapped { return (moved.moving(point, to: spot.at), hover) }
        // over a target that won't take this point unsnapped: no highlight, no attach
        return (moved, hover.loose ? hover : nil)
    }

    /// a whole Annotation being moved with ⇧⌘ held: when the pointer comes
    /// within reach of another Annotation's spot or edge, `unsnapped` shifts
    /// so the pointer sits exactly on it, and the drop attaches it there at
    /// its offset. Only a snapped spot counts, and only under the chord, so
    /// ordinary moves stay ordinary.
    func attachingWhole(_ moved: Annotation, unsnapped: Annotation, pointer p: CGPoint) -> (Annotation, AttachHover?) {
        guard DragModifiers.held.attachesWhole,
              let hover = AttachFinder.hover(at: p, in: stack, attaching: moved.id, .whole,
                                             radius: Self.attachRadius / zoom),
              let spot = hover.snapped else { return (moved, nil) }
        return (unsnapped.moved(by: CGVector(dx: spot.at.x - p.x, dy: spot.at.y - p.y)), hover)
    }

    /// the drop: a dragged point over a spot attaches there exactly, one
    /// inside a target loosely; a moved Annotation over a spot attaches
    /// whole. The keys held at the drop decide, as they decided the hover.
    func dropAttaching() {
        defer { attachHover = nil }
        guard let hover = attachHover else { return }
        let mods = DragModifiers.held
        if let (id, point) = draggedAttachPoint, mods.attachesPoints {
            if let spot = hover.snapped {
                mutateUnrecorded { $0.attach(id, point, to: spot.target, at: spot.spot) }
                AppLog.line("markup: attached \(point)")
            } else if hover.loose {
                mutateUnrecorded { $0.attach(id, point, to: hover.target.id, at: .frame(.zero), loose: true) }
                AppLog.line("markup: attached \(point) loosely")
            }
        }
        if case let .moving(start, _) = gesture, mods.attachesWhole, let spot = hover.snapped {
            mutateUnrecorded { $0.attach(start.id, .whole, to: spot.target, at: spot.spot) }
            AppLog.line("markup: attached a whole Annotation")
        }
    }
}

extension MarkupView {
    /// the attach target in malachite: for an exact attach its outline and
    /// spots, the snapped spot filled; for a loose one the whole outline
    /// glowing. nil clears them. Sizes stay constant on screen at any zoom.
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
        let z = controller.zoom, p = CGMutablePath(), outline = AttachFinder.outline(of: hover.target)
        p.addPath(outline)
        if hover.loose {
            // the drop attaches anywhere on it: the outline glows, no spot stands out
            let glow = CAShapeLayer()
            glow.path = outline
            glow.fillColor = accent.copy(alpha: 0.12)
            glow.strokeColor = accent.copy(alpha: 0.4)
            glow.lineWidth = 6 / z
            glow.lineJoin = .round
            glow.contentsScale = scale
            l.addSublayer(glow)
            l.path = p
            l.fillColor = nil
            l.strokeColor = accent
            l.lineWidth = 2 / z
            l.contentsScale = scale
            return
        }
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
