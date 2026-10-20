import Testing
import Foundation
import WadjetKit

struct PathGeometryTests {
    // a horizontal line (0,0)->(100,0); the stroke reaches width/2 to each side
    @Test(arguments: [
        (4.0, CGPoint(x: 50, y: 1.9), 0.0, true),   // inside the 4-pt stroke
        (4.0, CGPoint(x: 50, y: 2.1), 0.0, false),  // just outside it
        (10.0, CGPoint(x: 50, y: 4.9), 0.0, true),  // a wider stroke reaches further
        (10.0, CGPoint(x: 50, y: 5.1), 0.0, false),
        (4.0, CGPoint(x: 101.9, y: 0), 0.0, true),  // round cap extends past the end point
        (4.0, CGPoint(x: 102.1, y: 0), 0.0, false),
        (4.0, CGPoint(x: 50, y: 3), 2.0, true),     // tolerance widens the stroke on each side
    ])
    func lineHitTest(width: Double, point: CGPoint, tolerance: Double, expected: Bool) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: width))
        #expect(PathGeometry.hitTest(a, at: point, tolerance: tolerance) == expected)
    }

    // rotated pi/2 about the bounds centre, a (0,0)->(100,0) line displays
    // vertical at x=50, y -50…50 — drawing and hit-testing follow the transform
    @Test(arguments: [
        (CGPoint(x: 50, y: 40), true),
        (CGPoint(x: 90, y: 0), false),
    ])
    func rotatedLineHitTest(point: CGPoint, expected: Bool) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4),
                           transform: AnnotationTransform(rotation: .pi / 2))
        #expect(PathGeometry.hitTest(a, at: point) == expected)
    }

    // Proves a censor rect hit-tests as a filled shape: inside counts, and
    // tolerance reaches past its edge; rotated pi/2 about the centre (50,25),
    // (0,0,100,50) displays x 25…75, y -25…75
    @Test(arguments: [
        (CGPoint(x: 50, y: 25), 0.0, 0.0, true),    // centre: filled area hits
        (CGPoint(x: 101, y: 25), 0.0, 0.0, false),  // just past the edge
        (CGPoint(x: 101, y: 25), 2.0, 0.0, true),   // tolerance reaches outside
        (CGPoint(x: 50, y: 70), 0.0, .pi / 2, true),  // inside once rotated
        (CGPoint(x: 90, y: 25), 0.0, .pi / 2, false), // outside the rotated span
    ])
    func censorHitTest(point: CGPoint, tolerance: Double, rotation: Double, expected: Bool) {
        let a = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 100, height: 50),
                                         method: .blackOut),
                           style: AnnotationStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 1), width: 4),
                           transform: AnnotationTransform(rotation: rotation))
        #expect(PathGeometry.hitTest(a, at: point, tolerance: tolerance) == expected)
    }

    // flipped horizontally about the centre, a (0,0)->(100,50) line displays (0,50)->(100,0)
    @Test(arguments: [
        (CGPoint(x: 10, y: 45), true),
        (CGPoint(x: 10, y: 5), false),
    ])
    func flippedLineHitTest(point: CGPoint, expected: Bool) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 50)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4),
                           transform: AnnotationTransform(flipHorizontal: true))
        #expect(PathGeometry.hitTest(a, at: point) == expected)
    }

    // dash lengths scale with the stroke width; solid draws undashed (nil)
    @Test(arguments: [
        (LineDash.solid, 4.0, nil),
        (.dashed, 4.0, [8.0, 12.0]),
        (.dashed, 8.0, [16.0, 24.0]),
        (.dotted, 4.0, [0.0, 8.0]),
    ] as [(LineDash, Double, [Double]?)])
    func dashPattern(dash: LineDash, width: Double, expected: [Double]?) {
        #expect(dash.pattern(width: width)?.map(Double.init) == expected)
    }

    // p projects onto the nearest 45° ray, keeping its length along the ray —
    // a near-horizontal drag keeps the pointer's x
    @Test(arguments: [
        (CGPoint(x: 10, y: 6), CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 5)),   // near-horizontal
        (CGPoint(x: 10, y: 9), .zero, CGPoint(x: 9.5, y: 9.5)),             // near-diagonal
        (CGPoint(x: 1, y: 10), .zero, CGPoint(x: 0, y: 10)),                // near-vertical
        (CGPoint(x: -10, y: 1), .zero, CGPoint(x: -10, y: 0)),              // negative x
        (CGPoint(x: -1, y: -10), .zero, CGPoint(x: 0, y: -10)),             // fourth quadrant
        (.zero, .zero, .zero),                                              // p == origin
    ])
    func snapAngle(p: CGPoint, origin: CGPoint, expected: CGPoint) {
        let r = PathGeometry.snapAngle(p, from: origin)
        #expect(abs(r.x - expected.x) < 1e-3 && abs(r.y - expected.y) < 1e-3)
    }

    // each end type puts ink where the tangent aims it, and nowhere else —
    // for a bent Line the tangent (u) is the curve's, not the chord's:
    // at the end ∝ (1,-2), at the start ∝ (-1,-2)
    @Test(arguments: [
        // (end, on the head (end point)?, bent?, inside offset in (u,n), outside offset)
        (LineEnd.filledArrow, true, false, (-4.0, 0.0), (4.0, 0.0)),
        (.filledArrow, true, true, (-4.0, 0.0), (4.0, 0.0)),
        (.filledArrow, false, true, (-4.0, 0.0), (4.0, 0.0)),
        (.openArrow, true, false, (-8.0 * cos(.pi / 6), 4.0), (-8.0 * cos(.pi / 6), 0.0)),
        (.openArrow, false, true, (-8.0 * cos(.pi / 6), -4.0), (-8.0 * cos(.pi / 6), 0.0)),
        (.bar, true, false, (0.0, 6.0), (-3.0, 0.0)),
        (.bar, true, true, (0.0, -6.0), (-3.0, 0.0)),
        (.dot, true, false, (0.0, 3.0), (0.0, 8.0)),
        (.dot, false, true, (0.0, 3.0), (0.0, 8.0)),
    ])
    func endMarks(end: LineEnd, head: Bool, bent: Bool,
                  inside: (Double, Double), outside: (Double, Double)) {
        var style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        if head { style.head = end } else { style.tail = end }
        let bend = bent ? CGPoint(x: 50, y: 50) : nil
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0), bend: bend),
                           style: style)
        // the tip and outward tangent at this end
        let tip = head ? CGPoint(x: 100, y: 0) : CGPoint.zero
        let u: CGPoint = bent
            ? (head ? CGPoint(x: 1 / 5.0.squareRoot(), y: -2 / 5.0.squareRoot())
                    : CGPoint(x: -1 / 5.0.squareRoot(), y: -2 / 5.0.squareRoot()))
            : (head ? CGPoint(x: 1, y: 0) : CGPoint(x: -1, y: 0))
        let n = CGPoint(x: -u.y, y: u.x)
        func pt(_ o: (Double, Double)) -> CGPoint {
            CGPoint(x: tip.x + CGFloat(o.0) * u.x + CGFloat(o.1) * n.x,
                    y: tip.y + CGFloat(o.0) * u.y + CGFloat(o.1) * n.y)
        }
        let ends = PathGeometry.drawing(for: a).ends
        #expect(ends.contains(pt(inside)))
        #expect(!ends.contains(pt(outside)))
    }

    // a Line with no ends draws no ends path
    @Test func noEndsIsEmpty() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4))
        #expect(PathGeometry.drawing(for: a).ends.isEmpty)
    }

    // a filled arrow trims the stroke back half its length (L/2 = 9 at w 4) so
    // the round cap can't poke past the tip
    @Test func filledArrowTrimsStroke() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4,
                                                  head: .filledArrow, tail: .filledArrow))
        let b = PathGeometry.drawing(for: a).stroke.boundingBoxOfPath
        #expect(abs(b.minX - 9) < 0.5 && abs(b.maxX - 91) < 0.5)
    }

    // a bent Line can double back past its tip, crossing the trim distance
    // twice — trim must keep the endpoint-side crossing. (0,0)→(100,0) bent at
    // (98,1) loops out to x≈111 before returning; the right crossing sits at
    // t≈0.863, x > 100, 9 pt from the tip — the wrong one lands at x≈91
    @Test func doubledBackHeadTrimsNearEnd() {
        var s = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        s.head = .filledArrow
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0),
                                     bend: CGPoint(x: 98, y: 1)), style: s)
        let end = PathGeometry.drawing(for: a).stroke.currentPoint
        #expect(abs(hypot(end.x - 100, end.y) - 9) < 0.5)
        #expect(end.x > 100)
    }

    // the mirrored bug at the start: bend (2,1) sweeps the curve out to x≈-11
    // and back past the start, crossing the trim distance twice; the
    // start-side crossing sits at x<0
    @Test func doubledBackTailTrimsNearStart() {
        var s = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        s.tail = .filledArrow
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0),
                                     bend: CGPoint(x: 2, y: 1)), style: s)
        var first: CGPoint?
        PathGeometry.drawing(for: a).stroke.applyWithBlock { e in
            if first == nil { first = e.pointee.points.pointee }
        }
        #expect(first != nil)
        #expect(abs(hypot(first!.x, first!.y) - 9) < 0.5)
        #expect(first!.x < 0)
    }

    // hit testing reaches the ends, not just the stroke body
    @Test func hitTestEnds() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4,
                                                  head: .filledArrow))
        #expect(PathGeometry.hitTest(a, at: CGPoint(x: 96, y: 0)))
        // inside the arrowhead but off the stroke body (4 > width/2)
        #expect(PathGeometry.hitTest(a, at: CGPoint(x: 92, y: 4)))
    }

    let tri = [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 100, y: 0)),
               PathNode(anchor: CGPoint(x: 50, y: 80))]

    // a closed path hit-tests inside only while its style fills it; the
    // outline always hits
    @Test func closedPathInteriorHit() {
        let red = RGBAColour(red: 1, green: 0, blue: 0, alpha: 1)
        let filled = Annotation(kind: .path(PathData(nodes: tri, closed: true)),
                                style: AnnotationStyle(colour: red, width: 4, fill: red))
        #expect(PathGeometry.hitTest(filled, at: CGPoint(x: 50, y: 30)))
        let unfilled = Annotation(kind: .path(PathData(nodes: tri, closed: true)),
                                  style: AnnotationStyle(colour: red, width: 4))
        #expect(!PathGeometry.hitTest(unfilled, at: CGPoint(x: 50, y: 30)))
        #expect(PathGeometry.hitTest(unfilled, at: CGPoint(x: 50, y: 0)))
    }

    // a closed path draws no ends even with head/tail set, and a fill path
    // only when the style fills
    @Test func closedPathDrawing() {
        let red = RGBAColour(red: 1, green: 0, blue: 0, alpha: 1)
        let filled = Annotation(kind: .path(PathData(nodes: tri, closed: true)),
                                style: AnnotationStyle(colour: red, width: 4,
                                                       head: .filledArrow, tail: .dot, fill: red))
        let d = PathGeometry.drawing(for: filled)
        #expect(d.ends.isEmpty && d.fill != nil && d.fill!.contains(CGPoint(x: 50, y: 30)))
        var unfilledStyle = filled.style
        unfilledStyle.fill = nil
        #expect(PathGeometry.drawing(for: Annotation(kind: filled.kind, style: unfilledStyle)).fill == nil)
        // an open path still takes ends
        var openStyle = filled.style
        openStyle.fill = nil
        let open = Annotation(kind: .path(PathData(nodes: tri)), style: openStyle)
        #expect(!PathGeometry.drawing(for: open).ends.isEmpty)
    }

    // `stroked` off drops a closed path's stroke like a shape's — its fill
    // still hit-tests inside; an open path ignores `stroked` and always hits
    @Test func unstrokedClosedPathFillsOnly() {
        let red = RGBAColour(red: 1, green: 0, blue: 0, alpha: 1)
        let closed = Annotation(kind: .path(PathData(nodes: tri, closed: true)),
                                style: AnnotationStyle(colour: red, width: 4,
                                                       fill: red, stroked: false))
        #expect(closed.strokeColour == nil)
        #expect(closed.fillColour == red)
        #expect(PathGeometry.hitTest(closed, at: CGPoint(x: 50, y: 30)))
        let open = Annotation(kind: .path(PathData(nodes: tri)),
                              style: closed.style)
        #expect(open.strokeColour == red)
        #expect(PathGeometry.hitTest(open, at: CGPoint(x: 50, y: 0)))
    }

    // an open path's end marks sit on the last segment's tangent: with
    // handleIn (100,-50) the tangent at (100,0) points +y — inside at T−4u is
    // (100,-4), where a chord-direction arrow would put nothing
    @Test func openPathEndTangent() {
        var style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        style.head = .filledArrow
        let a = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 100, y: -50)),
        ])), style: style)
        let ends = PathGeometry.drawing(for: a).ends
        #expect(ends.contains(CGPoint(x: 100, y: -4)))
        #expect(!ends.contains(CGPoint(x: 96, y: 0)))
    }

    // a freehand stroke ends in 1-pt integer steps: a diagonal Brush stroke
    // whose first and last samples step along an axis must still aim both
    // arrows along the stroke (±(1,1)/√2), not along that final step's axis
    @Test func freehandArrowsFollowTheStroke() {
        var style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        style.head = .filledArrow
        style.tail = .filledArrow
        let raw = [CGPoint(x: -1, y: 0)] + (0...60).map { CGPoint(x: $0, y: $0) } + [CGPoint(x: 61, y: 60)]
        let a = Annotation(kind: .path(PathData.fitted(raw, smoothing: 0.5)!), style: style)
        let ends = PathGeometry.drawing(for: a).ends
        let d = 12 / 2.0.squareRoot()
        // 12 pt back along the diagonal sits inside each head; 12 pt back along
        // the axis (where the old, axis-aimed head sat) falls outside
        #expect(ends.contains(CGPoint(x: 61 - d, y: 60 - d)))
        #expect(!ends.contains(CGPoint(x: 61 - 12, y: 60)))
        #expect(ends.contains(CGPoint(x: -1 + d, y: d)))
        #expect(!ends.contains(CGPoint(x: -1 + 12, y: 0)))
    }

    // a filled arrow's trim reaches past a last segment shorter than the trim:
    // the stroke stops L/2 = 9 pt from each tip, not 1 pt
    @Test func filledArrowTrimsAcrossSegments() {
        var style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        style.head = .filledArrow
        style.tail = .filledArrow
        let a = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: CGPoint(x: -1, y: 0)), PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 60, y: 60)), PathNode(anchor: CGPoint(x: 61, y: 60)),
        ])), style: style)
        let stroke = PathGeometry.drawing(for: a).stroke
        var first: CGPoint?
        stroke.applyWithBlock { e in
            if first == nil { first = e.pointee.points.pointee }
        }
        let end = stroke.currentPoint
        #expect(abs(hypot(end.x - 61, end.y - 60) - 9) < 0.5)
        #expect(first != nil)
        #expect(abs(hypot(first!.x + 1, first!.y) - 9) < 0.5)
    }

    // a stroke that curls inside the trim circle just before its tip: a
    // purely radial trim would cut the whole curl and leave the stem ending
    // ~8 pt from a head aimed along the curl. The stem must still reach the
    // head, at the head (tip (0,0)) and, reversed, at the tail
    @Test(arguments: [true, false])
    func curledEndKeepsStemOnTheHead(head: Bool) {
        var style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        if head { style.head = .filledArrow } else { style.tail = .filledArrow }
        let points = [CGPoint(x: 0, y: -20), CGPoint(x: 0, y: -9), CGPoint(x: -8, y: 0),
                      CGPoint(x: 4, y: 4), CGPoint(x: 0, y: 0)]
        let nodes = (head ? points : points.reversed()).map { PathNode(anchor: $0) }
        let d = PathGeometry.drawing(for: Annotation(kind: .path(PathData(nodes: nodes)), style: style))
        let body = d.stroke.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10)
        #expect(body.intersects(d.ends))
    }
}
