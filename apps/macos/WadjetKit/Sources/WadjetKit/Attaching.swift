import CoreGraphics
import Foundation

/// Attaching on the layer stack: what may attach where, attaching and
/// detaching, moving a set of Annotations together, and the re-solve that
/// keeps every attached point and Annotation on its anchor after any change.
extension LayerStack {
    /// closer than this, in points, a followed point already sits on its
    /// anchor — re-solving it again changes nothing, so a no-op edit records
    /// no undo step
    static let attachTolerance: CGFloat = 1e-6

    /// the Annotations that follow `id`, directly or through others
    public func followers(of id: Annotation.ID) -> Set<Annotation.ID> {
        var out = Set<Annotation.ID>(), queue = [id]
        while let t = queue.popLast() {
            for a in annotations where a.attachments.contains(where: { $0.target == t }) {
                if out.insert(a.id).inserted { queue.append(a.id) }
            }
        }
        out.remove(id)
        return out
    }

    /// whether `point` of `source` may attach to `target`: both exist and
    /// differ, the source has that point, and the target doesn't already
    /// follow the source — A following B following A would never settle
    public func canAttach(_ source: Annotation.ID, _ point: AttachPoint, to target: Annotation.ID) -> Bool {
        guard source != target,
              let s = annotations.first(where: { $0.id == source }), s.canAttach(point),
              annotations.contains(where: { $0.id == target }) else { return false }
        return !followers(of: source).contains(target)
    }

    /// attaches `point` of `source` to `anchor` on `target`, replacing what
    /// that point was attached to; the point moves onto the anchor at once.
    /// A whole Annotation keeps its current offset and turn from the anchor,
    /// and drops its point attachments — and a point attachment drops a whole
    /// one. False, changing nothing, when `canAttach` refuses.
    @discardableResult
    public mutating func attach(_ source: Annotation.ID, _ point: AttachPoint, to target: Annotation.ID,
                                at anchor: AttachAnchor) -> Bool {
        guard canAttach(source, point, to: target),
              let i = annotations.firstIndex(where: { $0.id == source }),
              let t = annotations.first(where: { $0.id == target }),
              let p = t.position(of: anchor) else { return false }
        var a = annotations[i]
        var new = Attachment(point: point, target: target, anchor: anchor)
        if point == .whole {
            let b = a.kind.bounds, th = t.attachRotation
            let v = CGVector(dx: b.midX - p.x, dy: b.midY - p.y)
            // the offset in the target's unrotated frame, so it turns with it
            new.offset = CGVector(dx: v.dx * cos(th) + v.dy * sin(th), dy: -v.dx * sin(th) + v.dy * cos(th))
            new.turn = a.attachRotation - th
            a.attachments = [new]
        } else {
            a.attachments.removeAll { $0.point == point || $0.point == .whole }
            a.attachments.append(new)
        }
        annotations[i] = a
        return true
    }

    /// frees `point` of `source` where it is now — every point and a whole
    /// attachment when `point` is nil
    public mutating func detach(_ source: Annotation.ID, _ point: AttachPoint? = nil) {
        guard let i = annotations.firstIndex(where: { $0.id == source }) else { return }
        annotations[i].attachments.removeAll { point == nil || $0.point == point }
    }

    /// moves `ids` by `d` together — a multi-selection's drag. What follows
    /// them moves along once, by re-solving rather than by `d` again, so an
    /// arrow moved with its target lands exactly where the target takes its
    /// ends. A moved Annotation lets go of anything that doesn't move with it:
    /// dragging it away detaches it.
    public mutating func translate(_ ids: Set<Annotation.ID>, by d: CGVector) {
        // whatever moves rigidly: the ids, and whole Annotations attached to them
        var rigid = ids, grew = true
        while grew {
            grew = false
            for a in annotations where !rigid.contains(a.id)
                && a.attachments.contains(where: { $0.point == .whole && rigid.contains($0.target) }) {
                rigid.insert(a.id); grew = true
            }
        }
        var list = annotations
        for i in list.indices where ids.contains(list[i].id) {
            list[i] = list[i].moved(by: d)
            list[i].attachments.removeAll { !rigid.contains($0.target) }
        }
        annotations = list
    }

    /// `list` with every attachment re-solved, targets before what follows
    /// them; attachments whose target is gone, whose point is gone, or that
    /// close a cycle (only a hand-edited file can hold one) are dropped. nil
    /// when nothing changes.
    static func resolvingAttachments(_ list: [Annotation]) -> [Annotation]? {
        guard list.contains(where: { !$0.attachments.isEmpty }) else { return nil }
        var out = list, changed = false
        let index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // nil unvisited, false on the path being resolved, true resolved
        var done = [Int: Bool]()
        func resolve(_ i: Int) {
            guard done[i] == nil else { return }
            done[i] = false
            var kept: [Attachment] = []
            for at in out[i].attachments {
                guard let j = index[at.target], j != i, done[j] != false, out[i].canAttach(at.point) else {
                    changed = true
                    continue
                }
                resolve(j)
                kept.append(at)
            }
            if kept != out[i].attachments { out[i].attachments = kept }
            for at in kept {
                guard let j = index[at.target], let r = out[i].following(at, on: out[j]) else { continue }
                out[i] = r
                changed = true
            }
            done[i] = true
        }
        for i in out.indices { resolve(i) }
        return changed ? out : nil
    }
}

extension Annotation {
    /// a copy put back on `at`'s anchor on `target`, or nil when it already sits there
    func following(_ at: Attachment, on target: Annotation) -> Annotation? {
        guard let p = target.position(of: at.anchor) else { return nil }
        let tolerance = LayerStack.attachTolerance
        guard at.point == .whole else {
            guard let now = position(of: at.point), hypot(p.x - now.x, p.y - now.y) > tolerance else { return nil }
            return placing(at.point, at: p)
        }
        let th = target.attachRotation
        let centre = CGPoint(x: p.x + at.offset.dx * cos(th) - at.offset.dy * sin(th),
                             y: p.y + at.offset.dx * sin(th) + at.offset.dy * cos(th))
        var a = self, moved = false
        if kind.transforms {
            let r = (th + at.turn).remainder(dividingBy: 2 * .pi)
            if abs((r - transform.rotation).remainder(dividingBy: 2 * .pi)) > tolerance {
                a.transform.rotation = r
                moved = true
            }
        }
        // the bounds centre is the transform's pivot, so it is the centre on screen too
        let b = kind.bounds
        if hypot(centre.x - b.midX, centre.y - b.midY) > tolerance {
            a = a.moved(by: CGVector(dx: centre.x - b.midX, dy: centre.y - b.midY))
            moved = true
        }
        return moved ? a : nil
    }
}
