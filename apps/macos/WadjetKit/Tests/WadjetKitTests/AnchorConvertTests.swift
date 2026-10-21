import CoreGraphics
import Foundation
import Testing
@testable import WadjetKit

struct AnchorConvertTests {
    static let style = DrawCurveHandlesTests.style

    static func path(_ nodes: [PathNode], closed: Bool = false) -> Annotation {
        Annotation(kind: .path(PathData(nodes: nodes, closed: closed)), style: style)
    }

    static func nodes(_ a: Annotation?) -> [PathNode] {
        guard case let .path(d)? = a?.kind else { return [] }
        return d.nodes
    }

    static let near = DrawCurveHandlesTests.near

    // Proves ⌥-click on a smooth anchor retracts both its handles, leaving
    // the other nodes alone
    @Test func smoothAnchorTurnsCorner() {
        let a = DrawCurveHandlesTests.curve()
        let n = Self.nodes(a.convertingAnchor(1))
        #expect(n[1].handleIn == nil && n[1].handleOut == nil)
        #expect(n[1].anchor == CGPoint(x: 100, y: 0))
        #expect(n[0] == Self.nodes(a)[0] && n[2] == Self.nodes(a)[2])
    }

    // Proves ⌥-click on a corner anchor gives it symmetric handles along the
    // line through its neighbours, a sixth of that chord long
    @Test func cornerAnchorTurnsSmoothAlongItsNeighbours() {
        let a = Self.path([PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 100, y: 50)),
                           PathNode(anchor: CGPoint(x: 200, y: 0))])
        let n = Self.nodes(a.convertingAnchor(1))
        #expect(Self.near(n[1].handleIn, CGPoint(x: 100 - 200.0 / 6, y: 50)))
        #expect(Self.near(n[1].handleOut, CGPoint(x: 100 + 200.0 / 6, y: 50)))
        #expect(n[1].isSmooth)
        // a corner with broken handles turns smooth too
        let broken = Self.path([PathNode(anchor: .zero),
                                PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 70, y: -30),
                                         handleOut: CGPoint(x: 130, y: -30)),
                                PathNode(anchor: CGPoint(x: 200, y: 0))])
        #expect(Self.nodes(broken.convertingAnchor(1))[1].isSmooth)
    }

    // Proves an open path's end aims its handles at its one neighbour, and
    // a closed path's first anchor takes the last as its other neighbour
    @Test func endsAndClosedPathsFindTheirNeighbours() {
        let nodes = [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 90, y: 0)),
                     PathNode(anchor: CGPoint(x: 90, y: 90))]
        let open = Self.nodes(Self.path(nodes).convertingAnchor(0))
        #expect(Self.near(open[0].handleOut, CGPoint(x: 30, y: 0)))
        #expect(Self.near(open[0].handleIn, CGPoint(x: -30, y: 0)))
        let last = Self.nodes(Self.path(nodes).convertingAnchor(2))
        #expect(Self.near(last[2].handleIn, CGPoint(x: 90, y: 60)))
        let closed = Self.nodes(Self.path(nodes, closed: true).convertingAnchor(0))
        // neighbours (90, 90) and (90, 0): the chord runs straight down
        #expect(Self.near(closed[0].handleOut, CGPoint(x: 0, y: -15)))
        #expect(Self.near(closed[0].handleIn, CGPoint(x: 0, y: 15)))
    }

    // Proves two ⌥-clicks round-trip a corner to smooth and back
    @Test func convertingTwiceReturnsToACorner() {
        let a = Self.path([PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 100, y: 50)),
                           PathNode(anchor: CGPoint(x: 200, y: 0))])
        #expect(Self.nodes(a.convertingAnchor(1)?.convertingAnchor(1)) == Self.nodes(a))
    }

    // Proves kinds without convertible anchors, a lone node, and an index
    // past the path report nil so the press keeps its usual grip
    @Test func nothingToConvert() {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: Self.style)
        #expect(line.convertingAnchor(0) == nil)
        #expect(line.pullingHandles(0, to: CGPoint(x: 10, y: 10)) == nil)
        #expect(Self.path([PathNode(anchor: .zero)]).convertingAnchor(0) == nil)
        #expect(DrawCurveHandlesTests.curve().convertingAnchor(5) == nil)
    }

    // Proves a Shape converts as its outline path, in place on screen
    @Test func shapeConvertsAsItsOutline() throws {
        let rect = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 0, y: 0, width: 100, height: 60)),
                              style: Self.style)
        let converted = try #require(rect.convertingAnchor(0))
        let n = Self.nodes(converted)
        #expect(n.count == 4)
        #expect(n[0].isSmooth)
        let corners = Set(rect.outlinePath.anchorGrips.map { "\($0.at)" })
        #expect(Set(converted.anchorGrips.map { "\($0.at)" }) == corners)
    }

    // Proves ⌥-drag pulls the outgoing handle to the pointer and mirrors
    // the incoming one, Shift holds it at 45°, and a drag back onto the
    // anchor retracts both
    @Test func optionDragPullsSymmetricHandles() throws {
        let a = Self.path([PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 100, y: 0)),
                           PathNode(anchor: CGPoint(x: 200, y: 0))])
        let n = Self.nodes(a.pullingHandles(1, to: CGPoint(x: 130, y: 20)))
        #expect(n[1].handleOut == CGPoint(x: 130, y: 20))
        #expect(n[1].handleIn == CGPoint(x: 70, y: -20))
        let snapped = Self.nodes(a.pullingHandles(1, to: CGPoint(x: 130, y: 28), constrained: true))
        let out = try #require(snapped[1].handleOut)
        #expect(abs(abs(out.x - 100) - abs(out.y)) < 1e-6)
        #expect(Self.near(snapped[1].handleIn, CGPoint(x: 200 - out.x, y: -out.y)))
        let back = Self.nodes(a.pullingHandles(1, to: CGPoint(x: 100, y: 0)))
        #expect(back[1].handleIn == nil && back[1].handleOut == nil)
    }

    // Proves a rotated path keeps its rotation (the frame anything attached
    // to it resolves in) and every anchor stays put on screen, while a
    // pulled handle lands on the pointer
    @Test func rotatedPathKeepsItsFrame() throws {
        var a = Self.path([PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 100, y: 50)),
                           PathNode(anchor: CGPoint(x: 200, y: 0))])
        a.transform.rotation = .pi / 4
        let screen = a.anchorGrips.map(\.at)
        for edited in [a.convertingAnchor(1), a.convertingAnchor(0), a.pullingHandles(1, to: CGPoint(x: 40, y: 90))] {
            let e = try #require(edited)
            #expect(e.transform.rotation == .pi / 4)
            for (was, now) in zip(screen, e.anchorGrips.map(\.at)) { #expect(Self.near(now, was)) }
        }
        let pulled = try #require(a.pullingHandles(1, to: CGPoint(x: 40, y: 90)))
        #expect(Self.near(Self.nodes(pulled)[1].handleOut?.applying(pulled.affineTransform), CGPoint(x: 40, y: 90)))
    }

    // Proves converting or pulling a Brush stroke's anchor drops its raw
    // samples, so a later Smoothing change can't refit the edit away
    @Test func brushEditsDropTheSamples() throws {
        let raw = (0...40).map { CGPoint(x: CGFloat($0) * 5, y: 20 * sin(CGFloat($0) / 6)) }
        let brush = Annotation(kind: .path(try #require(PathData.fitted(raw, smoothing: 0.5))), style: Self.style)
        for edited in [brush.convertingAnchor(0), brush.pullingHandles(0, to: CGPoint(x: 10, y: 10))] {
            guard case let .path(d)? = edited?.kind else { Issue.record(); continue }
            #expect(d.rawPoints == nil)
            #expect(d.smoothing == nil)
        }
    }

    // Proves a press on the stroke (a quarter along the first segment)
    // activates the anchor it adds, whose curve handles then show
    @Test func addedPointBecomesTheActiveAnchor() throws {
        let a = DrawCurveHandlesTests.curve()
        let press = try #require(DrawCurveHandlesTests.press(a, CGPoint(x: 24.0625, y: -16.875), active: nil))
        guard case let .insert(inserted, i, _) = press else { Issue.record(); return }
        let active = try #require(DrawPress.activeAnchor(after: press, was: nil))
        #expect(active == i)
        #expect(inserted.activeTangentGrips(active).contains { $0.handle == .tangent(i, outgoing: true) })
    }
}
