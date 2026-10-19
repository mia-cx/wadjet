import CoreGraphics
import Foundation

/// rotation and flips, applied about the centre of the geometry's bounds: flip first, then rotate.
/// Resizing changes the geometry itself, never this.
public struct AnnotationTransform: Codable, Equatable, Sendable {
    public var rotation: CGFloat        // radians, counterclockwise in AppKit's y-up screen space
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public static let identity = AnnotationTransform()
    public init(rotation: CGFloat = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}

/// a grip on a selected Annotation
public enum SelectionHandle: Hashable, Sendable {
    /// x and y are each -1, 0 or 1: the min edge, the middle, or the max edge of the untransformed bounds
    case resize(x: Int, y: Int)
    /// a Line end (0 start, 1 end) or a Pen node's anchor
    case vertex(Int)
    /// the Line's on-curve midpoint — drag it to bend
    case bend
    /// a Pen node's bezier handle (outgoing steers the segment after the node)
    case tangent(Int, outgoing: Bool)
    case rotate
}

extension AnnotationKind {
    /// the points that define the geometry — a Censor's, shape's or counter's
    /// are its rect's min and max corners, so mapping them resizes; a
    /// Magnify's are its magnifier frame's, so moving/resizing never re-aims
    /// the source; Text's are its box's top-left and top-right (the box's
    /// height comes from the layout)
    var points: [CGPoint] {
        switch self {
        case let .line(start, end, bend): [start, end] + (bend.map { [$0] } ?? [])
        case let .path(data):
            data.nodes.flatMap { [$0.anchor] + [$0.handleIn, $0.handleOut].compactMap { $0 } }
        case let .censor(rect, _), let .shape(_, rect), let .window(_, rect):
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
        case let .counter(center, radius, _, _):
            [CGPoint(x: center.x - radius, y: center.y - radius),
             CGPoint(x: center.x + radius, y: center.y + radius)]
        case let .magnify(m):
            [CGPoint(x: m.frame.minX, y: m.frame.minY), CGPoint(x: m.frame.maxX, y: m.frame.maxY)]
        case let .text(d):
            [d.origin, CGPoint(x: d.origin.x + TextLayout(d).size.width, y: d.origin.y)]
        case let .image(_, p), let .canvas(_, p):
            [CGPoint(x: p.frame.minX, y: p.frame.minY), CGPoint(x: p.frame.maxX, y: p.frame.maxY)]
        }
    }
    /// the same kind with every defining point mapped — a counter rebuilds
    /// from its mapped box so it stays a circle; Text keeps its own rule: the
    /// mapped top edge becomes the new origin and wrapping width.
    func mapPoints(_ f: (CGPoint) -> CGPoint) -> AnnotationKind {
        switch self {
        case let .line(start, end, bend): return .line(start: f(start), end: f(end), bend: bend.map(f))
        case let .path(data):
            return .path(PathData(nodes: data.nodes.map {
                PathNode(anchor: f($0.anchor), handleIn: $0.handleIn.map(f), handleOut: $0.handleOut.map(f))
            }, closed: data.closed, rawPoints: data.rawPoints?.map(f), smoothing: data.smoothing))
        case let .censor(rect, method):
            return .censor(rect: rect.mapCorners(f), method: method)
        case let .shape(kind, rect):
            return .shape(kind, rect: rect.mapCorners(f))
        case let .window(layerID, frame):
            return .window(layerID: layerID, frame: frame.mapCorners(f))
        case let .counter(center, radius, value, format):
            let a = f(CGPoint(x: center.x - radius, y: center.y - radius)),
                b = f(CGPoint(x: center.x + radius, y: center.y + radius))
            return .counter(center: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                            radius: min(abs(a.x - b.x), abs(a.y - b.y)) / 2,
                            value: value, format: format)
        case let .magnify(m):
            var m = m
            m.frame = m.frame.mapCorners(f)
            return .magnify(m)
        case let .text(d):
            let l = TextLayout(d), tl = f(d.origin)
            let tr = f(CGPoint(x: d.origin.x + l.size.width, y: d.origin.y))
            var new = d
            new.origin = CGPoint(x: min(tl.x, tr.x), y: tl.y)
            // the mapped box's width less padding, at least one em
            new.width = max(abs(tr.x - tl.x) - 2 * l.padding.width, d.format.size)
            return .text(new)
        case let .image(asset, p):
            var p = p; p.frame = p.frame.mapCorners(f)
            return .image(asset: asset, p)
        case let .canvas(link, p):
            var p = p; p.frame = p.frame.mapCorners(f)
            return .canvas(link, p)
        }
    }
    /// resizes with one scale on both axes so it keeps its shape — counters
    /// always; image kinds unless the drag passes `stretch`
    var keepsAspect: Bool {
        switch self {
        case .counter, .window, .image, .canvas: true
        case .line, .path, .censor, .shape, .magnify, .text: false
        }
    }
    /// an upright box that mapPoints re-standardizes, so a negative resize
    /// scale has to become a flip instead — Text's map handles its own mirror
    var isBox: Bool {
        switch self {
        case .line, .path, .text: false
        case .censor, .shape, .counter, .magnify, .window, .image, .canvas: true
        }
    }
    /// whether rotation and flips apply — a Magnify's frame only moves and
    /// resizes, so its transform stays identity and it hides the rotate grip
    public var transforms: Bool {
        switch self {
        case .magnify: false
        default: true
        }
    }
    /// every defining point offset by `d`. Text shifts its origin alone so a
    /// nil (fit-to-text) width stays nil — a box-width map would freeze it.
    func translated(by d: CGVector) -> AnnotationKind {
        if case var .text(t) = self {
            t.origin = CGPoint(x: t.origin.x + d.dx, y: t.origin.y + d.dy)
            return .text(t)
        }
        return mapPoints { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }
    /// tight bounds of the untransformed geometry — a bent Line's frame hugs
    /// the curve; straight segments keep the points' box so a horizontal
    /// Line's height stays exactly 0 (the grip logic keys on `== 0`); Text's
    /// box comes from the layout
    public var bounds: CGRect {
        if case let .text(d) = self { return TextLayout(d).box }
        let segs = segments
        guard segs.contains(where: { !$0.straight }) else {
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        return PathGeometry.path(segments: segs).boundingBoxOfPath
    }
}

extension Annotation {
    /// geometry -> screen: flip about the bounds centre, then rotate about it
    public var affineTransform: CGAffineTransform {
        guard kind.transforms else { return .identity }
        let c = CGPoint(x: kind.bounds.midX, y: kind.bounds.midY)
        return CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: transform.flipHorizontal ? -1 : 1,
                                             y: transform.flipVertical ? -1 : 1))
            .concatenating(CGAffineTransform(rotationAngle: transform.rotation))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    }

    /// every point offset by `d` — the transform is about the bounds centre, so it stays valid
    public func moved(by d: CGVector) -> Annotation {
        var a = self
        a.kind = kind.translated(by: d)
        return a
    }

    /// a Brush stroke refit at a new smoothing, kept in place: the transform
    /// pivots on the bounds centre, which a refit can move, so the first raw
    /// sample's screen position is pinned (the fitter keeps endpoints, and the
    /// samples move with the geometry, so later refits stay stable). Anything
    /// else returns unchanged — a Pen path refits identically anyway.
    public func refitted(smoothing s: CGFloat) -> Annotation {
        guard case let .path(d) = kind, let pin = d.rawPoints?.first else { return self }
        var a = self
        a.kind = .path(d.refitted(smoothing: s))
        guard case let .path(r) = a.kind, let pinNow = r.rawPoints?.first else { return a }
        let was = pin.applying(affineTransform), now = pinNow.applying(a.affineTransform)
        return a.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y))
    }

    /// this close to the chord midpoint a bend straightens back to a line
    public static let bendStraightenRadius: CGFloat = 3

    /// the same geometry baked into screen coordinates — lossless for kinds
    /// whose points mapPoints covers (flips+rotation are similarities)
    var baked: Annotation {
        var a = self
        a.kind = kind.mapPoints { $0.applying(affineTransform) }
        a.transform = .identity
        return a
    }

    /// a handle drag, computed from the state at drag start (`self`) so it can't
    /// drift; `constrained` (Shift) snaps a vertex drag to 45° of the other end.
    /// Image kinds keep their aspect ratio unless `stretch` (also Shift); other
    /// kinds ignore it.
    public func dragging(_ handle: SelectionHandle, from start: CGPoint, to point: CGPoint,
                         constrained: Bool = false, stretch: Bool = false) -> Annotation {
        switch handle {
        case let .vertex(i):
            // the grip's position at drag start plus the drag — the press needn't land dead-on
            var a = baked
            let d = CGPoint(x: point.x - start.x, y: point.y - start.y)
            if case var .path(data) = a.kind {
                guard data.nodes.indices.contains(i) else { return a }
                var anchor = CGPoint(x: data.nodes[i].anchor.x + d.x,
                                     y: data.nodes[i].anchor.y + d.y)
                // 45° from the previous node (the next one for node 0 of an
                // open path — a closed path wraps)
                if constrained {
                    let j = data.closed ? (i + data.nodes.count - 1) % data.nodes.count
                                        : i == 0 ? (data.nodes.count > 1 ? 1 : i) : i - 1
                    anchor = PathGeometry.snapAngle(anchor, from: data.nodes[j].anchor)
                }
                let delta = CGPoint(x: anchor.x - data.nodes[i].anchor.x,
                                    y: anchor.y - data.nodes[i].anchor.y)
                // the node's handles ride along with its anchor
                data.nodes[i].anchor = anchor
                data.nodes[i].handleIn = data.nodes[i].handleIn.map {
                    CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
                data.nodes[i].handleOut = data.nodes[i].handleOut.map {
                    CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
                a.kind = .path(data)
                return a
            }
            guard case var .line(s, e, b) = a.kind else { return a }
            var p = i == 0 ? CGPoint(x: s.x + d.x, y: s.y + d.y)
                           : CGPoint(x: e.x + d.x, y: e.y + d.y)
            if constrained { p = PathGeometry.snapAngle(p, from: i == 0 ? e : s) }
            // the bend keeps its place relative to the chord: z = (B−S)/(E−S)
            // as complex numbers, so B' = S' + z·(E'−S')
            if let bendPt = b {
                let chord = CGPoint(x: e.x - s.x, y: e.y - s.y)
                if chord.x != 0 || chord.y != 0 {
                    let d2 = chord.x * chord.x + chord.y * chord.y
                    let rel = CGPoint(x: bendPt.x - s.x, y: bendPt.y - s.y)
                    let zr = (rel.x * chord.x + rel.y * chord.y) / d2
                    let zi = (rel.y * chord.x - rel.x * chord.y) / d2
                    let (ns, ne) = i == 0 ? (p, e) : (s, p)
                    let newChord = CGPoint(x: ne.x - ns.x, y: ne.y - ns.y)
                    b = CGPoint(x: ns.x + zr * newChord.x - zi * newChord.y,
                                y: ns.y + zr * newChord.y + zi * newChord.x)
                }
            }
            if i == 0 { s = p } else { e = p }
            a.kind = .line(start: s, end: e, bend: b)
            return a
        case .bend:
            var a = baked
            guard case let .line(s, e, b) = a.kind else { return a }
            let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
            let grip = b ?? mid
            let p = CGPoint(x: grip.x + point.x - start.x, y: grip.y + point.y - start.y)
            a.kind = .line(start: s, end: e,
                           bend: hypot(p.x - mid.x, p.y - mid.y) < Self.bendStraightenRadius ? nil : p)
            return a
        case let .tangent(i, outgoing):
            var a = baked
            guard case var .path(data) = a.kind, data.nodes.indices.contains(i) else { return a }
            let n = data.nodes[i]
            let old = outgoing ? n.handleOut : n.handleIn
            var h = CGPoint(x: (old?.x ?? n.anchor.x) + point.x - start.x,
                            y: (old?.y ?? n.anchor.y) + point.y - start.y)
            if constrained { h = PathGeometry.snapAngle(h, from: n.anchor) }
            if outgoing { data.nodes[i].handleOut = h } else { data.nodes[i].handleIn = h }
            // a smooth node stays smooth: the opposite handle turns to stay
            // collinear through the anchor at its own length; a nil one stays nil
            if let other = outgoing ? n.handleIn : n.handleOut {
                let ux = n.anchor.x - h.x, uy = n.anchor.y - h.y, l = hypot(ux, uy)
                if l > 1e-9 {
                    let len = hypot(other.x - n.anchor.x, other.y - n.anchor.y)
                    let opp = CGPoint(x: n.anchor.x + ux / l * len, y: n.anchor.y + uy / l * len)
                    if outgoing { data.nodes[i].handleIn = opp } else { data.nodes[i].handleOut = opp }
                }
            }
            a.kind = .path(data)
            return a
        case let .resize(x, y):
            let b = kind.bounds, m = affineTransform
            let p = point.applying(m.inverted())
            let anchor = CGPoint(x: b.midX - CGFloat(x) * b.width / 2, y: b.midY - CGFloat(y) * b.height / 2)
            let grip = CGPoint(x: b.midX + CGFloat(x) * b.width / 2, y: b.midY + CGFloat(y) * b.height / 2)
            // a 0 component leaves that axis alone; dragging past the anchor mirrors (negative scale)
            var sx = x == 0 || grip.x == anchor.x ? 1 : (p.x - anchor.x) / (grip.x - anchor.x)
            var sy = y == 0 || grip.y == anchor.y ? 1 : (p.y - anchor.y) / (grip.y - anchor.y)
            if kind.keepsAspect && !(stretch && placement != nil) {
                // one scale for both axes: the grip's moving axis on an edge
                // drag (the anchor is the middle, so it grows symmetrically),
                // the larger on a corner — signs kept, so it can still mirror
                let u = x == 0 ? abs(sy) : y == 0 ? abs(sx) : max(abs(sx), abs(sy))
                sx = x == 0 ? u : (sx < 0 ? -u : u)
                sy = y == 0 ? u : (sy < 0 ? -u : u)
            }
            var new = self
            new.kind = kind.mapPoints { CGPoint(x: anchor.x + ($0.x - anchor.x) * sx,
                                                y: anchor.y + ($0.y - anchor.y) * sy) }
            // a box kind re-standardizes inside mapPoints, so a negative scale
            // can't mirror it — carry the mirror as a geometry-space flip
            // (applied before the rotation, unlike flipped(horizontally:)) and
            // pin the content that sat on the anchor: after the mirror it
            // lives at the anchor reflected about the NEW bounds centre
            var pin = anchor
            if kind.isBox && kind.transforms {
                let c = CGPoint(x: new.kind.bounds.midX, y: new.kind.bounds.midY)
                if sx < 0 { new.transform.flipHorizontal.toggle(); pin.x = 2 * c.x - pin.x }
                if sy < 0 { new.transform.flipVertical.toggle(); pin.y = 2 * c.y - pin.y }
            }
            // the new bounds centre moved, so the transform's pivot did too — keep
            // the pin where the anchor was on screen
            let was = anchor.applying(m), now = pin.applying(new.affineTransform)
            return new.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y))
        case .rotate:
            let c = CGPoint(x: kind.bounds.midX, y: kind.bounds.midY)
            return rotated(by: atan2(point.y - c.y, point.x - c.x) - atan2(start.y - c.y, start.x - c.x))
        }
    }

    /// a resize-handle drag that moves the crop edges with the frame edges: the
    /// frame reveals more or less of `source` while the kept content stays put.
    /// `.rotate` and non-image kinds return self.
    public func recropping(_ handle: SelectionHandle, from start: CGPoint, to point: CGPoint,
                           source: CGRect) -> Annotation {
        guard case let .resize(x, y) = handle, var p = placement else { return self }
        let b = p.frame, m = affineTransform
        // the edge moves by the pointer's delta from the press, so an off-grip
        // press doesn't jump the edge to the pointer
        let s = start.applying(m.inverted()), q = point.applying(m.inverted())
        // the matching crop edge moves the same distance in source units,
        // staying inside source and ≥ 1 unit wide (so it can never mirror)
        func delta(_ edge: Int, _ d: CGFloat, _ k: CGFloat,
                   _ cropMin: CGFloat, _ cropMax: CGFloat,
                   _ sourceMin: CGFloat, _ sourceMax: CGFloat) -> CGFloat {
            var d = d
            if edge > 0 { d = min(d, (sourceMax - cropMax) * k); d = max(d, (cropMin + 1 - cropMax) * k) }
            else { d = max(d, (sourceMin - cropMin) * k); d = min(d, (cropMax - 1 - cropMin) * k) }
            return d
        }
        if x != 0 {
            let k = b.width / p.crop.width
            let d = delta(x, q.x - s.x, k,
                          p.crop.minX, p.crop.maxX, source.minX, source.maxX)
            if x > 0 { p.frame.size.width += d; p.crop.size.width += d / k }
            else { p.frame.origin.x += d; p.frame.size.width -= d
                   p.crop.origin.x += d / k; p.crop.size.width -= d / k }
        }
        if y != 0 {
            let k = b.height / p.crop.height
            let d = delta(y, q.y - s.y, k,
                          p.crop.minY, p.crop.maxY, source.minY, source.maxY)
            if y > 0 { p.frame.size.height += d; p.crop.size.height += d / k }
            else { p.frame.origin.y += d; p.frame.size.height -= d
                   p.crop.origin.y += d / k; p.crop.size.height -= d / k }
        }
        var new = self
        new.placement = p
        // the new frame centre moves the transform's pivot — re-pin the opposite
        // edge so the untouched side (and the image) stays where it was on screen
        let anchor = CGPoint(x: b.midX - CGFloat(x) * b.width / 2,
                             y: b.midY - CGFloat(y) * b.height / 2)
        let was = anchor.applying(m), now = anchor.applying(new.affineTransform)
        return new.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y))
    }

    /// the frame stays while the content follows the pointer: the crop slides
    /// inside `source`, clamped at its edges
    public func panning(from start: CGPoint, to point: CGPoint, source: CGRect) -> Annotation {
        guard var p = placement else { return self }
        let mi = affineTransform.inverted()
        let a = start.applying(mi), q = point.applying(mi)
        let kx = p.frame.width / p.crop.width, ky = p.frame.height / p.crop.height
        p.crop.origin.x = min(max(p.crop.origin.x - (q.x - a.x) / kx, source.minX),
                              source.maxX - p.crop.width)
        p.crop.origin.y = min(max(p.crop.origin.y - (q.y - a.y) / ky, source.minY),
                              source.maxY - p.crop.height)
        var new = self
        new.placement = p
        return new
    }

    /// positive = counterclockwise
    public func rotated(by angle: CGFloat) -> Annotation {
        var a = self
        a.transform.rotation = (transform.rotation + angle).remainder(dividingBy: 2 * .pi)
        return a
    }

    /// a mirror across the screen's vertical (`horizontally`) or horizontal axis
    /// through the centre, whatever the rotation: the flip toggles and the
    /// rotation unwinds so the rendered shape mirrors instead of spinning
    public func flipped(horizontally: Bool) -> Annotation {
        var a = self
        if horizontally { a.transform.flipHorizontal.toggle() } else { a.transform.flipVertical.toggle() }
        a.transform.rotation = -transform.rotation
        return a
    }

    /// the bounds' corners — (minX,minY) (maxX,minY) (maxX,maxY) (minX,maxY) — on screen
    public var frameCorners: [CGPoint] {
        let b = kind.bounds, m = affineTransform
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            .map { $0.applying(m) }
    }

    /// screen positions of the selection's grips — a Line gets a grip per end
    /// and one on its curve, a Pen path one per node plus one per bezier
    /// handle (nodes edit the shape, so paths get no frame resize grips);
    /// every kind also gets `.rotate` above the frame — placed by rotation
    /// alone, and everything else falls back to the bounds' resize grips
    public func handles(minExtent: CGFloat, rotateOffset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        let m = affineTransform, b = kind.bounds
        let c = CGPoint(x: b.midX, y: b.midY), v = b.height / 2 + rotateOffset
        let rotate = (SelectionHandle.rotate,
                      CGPoint(x: c.x - v * sin(transform.rotation),
                              y: c.y + v * cos(transform.rotation)))
        switch kind {
        case let .line(start, end, bend):
            let mid = bend ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            return [(.vertex(0), start.applying(m)),
                    (.vertex(1), end.applying(m)),
                    (.bend, mid.applying(m)),
                    rotate]
        case let .path(data) where data.rawPoints != nil:
            // a Brush stroke resizes as a frame — its nodes come from fitting,
            // and a refit would discard node edits
            return frameHandles(minExtent: minExtent, rotateOffset: rotateOffset)
        case let .path(data):
            var out: [(handle: SelectionHandle, at: CGPoint)] = data.nodes.indices.map {
                (.vertex($0), data.nodes[$0].anchor.applying(m))
            }
            for (i, n) in data.nodes.enumerated() {
                if let h = n.handleOut, h != n.anchor { out.append((.tangent(i, outgoing: true), h.applying(m))) }
                if let h = n.handleIn, h != n.anchor { out.append((.tangent(i, outgoing: false), h.applying(m))) }
            }
            out.append(rotate)
            return out
        // Text resizes its width alone — a box grip would imply a height it has
        case .text:
            return [(.resize(x: -1, y: 0), CGPoint(x: b.minX, y: b.midY).applying(m)),
                    (.resize(x: 1, y: 0), CGPoint(x: b.maxX, y: b.midY).applying(m)),
                    rotate]
        default:
            return frameHandles(minExtent: minExtent, rotateOffset: rotateOffset)
        }
    }

    /// screen positions of the bounds-based grips:
    /// - the 4 corners (x, y ∈ {-1, 1}), a component set to 0 on any axis whose
    ///   extent is exactly 0 (it would resize nothing), deduplicated keeping
    ///   first-seen order (x outer, y inner, -1 before 1) — so a horizontal
    ///   Line gets only resize(-1,0) at its left end and resize(1,0) at its
    ///   right end, and an undersized diagonal keeps all 4 corners
    /// - the 4 edge midpoints resize(0,±1), resize(±1,0), only when BOTH width
    ///   and height are ≥ `minExtent`
    /// - then `.rotate` above the frame's top centre — placed by rotation alone
    ///   so a flip can't put it below
    public func frameHandles(minExtent: CGFloat, rotateOffset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        let b = kind.bounds, m = affineTransform
        func at(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: b.midX + CGFloat(x) * b.width / 2,
                    y: b.midY + CGFloat(y) * b.height / 2).applying(m)
        }
        var out: [(handle: SelectionHandle, at: CGPoint)] = []
        var seen = Set<SelectionHandle>()
        // Text's height comes from the layout: its grips only set the
        // wrapping width — the two edge midpoints, then .rotate
        if case .text = kind {
            out.append((.resize(x: -1, y: 0), at(-1, 0)))
            out.append((.resize(x: 1, y: 0), at(1, 0)))
            let c = CGPoint(x: b.midX, y: b.midY), v = b.height / 2 + rotateOffset
            out.append((.rotate, CGPoint(x: c.x - v * sin(transform.rotation),
                                         y: c.y + v * cos(transform.rotation))))
            return out
        }
        for x in -1...1 where x != 0 { for y in -1...1 where y != 0 {
            let h = SelectionHandle.resize(x: b.width == 0 ? 0 : x, y: b.height == 0 ? 0 : y)
            if seen.insert(h).inserted { out.append((h, at(x, y))) }
        } }
        if b.width >= minExtent && b.height >= minExtent {
            for (x, y) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                out.append((.resize(x: x, y: y), at(x, y)))
            }
        }
        if kind.transforms {
            let c = CGPoint(x: b.midX, y: b.midY), v = b.height / 2 + rotateOffset
            out.append((.rotate, CGPoint(x: c.x - v * sin(transform.rotation),
                                         y: c.y + v * cos(transform.rotation))))
        }
        return out
    }

    /// the grip nearest `p`, if within `radius` — nearest, not first, so grips
    /// crowded closer than `radius` resolve to the one the press meant
    public func handle(at p: CGPoint, radius: CGFloat, minExtent: CGFloat,
                       rotateOffset: CGFloat) -> SelectionHandle? {
        handles(minExtent: minExtent, rotateOffset: rotateOffset)
            .map { ($0.handle, hypot($0.at.x - p.x, $0.at.y - p.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }
}

private extension CGRect {
    /// the rect through two mapped corners — a negative resize scale mirrors
    /// them, so it re-standardizes
    func mapCorners(_ f: (CGPoint) -> CGPoint) -> CGRect {
        let a = f(CGPoint(x: minX, y: minY)), b = f(CGPoint(x: maxX, y: maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
    }
}
