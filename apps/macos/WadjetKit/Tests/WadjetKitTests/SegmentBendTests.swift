import CoreGraphics
import Foundation
import Testing
@testable import WadjetKit

struct SegmentBendTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    static func near(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) < e }

    static func bends(_ a: Annotation) -> [(handle: SelectionHandle, at: CGPoint)] {
        a.handles(.drawing, minExtent: 12, rotateOffset: 20).filter { if case .segmentBend = $0.handle { true } else { false } }
    }

    static func press(_ a: Annotation, _ p: CGPoint) -> DrawPress? {
        a.drawPress(at: p, radius: 6, tolerance: 4, minExtent: 12, rotateOffset: 20)
    }

    static func nodes(_ a: Annotation) -> [PathNode] {
        if case let .path(d) = a.kind { return d.nodes }
        return []
    }

    /// a straight Line from (0,0) to (200,0) with a point added at (100,0)
    static func splitLine() throws -> Annotation {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 200, y: 0)), style: style)
        return try #require(line.insertingNode(near: CGPoint(x: 100, y: 0))).annotation
    }

    // Proves Mia's report is fixed: once a point is added to a Line, each of
    // its two segments shows a bend grip at its own midpoint
    @Test func aLineWithAnAddedPointKeepsABendGripPerSegment() throws {
        let path = try Self.splitLine()
        let bends = Self.bends(path)
        #expect(bends.map(\.handle) == [.segmentBend(0), .segmentBend(1)])
        #expect(Self.near(bends[0].at, CGPoint(x: 50, y: 0)))
        #expect(Self.near(bends[1].at, CGPoint(x: 150, y: 0)))
    }

    // Proves dragging a segment's grip bends that segment alone: its midpoint
    // follows the drag, every anchor stays put, the other segment stays straight
    @Test func draggingAGripBendsOnlyItsSegment() throws {
        let path = try Self.splitLine()
        let bent = path.dragging(.segmentBend(1), from: CGPoint(x: 150, y: 0), to: CGPoint(x: 150, y: 30))
        #expect(Self.nodes(bent).map(\.anchor) == Self.nodes(path).map(\.anchor))
        let segs = bent.kind.segments
        #expect(segs[0].straight)
        #expect(!segs[1].straight)
        #expect(Self.near(segs[1].point(at: 0.5), CGPoint(x: 150, y: 30)))
        // the grip now sits on the bent curve, where the pointer let go
        #expect(Self.near(Self.bends(bent)[1].at, CGPoint(x: 150, y: 30)))
    }

    // Proves a segment drags back to straight within the Line's straighten
    // radius, and that a bend of an inserted point's segment stays smooth at
    // that point (Illustrator keeps smooth anchors smooth)
    @Test func dragsBackStraightAndKeepsSmoothNodesSmooth() throws {
        let path = try Self.splitLine()
        let bent = path.dragging(.segmentBend(0), from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 20))
        let back = bent.dragging(.segmentBend(0), from: CGPoint(x: 50, y: 20), to: CGPoint(x: 50, y: 1))
        #expect(back.kind.segments.allSatisfy { $0.straight })

        // a bent Line split at its middle: the new node is smooth
        let curve = Annotation(kind: .line(start: .zero, end: CGPoint(x: 200, y: 0), bend: CGPoint(x: 100, y: 40)),
                               style: Self.style)
        let split = try #require(curve.insertingNode(near: CGPoint(x: 100, y: 40))).annotation
        let mid = try #require(Self.bends(split).first { $0.handle == .segmentBend(0) }).at
        let edited = split.dragging(.segmentBend(0), from: mid, to: CGPoint(x: mid.x - 10, y: mid.y + 25))
        let n = Self.nodes(edited)[1]
        let hi = try #require(n.handleIn), ho = try #require(n.handleOut)
        let u = CGPoint(x: hi.x - n.anchor.x, y: hi.y - n.anchor.y), v = CGPoint(x: ho.x - n.anchor.x, y: ho.y - n.anchor.y)
        #expect(abs(u.x * v.y - u.y * v.x) / (hypot(u.x, u.y) * hypot(v.x, v.y)) < 1e-6)
        #expect(u.x * v.x + u.y * v.y < 0)
        // the other handle keeps its length
        let was = try #require(Self.nodes(split)[1].handleOut)
        #expect(abs(hypot(v.x, v.y) - hypot(was.x - n.anchor.x, was.y - n.anchor.y)) < 1e-6)
    }

    // Proves snapping a segment straight keeps a smooth join smooth: the
    // neighbour's handle turns onto the straight segment's line
    @Test func snappingStraightKeepsASmoothJoin() throws {
        let curve = Annotation(kind: .line(start: .zero, end: CGPoint(x: 200, y: 0), bend: CGPoint(x: 100, y: 40)),
                               style: Self.style)
        let split = try #require(curve.insertingNode(near: CGPoint(x: 100, y: 40))).annotation
        let mid = try #require(Self.bends(split).first { $0.handle == .segmentBend(0) }).at
        // the straight chord's midpoint is (50,20)
        let straight = split.dragging(.segmentBend(0), from: mid, to: CGPoint(x: 50, y: 20))
        #expect(straight.kind.segments[0].straight)
        let n = Self.nodes(straight)[1]
        let ho = try #require(n.handleOut)
        let u = CGPoint(x: n.anchor.x - 0, y: n.anchor.y - 0), v = CGPoint(x: ho.x - n.anchor.x, y: ho.y - n.anchor.y)
        #expect(abs(u.x * v.y - u.y * v.x) / (hypot(u.x, u.y) * hypot(v.x, v.y)) < 1e-6)
        #expect(u.x * v.x + u.y * v.y > 0)
        let was = try #require(Self.nodes(split)[1].handleOut)
        #expect(abs(hypot(v.x, v.y) - hypot(was.x - n.anchor.x, was.y - n.anchor.y)) < 1e-6)
    }

    // Proves a corner stays a corner: bending one segment of a corner node
    // leaves the other segment's handle where it was
    @Test func aCornerNodeStaysACorner() {
        let data = PathData(nodes: [
            PathNode(anchor: .zero, handleOut: CGPoint(x: 0, y: 40)),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 100, y: 40), handleOut: CGPoint(x: 140, y: 40)),
            PathNode(anchor: CGPoint(x: 200, y: 0)),
        ])
        let a = Annotation(kind: .path(data), style: Self.style)
        let bent = a.dragging(.segmentBend(0), from: .zero, to: CGPoint(x: 0, y: 30))
        #expect(Self.nodes(bent)[1].handleOut == CGPoint(x: 140, y: 40))
        #expect(Self.nodes(bent)[1].handleIn == CGPoint(x: 100, y: 80))
    }

    // Proves a closed path's closing segment gets a grip and bends like the rest
    @Test func theClosingSegmentBends() {
        let data = PathData(nodes: [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 100, y: 0)),
                                    PathNode(anchor: CGPoint(x: 100, y: 100))], closed: true)
        let a = Annotation(kind: .path(data), style: Self.style)
        let last = Self.bends(a).last
        #expect(last?.handle == .segmentBend(2))
        #expect(last.map { Self.near($0.at, CGPoint(x: 50, y: 50)) } == true)
        let bent = a.dragging(.segmentBend(2), from: CGPoint(x: 50, y: 50), to: CGPoint(x: 40, y: 60))
        #expect(Self.near(bent.kind.segments[2].point(at: 0.5), CGPoint(x: 40, y: 60)))
        #expect(bent.kind.segments[0].straight && bent.kind.segments[1].straight)
    }

    // Proves the grip and its drag work in screen space on a rotated path
    @Test func aRotatedPathBendsUnderThePointer() throws {
        var path = try Self.splitLine()
        path.transform.rotation = .pi / 2
        let grip = try #require(Self.bends(path).last)
        let to = CGPoint(x: grip.at.x + 20, y: grip.at.y)
        let bent = path.dragging(grip.handle, from: grip.at, to: to)
        let mid = try #require(Self.bends(bent).last).at
        #expect(Self.near(mid, to, 1e-4))
    }

    // Proves the press order: an anchor beats a nearer bend grip, a bend grip
    // beats the stroke under it, and the stroke (adding a point) beats a
    // frame grip sitting on it
    @Test func pressOrderAnchorsThenBendsThenStrokeThenFrame() throws {
        let short = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: .zero),
                                                            PathNode(anchor: CGPoint(x: 16, y: 0)),
                                                            PathNode(anchor: CGPoint(x: 16, y: 100))])),
                               style: Self.style)
        // minExtent 8 puts the first segment's grip at (8,0), 3.5 from the press
        #expect(short.drawPress(at: CGPoint(x: 4.5, y: 0), radius: 6, tolerance: 4, minExtent: 8, rotateOffset: 20)
            == .grip(.vertex(0)))

        let path = try Self.splitLine()
        #expect(Self.press(path, CGPoint(x: 52, y: 1)) == .grip(.segmentBend(0)))
        if case .insert? = Self.press(path, CGPoint(x: 75, y: 0)) {} else { Issue.record("expected a new node") }

        // the bottom edge's resize grip sits at (150,0), on the first segment,
        // which is 240 long so its own bend grip is 30 away
        let data = PathData(nodes: [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 240, y: 0)),
                                    PathNode(anchor: CGPoint(x: 240, y: 100)), PathNode(anchor: CGPoint(x: 300, y: 100))])
        let a = Annotation(kind: .path(data), style: Self.style)
        #expect(a.handle(at: CGPoint(x: 150, y: 0), radius: 6, minExtent: 12, rotateOffset: 20, set: .drawing)
            == .resize(x: 0, y: -1))
        if case .insert? = Self.press(a, CGPoint(x: 150, y: 0)) {} else { Issue.record("expected a new node") }
        // off the stroke, the frame grip still resizes
        #expect(Self.press(a, CGPoint(x: 0, y: 100)) == .grip(.resize(x: -1, y: 1)))
    }

    // Proves short segments get no grip: a dense Brush stroke shows grips
    // only where a segment is long enough to hold one clear of its anchors
    @Test func shortSegmentsGetNoGrip() throws {
        let raw = (0...200).map { CGPoint(x: CGFloat($0), y: 30 * sin(CGFloat($0) / 8)) }
        let data = try #require(PathData.fitted(raw, smoothing: 0.2))
        let brush = Annotation(kind: .path(data), style: Self.style)
        let anchors = brush.anchorGrips.map(\.at)
        for g in Self.bends(brush) {
            #expect(anchors.allSatisfy { hypot($0.x - g.at.x, $0.y - g.at.y) >= 12 })
        }
        let tiny = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 20, y: 0))])),
                              style: Self.style)
        #expect(Self.bends(tiny).isEmpty)
        // bending a Brush stroke's segment drops its samples, so a refit can't undo it
        if let g = Self.bends(brush).first {
            guard case let .path(d) = brush.dragging(g.handle, from: g.at, to: CGPoint(x: g.at.x, y: g.at.y + 10)).kind
            else { Issue.record(); return }
            #expect(d.rawPoints == nil && d.smoothing == nil)
        }
    }

    // Proves an arrow keeps aiming along its end after the last segment
    // bends (#193's aim): the head sits exactly as on a bent Line of the
    // same curve, turned off the old straight chord
    @Test func anArrowheadFollowsABentLastSegment() throws {
        var path = try Self.splitLine()
        path.style.head = .filledArrow
        let bent = path.dragging(.segmentBend(1), from: CGPoint(x: 150, y: 0), to: CGPoint(x: 150, y: 40))
        var line = Annotation(kind: .line(start: CGPoint(x: 100, y: 0), end: CGPoint(x: 200, y: 0),
                                          bend: CGPoint(x: 150, y: 40)), style: Self.style)
        line.style.head = .filledArrow
        let reach = PathGeometry.headLength(width: Self.style.width)
        let u = PathGeometry.endOutward(bent.kind.segments, reach: reach)
        let want = PathGeometry.endOutward(line.kind.segments, reach: reach)
        #expect(Self.near(u, want, 1e-6))
        #expect(u.y < -0.3)
        let head = PathGeometry.drawing(for: bent).ends.boundingBoxOfPath
        let lineHead = PathGeometry.drawing(for: line).ends.boundingBoxOfPath
        #expect(abs(head.minX - lineHead.minX) < 1e-6 && abs(head.minY - lineHead.minY) < 1e-6
            && abs(head.width - lineHead.width) < 1e-6 && abs(head.height - lineHead.height) < 1e-6)
    }

    // Proves Direct Select shows a bend grip per segment, and that an anchor
    // in reach takes the press before one
    @Test func directSelectShowsSegmentGrips() throws {
        let path = try Self.splitLine()
        var sel = NodeSelection()
        sel.show(path.id, adding: false)
        let chrome = DirectSelectChrome([path], selection: sel, inset: 12)
        #expect(chrome.grips.map(\.handle) == [.segmentBend(0), .segmentBend(1)])
        #expect(chrome.hit(at: CGPoint(x: 52, y: 0), radius: 6) == .grip(path.id, .segmentBend(0)))
        let short = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 16, y: 0))])),
                               style: Self.style)
        var s2 = NodeSelection()
        s2.show(short.id, adding: false)
        let tight = DirectSelectChrome([short], selection: s2, inset: 8)
        #expect(tight.hit(at: CGPoint(x: 4.5, y: 0), radius: 6) == .anchor(AnchorRef(id: short.id, index: 0)))
    }
}
