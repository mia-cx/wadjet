import CoreGraphics
import CoreText
import Foundation

/// one cubic piece of an Annotation's geometry; `straight` segments draw as
/// lines (c1/c2 are then the endpoints) — Pen will join Line with node chains
struct Segment {
    var p0, c1, c2, p3: CGPoint
    var straight: Bool
}

extension AnnotationKind {
    /// the stroked geometry as cubics — a straight Line is one segment; a bent
    /// Line's quadratic C = 2·bend − (start+end)/2 is elevated: c1 = S + 2/3(C−S).
    /// Filled kinds (Censor, shapes) have no stroked geometry here
    var segments: [Segment] {
        switch self {
        case let .line(start, end, bend):
            guard let bend else {
                return [Segment(p0: start, c1: start, c2: end, p3: end, straight: true)]
            }
            let c = CGPoint(x: 2 * bend.x - (start.x + end.x) / 2,
                            y: 2 * bend.y - (start.y + end.y) / 2)
            return [Segment(p0: start,
                            c1: CGPoint(x: start.x + (c.x - start.x) * 2 / 3,
                                        y: start.y + (c.y - start.y) * 2 / 3),
                            c2: CGPoint(x: end.x + (c.x - end.x) * 2 / 3,
                                        y: end.y + (c.y - end.y) * 2 / 3),
                            p3: end, straight: false)]
        case let .path(data):
            // consecutive node pairs, plus last→first when closed; a pair is
            // straight when both inner handles are nil — else a cubic whose
            // missing handle collapses to its anchor. One node → a dot
            guard let first = data.nodes.first else { return [] }
            if data.nodes.count == 1 {
                let a = first.anchor
                return [Segment(p0: a, c1: a, c2: a, p3: a, straight: true)]
            }
            let pairs = zip(data.nodes, data.nodes.dropFirst())
            var segs = pairs.map { a, b in
                Segment(p0: a.anchor,
                        c1: a.handleOut ?? a.anchor,
                        c2: b.handleIn ?? b.anchor,
                        p3: b.anchor,
                        straight: a.handleOut == nil && b.handleIn == nil)
            }
            if data.closed, let last = data.nodes.last {
                segs.append(Segment(p0: last.anchor,
                                    c1: last.handleOut ?? last.anchor,
                                    c2: first.handleIn ?? first.anchor,
                                    p3: first.anchor,
                                    straight: last.handleOut == nil && first.handleIn == nil))
            }
            return segs
        case .censor, .shape, .counter, .magnify, .text, .window, .image, .canvas:
            return []
        }
    }
    /// closed paths fill; everything else is an open stroke
    public var isClosed: Bool {
        if case let .path(d) = self { return d.closed }
        return false
    }
}

/// a stroke and its ends, ready to draw: stroke the first (round caps/joins,
/// `style.dash` pattern), fill the second with the same colour
public struct AnnotationDrawing {
    /// the closed path's geometry when the style fills it, else nil
    public let fill: CGPath?
    public let stroke: CGPath
    public let ends: CGPath
}

/// Builds each Annotation's drawable path and hit-tests it — the stroked
/// outline and a Line's ends, or the filled area when filled. A Magnify's
/// path is its source outline and leader; the magnifier box draws separately.
/// Strokes have round caps and joins, as the Markup panels draw them.
public enum PathGeometry {
    /// the segments' path, before any transform; `closed` joins it back to its start
    static func path(segments: [Segment], closed: Bool = false) -> CGPath {
        let p = CGMutablePath()
        guard let first = segments.first else { return p }
        p.move(to: first.p0)
        for s in segments {
            if s.straight { p.addLine(to: s.p3) } else { p.addCurve(to: s.p3, control1: s.c1, control2: s.c2) }
        }
        if closed { p.closeSubpath() }
        return p
    }

    /// the geometry's path in screen coordinates — drawn and hit-tested
    /// through the Annotation's transform
    public static func path(for a: Annotation) -> CGPath {
        let p = CGMutablePath()
        switch a.kind {
        case .line, .path:
            p.addPath(path(segments: a.kind.segments, closed: a.kind.isClosed))
        case let .censor(rect, _):
            p.addRect(rect)
        case let .shape(kind, rect):
            p.addPath(kind.path(in: rect))
        case let .counter(center, radius, _, _):
            p.addPath(CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: 2 * radius, height: 2 * radius),
                             transform: nil))
        case let .magnify(m):
            p.addPath(m.options.shape.path(in: m.source))
            if m.options.leader, let l = m.leader {
                p.move(to: l.start); p.addLine(to: l.end)
            }
        case let .text(d):
            p.addRect(TextLayout(d).box)
        case let .window(_, frame):
            p.addRect(frame)
        case let .image(_, placement), let .canvas(_, placement):
            let r = min(placement.cornerRadius,
                        min(placement.frame.width, placement.frame.height) / 2)
            p.addPath(CGPath(roundedRect: placement.frame, cornerWidth: r, cornerHeight: r, transform: nil))
        }
        var t = a.affineTransform
        return p.copy(using: &t) ?? p
    }
    /// a counter's label as glyph outlines, filled white over the circle: bold
    /// system font at 1.1 × radius, scaled down to fit 1.4 × radius wide,
    /// centred on the glyphs' bounding box. It turns with the counter's
    /// rotation but never mirrors. nil for other kinds.
    public static func labelPath(for a: Annotation) -> CGPath? {
        guard case let .counter(center, radius, value, format) = a.kind else { return nil }
        guard let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 1.1 * radius, nil) else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: format.label(value), attributes: [.font: font]))
        let glyphs = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphIDs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(), &glyphIDs)
            CTRunGetPositions(run, CFRange(), &positions)
            for i in 0..<n {
                if let g = CTFontCreatePathForGlyph(font, glyphIDs[i], nil) {
                    glyphs.addPath(g, transform: CGAffineTransform(translationX: positions[i].x,
                                                                   y: positions[i].y))
                }
            }
        }
        // centre the glyph bounding box on the counter, then rotate about it —
        // the label never mirrors, so the flip components don't apply
        let bb = glyphs.boundingBox
        let s = bb.width > 0 ? min(1, 1.4 * radius / bb.width) : 1
        var t = CGAffineTransform(translationX: -bb.midX, y: -bb.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(rotationAngle: a.transform.rotation))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return glyphs.copy(using: &t) ?? glyphs
    }

    /// the stroke (trimmed so a filled arrow's tip stays sharp), the filled
    /// ends, and a closed path's fill — all in screen coordinates. Closed
    /// paths get no ends and no trim; filled kinds draw nothing here
    public static func drawing(for a: Annotation) -> AnnotationDrawing {
        let segments = a.kind.segments, w = a.style.width, reach = headLength(width: w)
        let closed = a.kind.isClosed
        let ends = CGMutablePath()
        var strokeSegments = segments
        // each end aims along the stroke its arrowhead covers, not the last
        // control vector — see endOutward(_:reach:)
        if !closed, let last = segments.last {
            let u = endOutward(segments, reach: reach), n = CGPoint(x: -u.y, y: u.x)
            ends.addPath(endMark(a.style.head, at: last.p3, u: u, n: n, width: w))
            if a.style.head == .filledArrow {
                strokeSegments = trimmedEnd(strokeSegments, by: headLength(width: w) / 2)
            }
        }
        // tangents come from the untrimmed geometry, and the tail's mark sits
        // at the untrimmed start even if the head's trim reached it
        if !closed, let first = segments.first {
            let u = startOutward(segments, reach: reach), n = CGPoint(x: -u.y, y: u.x)
            ends.addPath(endMark(a.style.tail, at: first.p0, u: u, n: n, width: w))
            if a.style.tail == .filledArrow {
                strokeSegments = trimmedStart(strokeSegments, by: headLength(width: w) / 2)
            }
        }
        var t = a.affineTransform
        let body = path(segments: strokeSegments, closed: closed)
        let stroke = body.copy(using: &t) ?? body
        return AnnotationDrawing(
            fill: closed && a.style.fill != nil ? stroke : nil,
            stroke: stroke,
            ends: ends.copy(using: &t) ?? ends)
    }

    /// the area an Annotation paints, as one path: its fill when it fills an
    /// area (`fillsArea` — filled kinds and windows), ∪ its stroked outline
    /// when `strokeColour` is (∪ a Line's filled
    /// end marks), ∪ for a Magnify the magnifier's silhouette (∪ that
    /// silhouette stroked at style.width when it carries a border). Use it
    /// where "does it paint here" matters — retention, coverage masks — where
    /// hitTest's looser tolerance wouldn't.
    public static func coverage(for a: Annotation) -> CGPath {
        let p = path(for: a)
        var covered = CGMutablePath() as CGPath
        if a.fillsArea {
            covered = covered.union(p, using: .winding)
        }
        if a.strokeColour != nil {
            covered = covered.union(p.copy(strokingWithWidth: a.style.width,
                lineCap: .round, lineJoin: .round, miterLimit: 10), using: .winding)
            // a filled arrow's head and tail paint past the stroke's path
            covered = covered.union(drawing(for: a).ends, using: .winding)
        }
        if case let .magnify(m) = a.kind {
            let silhouette = m.options.shape.path(in: m.frame)
            covered = covered.union(silhouette, using: .winding)
            if m.options.border != nil {
                covered = covered.union(silhouette.copy(strokingWithWidth: a.style.width,
                    lineCap: .round, lineJoin: .round, miterLimit: 10), using: .winding)
            }
        }
        return covered
    }
    /// whether `point` lands on the filled area, on the stroked outline — the
    /// stroke geometry is untrimmed and undashed, so a click between two
    /// dashes still selects — or on a Line's ends, each widened by `tolerance`;
    /// a Magnify also hits anywhere inside its magnifier box
    public static func hitTest(_ a: Annotation, at point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        if case let .magnify(m) = a.kind,
           m.options.shape.path(in: m.frame).contains(point) { return true }
        let p = path(for: a)
        if a.fillsArea && p.contains(point) { return true }
        if p.copy(strokingWithWidth: (a.strokeColour == nil ? 0 : a.style.width) + 2 * tolerance,
                  lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point) { return true }
        let ends = drawing(for: a).ends
        return ends.contains(point)
            || ends.copy(strokingWithWidth: 2 * tolerance,
                         lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }

    /// `p` projected onto the nearest 45° ray from `origin` — keeps the
    /// projection's length along the ray, so a near-horizontal drag keeps x
    public static func snapAngle(_ p: CGPoint, from origin: CGPoint) -> CGPoint {
        let v = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
        let a = (atan2(v.y, v.x) / (.pi / 4)).rounded() * (.pi / 4)
        let u = CGPoint(x: cos(a), y: sin(a))
        let t = v.x * u.x + v.y * u.y
        return CGPoint(x: origin.x + t * u.x, y: origin.y + t * u.y)
    }
}
