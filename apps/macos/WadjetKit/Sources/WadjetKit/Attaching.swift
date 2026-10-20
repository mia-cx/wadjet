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
        replaceGroup(annotations.filter { ids.contains($0.id) }.map { $0.moved(by: d) })
    }

    /// replaces several Annotations at once — a multi-selection's move,
    /// resize, or rotation — in one change, so what follows them re-solves
    /// once against all of them. Each lets go of whatever doesn't move with
    /// the group: carrying it away detaches it, while an arrow moved with
    /// its target stays attached and lands where the target takes its ends.
    public mutating func replaceGroup(_ members: [Annotation]) {
        let rigid = movingTogether(Set(members.map(\.id)))
        var list = annotations
        let index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in members {
            guard let i = index[m.id] else { continue }
            list[i] = m
            list[i].attachments.removeAll { !rigid.contains($0.target) }
        }
        annotations = list
    }

    /// what moves exactly as `ids` do when they move together: the ids,
    /// whole Annotations attached to them, and Lines and paths whose every
    /// point follows them, through chains
    public func movingTogether(_ ids: Set<Annotation.ID>) -> Set<Annotation.ID> {
        var rigid = ids, grew = true
        while grew {
            grew = false
            for a in annotations where !rigid.contains(a.id) && a.followsRigidly(rigid) {
                rigid.insert(a.id); grew = true
            }
        }
        return rigid
    }

    /// copies of `annotations` under new ids (`ids` maps each old id to its
    /// copy's): attachments between copies point at the copies, and ones to
    /// anything left out of the copy let go — Duplicate, ⌥-drag, and paste
    public static func copies(of annotations: [Annotation], ids: [Annotation.ID: Annotation.ID]) -> [Annotation] {
        annotations.map { a in
            var c = a
            c.id = ids[a.id] ?? a.id
            c.attachments = a.attachments.compactMap { at in
                guard let t = ids[at.target] else { return nil }
                var at = at
                at.target = t
                return at
            }
            return c
        }
    }

    /// replaces `a` after an edit that rebuilds its nodes — a Brush refit,
    /// a node added or removed — so its node and segment indices mean other
    /// places now. Every attachment that names one moves to the spot on the
    /// new geometry nearest where it held, so nothing jumps.
    public mutating func replaceReshaping(_ a: Annotation) {
        guard let old = annotations.first(where: { $0.id == a.id }) else { return }
        var list = annotations
        for i in list.indices {
            if list[i].id == a.id {
                // each node attachment moves to the new node nearest where it
                // held; when two land on one node (or on an attached end),
                // the one that moved least keeps it and the others go free
                // the stack's records, not `a`'s: a batch of refits made from
                // one snapshot must not undo each other's remaps
                let moved: [(Attachment, CGFloat)] = old.attachments.map { at in
                    guard case .node = at.point, let was = old.position(of: at.point),
                          let node = a.nearestNode(to: was), let now = a.position(of: node) else { return (at, 0) }
                    var at = at
                    at.point = node
                    return (at, hypot(now.x - was.x, now.y - was.y))
                }
                var taken = Set<AttachPoint>(), kept: [Attachment] = []
                for (at, _) in moved.enumerated().sorted(by: { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) })
                    .map(\.element) where taken.insert(at.point).inserted {
                    kept.append(at)
                }
                var new = a
                // in their original order, so a save reads the same
                new.attachments = moved.map(\.0).filter { at in kept.contains(at) }
                list[i] = new
                continue
            }
            list[i].attachments = list[i].attachments.map { at in
                guard at.target == a.id, case .segment = at.anchor, let was = old.position(of: at.anchor),
                      let anchor = a.nearestSegmentAnchor(to: was) else { return at }
                var at = at
                at.anchor = anchor
                return at
            }
        }
        annotations = list
    }

    /// replaces `a`, a copy of a Line or path with node `node` just added by
    /// splitting the segment before it at `t0` —
    /// `Annotation.insertingNodeSplit`. The split keeps the curve, so every
    /// attachment keeps its exact spot: an anchor on the split segment moves
    /// to the matching half and t, later segments and nodes shift up by one.
    public mutating func replaceInsertingNode(_ a: Annotation, at node: Int, splitAt t0: CGFloat) {
        guard let old = annotations.first(where: { $0.id == a.id }), node > 0 else { return replace(a) }
        let split = node - 1
        var list = annotations
        for i in list.indices {
            if list[i].id == a.id {
                var new = a
                new.attachments = old.attachments.map { at in
                    guard case let .node(k) = at.point, k >= node else { return at }
                    var at = at
                    at.point = .node(k + 1)
                    return at
                }
                list[i] = new
                continue
            }
            list[i].attachments = list[i].attachments.map { at in
                guard at.target == a.id, case let .segment(j, t) = at.anchor, j >= split else { return at }
                var at = at
                at.anchor = j > split ? .segment(j + 1, t: t)
                    : t < t0 ? .segment(split, t: t0 > 0 ? t / t0 : 0)
                    : .segment(node, t: t0 < 1 ? (t - t0) / (1 - t0) : 1)
                return at
            }
        }
        annotations = list
    }

    /// `list` with every attachment re-solved, targets before what follows
    /// them. One whose target is missing is skipped: the point stays free
    /// where it is, and the reference stays only until the stack is saved,
    /// so a target that is only being moved within the array (or comes back
    /// on undo) is still followed. Attachments whose point is gone, or that
    /// close a cycle (only a hand-edited file can hold one), are dropped.
    /// nil when nothing changes.
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
                guard let j = index[at.target] else { kept.append(at); continue }
                guard j != i, done[j] != false, out[i].canAttach(at.point) else {
                    changed = true
                    continue
                }
                resolve(j)
                kept.append(at)
            }
            if kept != out[i].attachments { out[i].attachments = kept }
            if let r = out[i].following(kept.compactMap { at in index[at.target].map { (at, out[$0]) } }) {
                out[i] = r
                changed = true
            }
            done[i] = true
        }
        for i in out.indices { resolve(i) }
        return changed ? out : nil
    }

    /// what gets saved and loaded: attachments whose target is gone are left out
    static func savedAnnotations(_ annotations: [Annotation]) -> [Annotation] {
        let ids = Set(annotations.map(\.id))
        return annotations.map { a in
            var a = a
            a.attachments.removeAll { !ids.contains($0.target) }
            return a
        }
    }
}

extension Annotation {
    /// whether this moves exactly as `rigid` does: attached whole to one of
    /// them, or a Line or path whose every point is attached to them
    func followsRigidly(_ rigid: Set<Annotation.ID>) -> Bool {
        guard !attachments.isEmpty, attachments.allSatisfy({ rigid.contains($0.target) }) else { return false }
        let held = Set(attachments.map(\.point))
        if held.contains(.whole) { return true }
        switch kind {
        case .line: return held.isSuperset(of: [.start, .end])
        case let .path(d):
            return d.nodes.indices.allSatisfy { i in
                held.contains(.node(i)) || (!d.closed && (i == 0 ? held.contains(.start)
                    : i == d.nodes.count - 1 && held.contains(.end)))
            }
        default: return false
        }
    }

    /// a copy put back on its attachments' anchors, each paired with its
    /// target — every point at once — or nil when it already sits there
    func following(_ attached: [(Attachment, Annotation)]) -> Annotation? {
        let tolerance = LayerStack.attachTolerance
        if let (at, target) = attached.first(where: { $0.0.point == .whole }) {
            return followingWhole(at, on: target)
        }
        let moves: [(AttachPoint, CGPoint)] = attached.compactMap { at, target in
            target.position(of: at.anchor).map { (at.point, $0) }
        }
        guard moves.contains(where: { point, p in
            position(of: point).map { hypot(p.x - $0.x, p.y - $0.y) > tolerance } ?? false
        }) else { return nil }
        return placing(moves)
    }

    /// a whole Annotation put back at its offset and turn from the anchor, or nil when it sits there
    func followingWhole(_ at: Attachment, on target: Annotation) -> Annotation? {
        guard let p = target.position(of: at.anchor) else { return nil }
        let tolerance = LayerStack.attachTolerance
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
