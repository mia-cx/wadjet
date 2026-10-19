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
        case .censor, .shape, .counter:
            return []
        }
    }
}

/// a stroke and its ends, ready to draw: stroke the first (round caps/joins,
/// `style.dash` pattern), fill the second with the same colour
public struct AnnotationDrawing {
    public let stroke: CGPath
    public let ends: CGPath
}

/// Builds each Annotation's drawable path and hit-tests it — the stroked
/// outline and a Line's ends, or the filled area when filled. Strokes have
/// round caps and joins, as the Markup panels draw them.
public enum PathGeometry {
    /// the segments' path, before any transform
    static func path(segments: [Segment]) -> CGPath {
        let p = CGMutablePath()
        guard let first = segments.first else { return p }
        p.move(to: first.p0)
        for s in segments {
            if s.straight { p.addLine(to: s.p3) } else { p.addCurve(to: s.p3, control1: s.c1, control2: s.c2) }
        }
        return p
    }

    /// the geometry's path in screen coordinates — drawn and hit-tested
    /// through the Annotation's transform
    public static func path(for a: Annotation) -> CGPath {
        let p = CGMutablePath()
        switch a.kind {
        case .line:
            p.addPath(path(segments: a.kind.segments))
        case let .censor(rect, _):
            p.addRect(rect)
        case let .shape(kind, rect):
            p.addPath(kind.path(in: rect))
        case let .counter(center, radius, _, _):
            p.addPath(CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: 2 * radius, height: 2 * radius),
                             transform: nil))
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

    /// the stroke (trimmed so a filled arrow's tip stays sharp) and the filled
    /// ends, both in screen coordinates; filled kinds draw nothing here
    public static func drawing(for a: Annotation) -> AnnotationDrawing {
        let segments = a.kind.segments, w = a.style.width
        let ends = CGMutablePath()
        var strokeSegments = segments
        if let last = segments.last {
            let u = last.endOutward, n = CGPoint(x: -u.y, y: u.x)
            ends.addPath(endMark(a.style.head, at: last.p3, u: u, n: n, width: w))
            if a.style.head == .filledArrow {
                strokeSegments = trimmedEnd(strokeSegments, by: headLength(width: w) / 2)
            }
        }
        // tangents come from the untrimmed geometry, and the tail's mark sits
        // at the untrimmed start even if the head's trim reached it
        if let first = segments.first {
            let u = first.startOutward, n = CGPoint(x: -u.y, y: u.x)
            ends.addPath(endMark(a.style.tail, at: first.p0, u: u, n: n, width: w))
            if a.style.tail == .filledArrow {
                strokeSegments = trimmedStart(strokeSegments, by: headLength(width: w) / 2)
            }
        }
        var t = a.affineTransform
        return AnnotationDrawing(
            stroke: path(segments: strokeSegments).copy(using: &t) ?? path(segments: strokeSegments),
            ends: ends.copy(using: &t) ?? ends)
    }

    /// whether `point` lands on the filled area, on the stroked outline — the
    /// stroke geometry is untrimmed and undashed, so a click between two
    /// dashes still selects — or on a Line's ends, each widened by `tolerance`
    public static func hitTest(_ a: Annotation, at point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        let p = path(for: a)
        if a.fillColour != nil && p.contains(point) { return true }
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
