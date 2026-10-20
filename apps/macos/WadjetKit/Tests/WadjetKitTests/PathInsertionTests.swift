import CoreGraphics
import Foundation
import Testing
@testable import WadjetKit

struct PathInsertionTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    /// how far the furthest of `a`'s sampled stroke points sits from `b`'s stroke
    static func deviation(_ a: Annotation, from b: Annotation) -> CGFloat {
        func samples(_ x: Annotation, _ n: Int) -> [CGPoint] {
            x.kind.segments.flatMap { s in
                (0...n).map { k -> CGPoint in
                    let t = CGFloat(k) / CGFloat(n)
                    let p = s.straight
                        ? CGPoint(x: s.p0.x + (s.p3.x - s.p0.x) * t, y: s.p0.y + (s.p3.y - s.p0.y) * t)
                        : s.point(at: t)
                    return p.applying(x.affineTransform)
                }
            }
        }
        let dense = samples(b, 5000)
        return samples(a, 50).map { p in
            dense.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity
        }.max() ?? .infinity
    }

    // Proves a node added anywhere along a Line, a bent Line, a Pen curve, a
    // closed path's closing segment, or a rotated stroke lands on the stroke
    // and leaves its shape unchanged, both ways round
    @Test(arguments: [
        ("straight Line", AnnotationKind.line(start: .zero, end: CGPoint(x: 100, y: 0)),
         CGPoint(x: 30, y: 3), 0.0),
        ("bent Line", .line(start: .zero, end: CGPoint(x: 100, y: 0), bend: CGPoint(x: 50, y: 40)),
         CGPoint(x: 25, y: 30), 0.0),
        ("Pen curve", .path(PathData(nodes: [
            PathNode(anchor: .zero, handleOut: CGPoint(x: 0, y: 80)),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 100, y: 80)),
            PathNode(anchor: CGPoint(x: 150, y: 50))])),
         CGPoint(x: 60, y: 62), 0.0),
        ("closing segment", .path(PathData(nodes: [
            PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 100, y: 0)),
            PathNode(anchor: CGPoint(x: 100, y: 100), handleOut: CGPoint(x: 0, y: 150))], closed: true)),
         CGPoint(x: 30, y: 95), 0.0),
        ("rotated Line", .line(start: .zero, end: CGPoint(x: 100, y: 0), bend: CGPoint(x: 50, y: 30)),
         CGPoint(x: 40, y: 60), Double.pi / 3),
    ] as [(String, AnnotationKind, CGPoint, Double)])
    func keepsShape(_ name: String, kind: AnnotationKind, press: CGPoint, rotation: Double) throws {
        let a = Annotation(kind: kind, style: Self.style).rotated(by: rotation)
        let (b, i) = try #require(a.insertingNode(near: press), "\(name)")
        guard case let .path(d) = b.kind else { Issue.record("\(name) isn't a path"); return }
        #expect(d.nodes.count == a.kind.segments.count + (a.kind.isClosed ? 0 : 1) + 1, "\(name)")
        #expect(Self.deviation(a, from: b) < 0.05, "\(name)")
        #expect(Self.deviation(b, from: a) < 0.05, "\(name)")
        // the new node sits on the stroke, as close to the press as the stroke gets
        let node = d.nodes[i].anchor.applying(b.affineTransform)
        let onStroke = Annotation(kind: .line(start: node, end: node), style: Self.style)
        #expect(Self.deviation(onStroke, from: a) < 0.05, "\(name)")
    }

    // Proves a Line's ends survive the change to a path, so an arrow stays an arrow
    @Test func lineKeepsItsEnds() throws {
        var style = Self.style
        style.head = .filledArrow; style.tail = .dot
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let (b, i) = try #require(a.insertingNode(near: CGPoint(x: 40, y: 2)))
        #expect(i == 1)
        #expect(b.style == style)
        guard case let .path(d) = b.kind else { Issue.record("not a path"); return }
        #expect(d.nodes.map(\.anchor.x).map { ($0 * 1000).rounded() / 1000 } == [0, 40, 100])
        #expect(d.nodes.allSatisfy { $0.anchor.y == 0 && $0.handleIn == nil && $0.handleOut == nil })
    }

    // Proves a node added inside a filled arrowhead's trim leaves the drawn
    // arrow as it was: the stem still stops short of the tip, the head is the same
    @Test func nearEndInsertionKeepsTheArrow() throws {
        var style = Self.style
        style.width = 24
        style.head = .filledArrow
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let (b, _) = try #require(a.insertingNode(near: CGPoint(x: 93, y: 0)))
        let before = PathGeometry.drawing(for: a), after = PathGeometry.drawing(for: b)
        func same(_ r: CGRect, _ s: CGRect) -> Bool {
            abs(r.minX - s.minX) < 0.01 && abs(r.maxX - s.maxX) < 0.01 && abs(r.minY - s.minY) < 0.01 && abs(r.maxY - s.maxY) < 0.01
        }
        #expect(same(before.stroke.boundingBoxOfPath, after.stroke.boundingBoxOfPath))
        #expect(same(before.ends.boundingBoxOfPath, after.ends.boundingBoxOfPath))
    }

    // Proves a Brush stroke drops its samples, so the Smoothing slider can't
    // refit the new node away
    @Test func brushDropsSamples() throws {
        let raw = (0...20).map { CGPoint(x: CGFloat($0) * 5, y: sin(CGFloat($0) / 3) * 20) }
        let data = try #require(PathData.fitted(raw, smoothing: 0.5))
        let a = Annotation(kind: .path(data), style: Self.style)
        let (b, _) = try #require(a.insertingNode(near: CGPoint(x: 50, y: 0)))
        guard case let .path(d) = b.kind else { Issue.record("not a path"); return }
        #expect(d.rawPoints == nil && d.smoothing == nil)
        #expect(Self.deviation(a, from: b) < 0.05)
    }

    // Proves a press inside a filled closed path adds nothing — the body still
    // moves it — while a press on its stroke adds a node
    @Test func filledBodyIsNotTheStroke() {
        var style = Self.style
        style.fill = style.colour
        let square = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 200, y: 0)),
            PathNode(anchor: CGPoint(x: 200, y: 200)), PathNode(anchor: CGPoint(x: 0, y: 200))], closed: true)),
                                style: style)
        #expect(square.insertingNode(near: CGPoint(x: 40, y: 40), within: 4) == nil)
        #expect(square.insertingNode(near: CGPoint(x: 40, y: 3), within: 4)?.node == 1)
    }

    // Proves a press on an existing node, or on a kind without nodes, adds nothing
    @Test func nothingToAdd() {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: Self.style)
        #expect(line.insertingNode(near: CGPoint(x: 100, y: 1)) == nil)
        let rect = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 0, y: 0, width: 50, height: 50)),
                              style: Self.style)
        #expect(rect.insertingNode(near: CGPoint(x: 25, y: 0)) == nil)
    }
}
