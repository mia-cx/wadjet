import AppKit
import WadjetKit

/// Direct Select, after Illustrator's Direct Selection (and Affinity's Node
/// tool where it does better): presses edit a Line's ends, a path's nodes and
/// handles, and a Shape's vertices and corner radius. The anchor state is
/// `nodes`; the geometry lives in WadjetKit's DirectSelect.swift. Kinds
/// without anchors (Text, Censor, images…) select and move as under Select.
extension MarkupController {
    /// what Direct Select draws and takes presses on
    var directChrome: DirectSelectChrome {
        DirectSelectChrome(stack.annotations, selection: nodes, inset: Self.handleMinExtent / zoom)
    }

    /// arming Direct Select (or picking a layer under it) shows the selected
    /// path's anchors, none selected
    func showSelectionAnchors() {
        guard directSelecting, let sel = selected, sel.kind.hasAnchors, !nodes.shown.contains(sel.id) else { return }
        nodes.show(sel.id, adding: false)
    }

    /// the marquee in flight, for the views to draw
    var marqueeRect: CGRect? {
        guard case let .marquee(from, to, _) = gesture else { return nil }
        return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                      width: abs(to.x - from.x), height: abs(to.y - from.y))
    }

    /// a press with Direct Select: a shown anchor or grip, else an anchor or
    /// segment of what's under the pointer, else its body; empty space starts
    /// a marquee. `adding` is Shift.
    func beginDirect(at p: CGPoint, adding: Bool) {
        let radius = Self.handleHitRadius / zoom, tol = Self.hitTolerance / zoom
        switch directChrome.hit(at: p, radius: radius) {
        case let .anchor(ref)?:
            pressAnchor(ref, at: p, adding: adding)
            return
        case let .grip(id, h)?:
            guard let a = stack.annotations.first(where: { $0.id == id }) else { return }
            setSelection([id])
            gesture = .handle(h, a, from: p)
            return
        case nil:
            break
        }
        // a selected kind without anchors keeps Select's grips
        if let sel = selected, !sel.kind.hasAnchors, grabSelection(at: p) { return }
        guard let hit = stack.topmost(at: p, tolerance: tol) else {
            // empty space: a marquee, which keeps the selection only with Shift
            if !adding { nodes.clear(); setSelection([]) }
            gesture = .marquee(from: p, to: p, adding: adding)
            return
        }
        guard hit.kind.hasAnchors else {
            nodes.clear()
            setSelection([hit.id])
            gesture = Self.moveGesture(hit, at: p)
            return
        }
        // an anchor of what's under the pointer, shown or not
        if let i = hit.anchors.indices.min(by: { hypot(hit.anchors[$0].x - p.x, hit.anchors[$0].y - p.y)
                                               < hypot(hit.anchors[$1].x - p.x, hit.anchors[$1].y - p.y) }),
           hypot(hit.anchors[i].x - p.x, hit.anchors[i].y - p.y) <= radius {
            pressAnchor(AnchorRef(id: hit.id, index: i), at: p, adding: adding)
            return
        }
        nodes.show(hit.id, adding: adding)
        setSelection(adding ? selection.adding([hit.id]) : [hit.id])
        // a segment drags its two anchors; anywhere else in the body, the whole
        if let seg = hit.segment(at: p, tolerance: tol) {
            gesture = .anchors([hit.id: (hit, seg.anchors)], from: p)
        } else {
            gesture = Self.moveGesture(hit, at: p)
        }
        render()
    }

    /// Illustrator's anchor press, then a drag that carries every selected anchor
    private func pressAnchor(_ ref: AnchorRef, at p: CGPoint, adding: Bool) {
        nodes.press(ref, adding: adding)
        setSelection(adding ? selection.adding([ref.id]) : [ref.id])
        if nodes.anchors.contains(ref) {
            var starts: [Annotation.ID: (start: Annotation, indices: Set<Int>)] = [:]
            for a in stack.annotations where nodes.shown.contains(a.id) {
                let idx = nodes.indices(of: a.id)
                if !idx.isEmpty { starts[a.id] = (a, idx) }
            }
            gesture = .anchors(starts, from: p)
        }
        render()
    }

    /// moves the gesture's anchors from their start states — no drift; Shift
    /// keeps the move on a 45° ray
    func dragAnchors(_ starts: [Annotation.ID: (start: Annotation, indices: Set<Int>)],
                     from: CGPoint, to p: CGPoint, constrained: Bool) {
        let q = constrained ? PathGeometry.snapAngle(p, from: from) : p
        let d = CGVector(dx: q.x - from.x, dy: q.y - from.y)
        mutateUnrecorded { s in
            for (_, m) in starts { s.replace(m.start.movingAnchors(m.indices, by: d)) }
        }
    }

    /// the marquee's release: its anchors join the selection
    func endMarquee(from: CGPoint, to: CGPoint, adding: Bool) {
        let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
        nodes.marquee(rect, in: stack.annotations, adding: adding)
        setSelection(nodes.shown.last)
        commitGesture()
        render()
        AppLog.line("markup: marquee selected \(nodes.anchors.count) anchors")
    }

    /// Delete with anchors selected: they go, their neighbours join, and an
    /// Annotation left too short goes too — one undo step. False when no
    /// anchor was selected.
    func deleteAnchors() -> Bool {
        guard directSelecting, !nodes.anchors.isEmpty else { return false }
        let picked = nodes
        edit { s in
            for a in s.annotations where !picked.indices(of: a.id).isEmpty {
                if let kept = a.removingAnchors(picked.indices(of: a.id)) { s.replace(kept) }
                else { s.remove(id: a.id) }
            }
        }
        nodes.prune(to: stack.annotations)
        // the anchor indices shifted: nothing stays selected, the paths stay shown
        nodes.deselectAnchors()
        let kept = selection.pruned(to: stack.annotations)
        setSelection(kept.isEmpty ? AnnotationSelection(nodes.shown.last.map { [$0] } ?? []) : kept)
        render()
        AppLog.line("markup: deleted anchors")
        return true
    }

    /// an arrow key with anchors selected nudges them by `d` (1 pt, 10 with
    /// Shift) — each press one undo step. False when there's nothing to nudge.
    func nudgeAnchors(by d: CGVector) -> Bool {
        guard directSelecting, gesture == nil, !nodes.anchors.isEmpty else { return false }
        let picked = nodes
        edit { s in
            for a in s.annotations where !picked.indices(of: a.id).isEmpty {
                s.replace(a.movingAnchors(picked.indices(of: a.id), by: d))
            }
        }
        return true
    }

    /// the arrow key's nudge, or nil for any other key
    static func nudge(for e: NSEvent) -> CGVector? {
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch e.keyCode {
        case 123: return CGVector(dx: -step, dy: 0)
        case 124: return CGVector(dx: step, dy: 0)
        case 125: return CGVector(dx: 0, dy: -step)
        case 126: return CGVector(dx: 0, dy: step)
        default: return nil
        }
    }
}
