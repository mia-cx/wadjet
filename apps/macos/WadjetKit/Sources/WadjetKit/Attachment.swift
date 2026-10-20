import CoreGraphics
import Foundation

/// One attached point or Annotation: `point` of the Annotation that holds this
/// follows `anchor` on the Annotation `target`. Like tldraw's arrow bindings
/// and Excalidraw's bound elements, but held on the attaching side only — the
/// target knows nothing, so deleting it just leaves the reference dangling,
/// and the LayerStack drops it. ADR 0001 explains the choice.
public struct Attachment: Equatable, Sendable {
    public var point: AttachPoint
    public var target: Annotation.ID
    public var anchor: AttachAnchor
    /// `.whole` only: the attaching Annotation's centre minus the anchor, in
    /// the target's unrotated frame — it turns with the target, never scales
    public var offset: CGVector
    /// `.whole` only: the attaching Annotation's rotation minus the target's
    public var turn: CGFloat
    public init(point: AttachPoint, target: Annotation.ID, anchor: AttachAnchor,
                offset: CGVector = .zero, turn: CGFloat = 0) {
        self.point = point
        self.target = target
        self.anchor = anchor
        self.offset = offset
        self.turn = turn
    }
}

/// which part of the attaching Annotation follows. Ends are named rather than
/// numbered so they survive points added along the path.
public enum AttachPoint: Hashable, Sendable {
    /// a Line's start or an open path's first node
    case start
    /// a Line's end or an open path's last node
    case end
    /// a path node by index — the points between the ends, or any node of a closed path
    case node(Int)
    /// a Line's bend, the on-curve point at t = 0.5
    case bend
    /// the whole Annotation, kept at its offset from the anchor
    case whole
}

/// where on the target an attachment holds
public enum AttachAnchor: Equatable, Sendable {
    /// a position in the target's untransformed bounds, 0…1 on each axis from
    /// the bottom-left: (0, 0) and (1, 1) are corners, (0.5, 0) the bottom
    /// edge's midpoint. It rides the target's resize, rotation and flips, and
    /// stays on an ellipse's, polygon's or star's outline because those
    /// scale with their rect.
    case frame(CGPoint)
    /// a position along a Line's or path's segment `index` at parameter `t`
    /// (0…1) — t = 0 is the segment's first node, so a vertex is (i, 0) and
    /// an open path's end is (last, 1). It rides the path's reshaping.
    case segment(Int, t: CGFloat)
}

extension Attachment: Codable {
    enum CodingKeys: String, CodingKey { case target, start, end, node, bend, whole, frame, segment }
    enum WholeKeys: String, CodingKey { case offset, turn }
    /// `{"target":"…","end":true,"frame":[1,0.5]}`, `{"target":"…","node":2,"segment":[1,0.25]}`,
    /// `{"target":"…","whole":{"offset":[12,-4],"turn":0},"frame":[1,1]}`
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(UUID.self, forKey: .target)
        offset = .zero
        turn = 0
        if c.contains(.start) { point = .start }
        else if c.contains(.end) { point = .end }
        else if c.contains(.bend) { point = .bend }
        else if c.contains(.node) { point = .node(try c.decode(Int.self, forKey: .node)) }
        else if c.contains(.whole) {
            point = .whole
            let w = try c.nestedContainer(keyedBy: WholeKeys.self, forKey: .whole)
            let o = try w.decodePoint(forKey: .offset)
            offset = CGVector(dx: o.x, dy: o.y)
            turn = try w.decode(CGFloat.self, forKey: .turn)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                debugDescription: "an attachment names its point: start, end, node, bend, or whole"))
        }
        if c.contains(.frame) {
            anchor = .frame(try c.decodePoint(forKey: .frame))
        } else {
            let v = try c.decode([CGFloat].self, forKey: .segment)
            guard v.count == 2, let i = Int(exactly: v[0]) else {
                throw DecodingError.dataCorruptedError(forKey: .segment, in: c,
                    debugDescription: "a segment anchor is exactly [index, t]")
            }
            anchor = .segment(i, t: v[1])
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        switch point {
        case .start: try c.encode(true, forKey: .start)
        case .end: try c.encode(true, forKey: .end)
        case .bend: try c.encode(true, forKey: .bend)
        case let .node(i): try c.encode(i, forKey: .node)
        case .whole:
            var w = c.nestedContainer(keyedBy: WholeKeys.self, forKey: .whole)
            try w.encodePoint(CGPoint(x: offset.dx, y: offset.dy), forKey: .offset)
            try w.encode(turn, forKey: .turn)
        }
        switch anchor {
        case let .frame(u): try c.encodePoint(u, forKey: .frame)
        case let .segment(i, t): try c.encode([CGFloat(i), t], forKey: .segment)
        }
    }
}

extension Annotation {
    /// where `anchor` sits on this Annotation, on screen; nil for a segment
    /// anchor on a kind without segments (a box)
    public func position(of anchor: AttachAnchor) -> CGPoint? {
        switch anchor {
        case let .frame(u):
            let b = kind.bounds
            return CGPoint(x: b.minX + u.x * b.width, y: b.minY + u.y * b.height).applying(affineTransform)
        case let .segment(i, t):
            let segs = kind.segments
            guard !segs.isEmpty else { return nil }
            let s = segs[min(max(0, i), segs.count - 1)]
            return s.strokePoint(at: min(max(0, t), 1)).applying(affineTransform)
        }
    }

    /// the frame anchor at screen point `p`: its position in the untransformed
    /// bounds, 0.5 on an axis the bounds have no extent on
    public func frameAnchor(at p: CGPoint) -> AttachAnchor {
        let b = kind.bounds, q = p.applying(affineTransform.inverted())
        return .frame(CGPoint(x: b.width == 0 ? 0.5 : (q.x - b.minX) / b.width,
                              y: b.height == 0 ? 0.5 : (q.y - b.minY) / b.height))
    }

    /// which points can attach: a Line's ends and bend, an open path's ends
    /// and nodes between, a closed path's nodes — and any Annotation whole
    public func canAttach(_ point: AttachPoint) -> Bool {
        switch (point, kind) {
        case (.whole, _): true
        case (.start, .line), (.end, .line), (.bend, .line): true
        case let (.start, .path(d)), let (.end, .path(d)): !d.closed && d.nodes.count > 1
        case let (.node(i), .path(d)): d.nodes.indices.contains(i)
        default: false
        }
    }

    /// where `point` sits now, on screen; nil for `.whole` or a point this kind lacks
    public func position(of point: AttachPoint) -> CGPoint? {
        let m = affineTransform
        switch (point, kind) {
        case let (.start, .line(s, _, _)): return s.applying(m)
        case let (.end, .line(_, e, _)): return e.applying(m)
        case let (.bend, .line(s, e, b)):
            return (b ?? CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)).applying(m)
        case let (.start, .path(d)): return d.nodes.first.map { $0.anchor.applying(m) }
        case let (.end, .path(d)): return d.nodes.last.map { $0.anchor.applying(m) }
        case let (.node(i), .path(d)):
            return d.nodes.indices.contains(i) ? d.nodes[i].anchor.applying(m) : nil
        default: return nil
        }
    }

    /// a copy with `point` moved to screen point `p` and the rest re-solved
    /// around it: a Line's bend keeps its place relative to the chord, so the
    /// curve and the ends' heads re-aim; a path node's handles ride along.
    /// The geometry is baked, so the transform comes back identity.
    func placing(_ point: AttachPoint, at p: CGPoint) -> Annotation {
        var a = baked
        switch (point, a.kind) {
        case let (.start, .line(s, e, b)):
            a.kind = .line(start: p, end: e, bend: b.map { Self.bend($0, keptFrom: (s, e), on: (p, e)) })
        case let (.end, .line(s, e, b)):
            a.kind = .line(start: s, end: p, bend: b.map { Self.bend($0, keptFrom: (s, e), on: (s, p)) })
        case let (.bend, .line(s, e, _)):
            a.kind = .line(start: s, end: e, bend: p)
        case (.start, .path(var d)), (.end, .path(var d)), (.node, .path(var d)):
            let i: Int = switch point {
            case .start: 0
            case .end: d.nodes.count - 1
            case let .node(i): i
            default: -1
            }
            guard d.nodes.indices.contains(i) else { return self }
            let n = d.nodes[i], dx = p.x - n.anchor.x, dy = p.y - n.anchor.y
            func shift(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x + dx, y: q.y + dy) }
            d.nodes[i] = PathNode(anchor: p, handleIn: n.handleIn.map(shift), handleOut: n.handleOut.map(shift))
            a.kind = .path(d)
        default:
            return self
        }
        return a
    }

    /// the bend that sits where `bend` sat relative to the old chord, on the
    /// new one: z = (B−S)/(E−S) as complex numbers, B' = S' + z·(E'−S')
    private static func bend(_ bend: CGPoint, keptFrom old: (CGPoint, CGPoint),
                             on new: (CGPoint, CGPoint)) -> CGPoint {
        let (s, e) = old, (ns, ne) = new
        let chord = CGVector(dx: e.x - s.x, dy: e.y - s.y), d2 = chord.dx * chord.dx + chord.dy * chord.dy
        guard d2 > 0 else { return bend }
        let rx = bend.x - s.x, ry = bend.y - s.y
        let zr = (rx * chord.dx + ry * chord.dy) / d2, zi = (ry * chord.dx - rx * chord.dy) / d2
        let nc = CGVector(dx: ne.x - ns.x, dy: ne.y - ns.y)
        return CGPoint(x: ns.x + zr * nc.dx - zi * nc.dy, y: ns.y + zr * nc.dy + zi * nc.dx)
    }

    /// the rotation an attached whole Annotation turns with: its own, or 0
    /// for kinds that never rotate (Magnify)
    var attachRotation: CGFloat { kind.transforms ? transform.rotation : 0 }
}

extension Segment {
    /// the point at parameter t as the stroke is drawn: a straight segment
    /// interpolates its ends evenly, a curve is the cubic
    func strokePoint(at t: CGFloat) -> CGPoint {
        straight ? CGPoint(x: p0.x + (p3.x - p0.x) * t, y: p0.y + (p3.y - p0.y) * t) : point(at: t)
    }
}
