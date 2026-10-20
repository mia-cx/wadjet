import CoreGraphics
import Foundation

/// One anchor Direct Select edits: an Annotation's point by index — a Line's
/// end, a path's node, or a Shape's outline vertex.
public struct AnchorRef: Hashable, Sendable {
    public let id: Annotation.ID
    public let index: Int
    public init(id: Annotation.ID, index: Int) {
        self.id = id
        self.index = index
    }
}

/// Direct Select's state, after Illustrator's Direct Selection: the
/// Annotations whose anchors show, and the anchors selected among them.
public struct NodeSelection: Equatable, Sendable {
    /// whose anchors show, in the order they were touched
    public private(set) var shown: [Annotation.ID] = []
    public private(set) var anchors: Set<AnchorRef> = []
    public init() {}

    public var isEmpty: Bool { shown.isEmpty }
    /// the selected anchors' indices on one Annotation
    public func indices(of id: Annotation.ID) -> Set<Int> {
        Set(anchors.filter { $0.id == id }.map(\.index))
    }

    /// a press on an anchor. Shift (`adding`) toggles it and keeps the rest;
    /// a plain press selects it alone, unless it is already selected, so a
    /// drag can carry every selected anchor
    public mutating func press(_ ref: AnchorRef, adding: Bool) {
        if adding {
            if anchors.contains(ref) { anchors.remove(ref) } else { anchors.insert(ref) }
            show(ref.id)
        } else if !anchors.contains(ref) {
            anchors = [ref]
            if !shown.contains(ref.id) { shown = [ref.id] }
        }
    }

    /// a press on an Annotation's stroke or body: its anchors show, none
    /// selected. Shift keeps what was shown and selected.
    public mutating func show(_ id: Annotation.ID, adding: Bool) {
        if adding { show(id); return }
        shown = [id]
        anchors = []
    }

    private mutating func show(_ id: Annotation.ID) {
        if !shown.contains(id) { shown.append(id) }
    }

    /// a marquee drag: every anchor inside `rect` on `annotations` (visible,
    /// unlocked, with anchors) is selected, across Annotations. Shift adds
    /// them to the selection.
    public mutating func marquee(_ rect: CGRect, in annotations: [Annotation], adding: Bool) {
        if !adding { shown = []; anchors = [] }
        for a in annotations where !a.hidden && !a.locked {
            let inside = a.anchors.indices.filter { rect.contains(a.anchors[$0]) }
            guard !inside.isEmpty else { continue }
            show(a.id)
            for i in inside { anchors.insert(AnchorRef(id: a.id, index: i)) }
        }
    }

    public mutating func clear() { shown = []; anchors = [] }
    /// keeps what's shown, selects no anchor
    public mutating func deselectAnchors() { anchors = [] }

    /// drops what `annotations` no longer holds — after an undo, a delete, a
    /// node removed — so no ref points past an Annotation's anchors
    public mutating func prune(to annotations: [Annotation]) {
        let byID = Dictionary(annotations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        shown = shown.filter { byID[$0].map { !$0.hidden && !$0.locked && $0.kind.hasAnchors } ?? false }
        anchors = anchors.filter { r in
            shown.contains(r.id) && byID[r.id].map { r.index < $0.anchors.count } == true
        }
    }
}

extension AnnotationKind {
    /// whether Direct Select edits this kind's points: Lines, paths, Shapes.
    /// Every other kind moves and resizes as a whole, as under Select.
    public var hasAnchors: Bool {
        switch self {
        case .line, .path, .shape: true
        default: false
        }
    }
}

extension Annotation {
    /// Direct Select's anchors on screen: a Line's two ends, a path's nodes,
    /// a Shape's outline vertices; empty for other kinds
    public var anchors: [CGPoint] {
        let m = affineTransform
        switch kind {
        case let .line(start, end, _): return [start.applying(m), end.applying(m)]
        case let .path(d): return d.nodes.map { $0.anchor.applying(m) }
        case let .shape(k, rect): return PathData(outline: k.path(in: rect)).nodes.map { $0.anchor.applying(m) }
        default: return []
        }
    }

    /// a Shape as the closed path of its outline, kept where it was on
    /// screen — dragging a Shape's anchor or handle reshapes it into a path,
    /// like Illustrator expanding a live shape. Other kinds return self.
    public var outlinePath: Annotation {
        guard case let .shape(k, rect) = kind else { return self }
        var a = self
        let data = PathData(outline: k.path(in: rect))
        a.kind = .path(data)
        // a polygon's outline doesn't fill its rect, so the transform's pivot
        // (the bounds centre) moves — pin the first vertex on screen
        guard let pin = data.nodes.first?.anchor else { return a }
        let was = pin.applying(affineTransform), now = pin.applying(a.affineTransform)
        return a.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y))
    }

    /// the anchors at `indices` moved by `d` on screen, their handles riding
    /// along. Moving both of a Line's ends moves the Line; one end keeps the
    /// bend's place on the chord. A Shape becomes its outline path first,
    /// unless nothing moves.
    public func movingAnchors(_ indices: Set<Int>, by d: CGVector) -> Annotation {
        guard !indices.isEmpty, d.dx != 0 || d.dy != 0 else { return self }
        switch kind {
        case .line:
            if indices.isSuperset(of: [0, 1]) { return moved(by: d) }
            guard let i = indices.first else { return self }
            return dragging(.vertex(i), from: .zero, to: CGPoint(x: d.dx, y: d.dy))
        case .shape:
            return outlinePath.movingAnchors(indices, by: d)
        case .path:
            var a = baked
            guard case var .path(data) = a.kind else { return self }
            func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
            for i in indices where data.nodes.indices.contains(i) {
                data.nodes[i].anchor = shift(data.nodes[i].anchor)
                data.nodes[i].handleIn = data.nodes[i].handleIn.map(shift)
                data.nodes[i].handleOut = data.nodes[i].handleOut.map(shift)
            }
            // a hand-moved node no longer matches the Brush samples a refit reads
            data.rawPoints = nil
            data.smoothing = nil
            a.kind = .path(data)
            return a
        default:
            return self
        }
    }

    /// the anchors at `indices` removed, their neighbours joined across the
    /// gap (Affinity's delete, which keeps the path whole). nil when too few
    /// anchors remain to draw: a Line loses either end, a path keeps under
    /// two. A Shape becomes its outline path first.
    public func removingAnchors(_ indices: Set<Int>) -> Annotation? {
        guard !indices.isEmpty else { return self }
        switch kind {
        case .line:
            return nil
        case .shape:
            return outlinePath.removingAnchors(indices)
        case let .path(d):
            var data = d
            data.nodes = d.nodes.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
            guard data.nodes.count >= 2 else { return nil }
            // two nodes enclose an area only through a curve
            if data.nodes.count < 3, AnnotationKind.path(data).segments.allSatisfy(\.straight) { data.closed = false }
            data.rawPoints = nil
            data.smoothing = nil
            var a = self
            a.kind = .path(data)
            // pin a kept node: the bounds, and so the pivot, may have moved
            let keep = data.nodes[0].anchor
            let was = keep.applying(affineTransform), now = keep.applying(a.affineTransform)
            return a.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y))
        default:
            return self
        }
    }

    /// the stroke segment nearest `p` (screen), if within `tolerance` of the
    /// stroke's edge, and the anchors it joins
    public func segment(at p: CGPoint, tolerance: CGFloat) -> (index: Int, anchors: Set<Int>)? {
        let data: PathData
        switch kind {
        case let .line(start, end, _):
            data = PathData(nodes: [PathNode(anchor: start), PathNode(anchor: end)])
        case let .path(d): data = d
        case let .shape(k, rect): data = PathData(outline: k.path(in: rect))
        default: return nil
        }
        // a bent Line's one curved segment stands in for its two plain nodes
        let segs = kind.isLine ? kind.segments : AnnotationKind.path(data).segments
        let q = p.applying(affineTransform.inverted())
        guard data.nodes.count >= 2, let (i, t) = Self.nearest(on: segs, to: q) else { return nil }
        let s = segs[i]
        let on = s.straight
            ? CGPoint(x: s.p0.x + (s.p3.x - s.p0.x) * t, y: s.p0.y + (s.p3.y - s.p0.y) * t)
            : s.point(at: t)
        // measured on screen: the transform is a similarity, so distances keep
        let sp = on.applying(affineTransform)
        guard hypot(sp.x - p.x, sp.y - p.y) <= tolerance + style.width / 2 else { return nil }
        return (i, [i, (i + 1) % data.nodes.count])
    }

    /// where a rounded-rectangle's corner widget sits on screen: the top-left
    /// corner's arc centre, at least `inset` in from the corner so it never
    /// sits on the anchor; nil for other kinds
    public func cornerWidget(inset: CGFloat) -> CGPoint? {
        guard case let .shape(.rectangle(r), rect) = kind else { return nil }
        let o = max(min(max(0, r), min(rect.width, rect.height) / 2), inset)
        guard o <= min(rect.width, rect.height) / 2 else { return nil } // too small to hold it
        return CGPoint(x: rect.minX + o, y: rect.maxY - o).applying(affineTransform)
    }
}

extension AnnotationKind {
    var isLine: Bool {
        if case .line = self { return true }
        return false
    }
}

/// What Direct Select draws and takes presses on, from the Annotations whose
/// anchors show: hollow anchors, filled once selected; bezier handles only
/// on selected anchors and their neighbours (Illustrator's rule); a Line's
/// bend grip; a rectangle's corner-radius widget.
public struct DirectSelectChrome: Sendable {
    public struct Anchor: Sendable {
        public let ref: AnchorRef
        public let at: CGPoint
        public let selected: Bool
    }
    /// a grip that isn't an anchor; `stem` is the anchor a bezier handle hangs from
    public struct Grip: Sendable {
        public let id: Annotation.ID
        public let handle: SelectionHandle
        public let at: CGPoint
        public let stem: CGPoint?
    }
    public enum Hit: Equatable, Sendable {
        case anchor(AnchorRef)
        case grip(Annotation.ID, SelectionHandle)
    }

    public let anchors: [Anchor]
    public let grips: [Grip]

    /// `inset` keeps the corner widget clear of its corner anchor, in screen points
    public init(_ annotations: [Annotation], selection: NodeSelection, inset: CGFloat) {
        var anchors: [Anchor] = [], grips: [Grip] = []
        for id in selection.shown {
            guard let a = annotations.first(where: { $0.id == id }) else { continue }
            let picked = selection.indices(of: id)
            for (i, p) in a.anchors.enumerated() {
                anchors.append(Anchor(ref: AnchorRef(id: id, index: i), at: p, selected: picked.contains(i)))
            }
            let m = a.affineTransform
            switch a.kind {
            case let .line(s, e, b):
                let mid = b ?? CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                grips.append(Grip(id: id, handle: .bend, at: mid.applying(m), stem: nil))
            case .path, .shape:
                let data: PathData
                if case let .path(d) = a.kind { data = d }
                else if case let .shape(k, r) = a.kind { data = PathData(outline: k.path(in: r)) }
                else { continue }
                let n = data.nodes.count
                var near = Set<Int>()
                for i in picked {
                    near.insert(i)
                    if i > 0 || data.closed { near.insert((i - 1 + n) % n) }
                    if i < n - 1 || data.closed { near.insert((i + 1) % n) }
                }
                for i in near.sorted() where i < n {
                    let node = data.nodes[i], anchor = node.anchor.applying(m)
                    if let h = node.handleIn, h != node.anchor {
                        grips.append(Grip(id: id, handle: .tangent(i, outgoing: false), at: h.applying(m), stem: anchor))
                    }
                    if let h = node.handleOut, h != node.anchor {
                        grips.append(Grip(id: id, handle: .tangent(i, outgoing: true), at: h.applying(m), stem: anchor))
                    }
                }
                if let w = a.cornerWidget(inset: inset) {
                    grips.append(Grip(id: id, handle: .cornerRadius, at: w, stem: nil))
                }
            default:
                break
            }
        }
        self.anchors = anchors
        self.grips = grips
    }

    /// the anchor or grip nearest `p` within `radius`; an anchor wins a tie
    /// with a grip sitting on it, so a collapsed handle never hides its node
    public func hit(at p: CGPoint, radius: CGFloat) -> Hit? {
        func d(_ q: CGPoint) -> CGFloat { hypot(q.x - p.x, q.y - p.y) }
        let a = anchors.map { (Hit.anchor($0.ref), d($0.at)) }
        let g = grips.map { (Hit.grip($0.id, $0.handle), d($0.at)) }
        return (a + g).filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }
}
