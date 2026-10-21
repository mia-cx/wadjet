import CoreGraphics
import Foundation
import Testing
@testable import WadjetKit

struct DrawCurveHandlesTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    /// three nodes: node 1 is smooth, its handles opposite through (100, 0)
    static func curve(closed: Bool = false) -> Annotation {
        Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero, handleIn: CGPoint(x: -20, y: 20), handleOut: CGPoint(x: 30, y: -30)),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 70, y: -30),
                     handleOut: CGPoint(x: 130, y: 30)),
            PathNode(anchor: CGPoint(x: 200, y: 0), handleIn: CGPoint(x: 170, y: 30),
                     handleOut: CGPoint(x: 220, y: -20)),
        ], closed: closed)), style: style)
    }

    static func press(_ a: Annotation, _ p: CGPoint, active: Int?) -> DrawPress? {
        a.drawPress(at: p, radius: 6, tolerance: 4, minExtent: 12, rotateOffset: 20, active: active)
    }

    static func near(_ a: CGPoint?, _ b: CGPoint) -> Bool {
        guard let a else { return false }
        return hypot(a.x - b.x, a.y - b.y) < 1e-4
    }

    // Proves the active anchor shows its own two handles and the far handle
    // of each segment it joins, as Illustrator does, and no others
    @Test func activeAnchorShowsItsHandlesAndTheAdjacentSegmentEnds() {
        let a = Self.curve()
        #expect(a.activeTangentGrips(1).map(\.handle) == [.tangent(0, outgoing: true), .tangent(1, outgoing: false),
                                                         .tangent(1, outgoing: true), .tangent(2, outgoing: false)])
        // an open path's end joins one segment
        #expect(a.activeTangentGrips(0).map(\.handle) == [.tangent(0, outgoing: false), .tangent(0, outgoing: true),
                                                         .tangent(1, outgoing: false)])
        // a closed path wraps
        #expect(Self.curve(closed: true).activeTangentGrips(0).map(\.handle)
            == [.tangent(2, outgoing: true), .tangent(0, outgoing: false),
                .tangent(0, outgoing: true), .tangent(1, outgoing: false)])
        #expect(a.activeTangentGrips(nil).isEmpty)
        #expect(a.activeTangentGrips(9).isEmpty)
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: Self.style)
        #expect(line.activeTangentGrips(0).isEmpty)
    }

    // Proves curve handles show and take presses only around the active
    // anchor, and that they rank after anchors but before bend grips
    @Test func handlesShowOnlyAroundTheActiveAnchor() {
        let a = Self.curve()
        let handle = CGPoint(x: 130, y: 30)
        #expect(!a.handles(.drawing, minExtent: 12, rotateOffset: 20)
            .contains { if case .tangent = $0.handle { true } else { false } })
        #expect(Self.press(a, handle, active: nil) != .grip(.tangent(1, outgoing: true)))
        #expect(Self.press(a, handle, active: 1) == .grip(.tangent(1, outgoing: true)))
        // the handle sits in reach of the press, but the anchor still wins
        let anchored = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero, handleOut: CGPoint(x: 4, y: 0)),
            PathNode(anchor: CGPoint(x: 100, y: 0)),
        ])), style: Self.style)
        #expect(Self.press(anchored, CGPoint(x: 3, y: 0), active: 0) == .grip(.vertex(0)))
        // a handle beats a bend grip it sits on
        #expect(SelectionHandle.tangent(0, outgoing: true).drawingRank < SelectionHandle.segmentBend(0).drawingRank)
        #expect(SelectionHandle.vertex(0).drawingRank < SelectionHandle.tangent(0, outgoing: true).drawingRank)
    }

    // Proves a press on an anchor activates it, a handle or bend press keeps
    // it, and any other press clears it
    @Test func pressesSetAndClearTheActiveAnchor() {
        let insert = DrawPress.insert(Self.curve(), node: 1, t: 0.5)
        #expect(DrawPress.activeAnchor(after: .grip(.vertex(2)), was: nil) == 2)
        #expect(DrawPress.activeAnchor(after: .grip(.vertex(0)), was: 2) == 0)
        #expect(DrawPress.activeAnchor(after: .grip(.tangent(1, outgoing: true)), was: 1) == 1)
        #expect(DrawPress.activeAnchor(after: .grip(.segmentBend(0)), was: 1) == 1)
        #expect(DrawPress.activeAnchor(after: insert, was: 1) == nil)
        #expect(DrawPress.activeAnchor(after: .grip(.resize(x: 1, y: 1)), was: 1) == nil)
        #expect(DrawPress.activeAnchor(after: nil, was: 1) == nil)
    }

    // Proves a smooth anchor's handles stay collinear while one drags, and
    // ⌥ (`breaking`) leaves the opposite handle where it was
    @Test func smoothHandlesStayCollinearUnlessBroken() {
        let a = Self.curve(), from = CGPoint(x: 130, y: 30), to = CGPoint(x: 100, y: 50)
        guard case let .path(smooth) = a.dragging(.tangent(1, outgoing: true), from: from, to: to).kind,
              case let .path(broken) = a.dragging(.tangent(1, outgoing: true), from: from, to: to, breaking: true).kind
        else { Issue.record(); return }
        #expect(Self.near(smooth.nodes[1].handleOut, CGPoint(x: 100, y: 50)))
        // straight up from the anchor, at the old 42.43 length
        #expect(Self.near(smooth.nodes[1].handleIn, CGPoint(x: 100, y: -hypot(30, 30))))
        #expect(Self.near(broken.nodes[1].handleIn, CGPoint(x: 70, y: -30)))
    }

    // Proves a corner anchor's handles move independently: dragging one
    // leaves the other alone, as Illustrator does
    @Test func cornerHandlesMoveAlone() {
        let a = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 70, y: -30),
                     handleOut: CGPoint(x: 130, y: -30)),
            PathNode(anchor: CGPoint(x: 200, y: 0)),
        ])), style: Self.style)
        guard case let .path(d) = a.dragging(.tangent(1, outgoing: true), from: CGPoint(x: 130, y: -30),
                                             to: CGPoint(x: 140, y: 20)).kind
        else { Issue.record(); return }
        #expect(Self.near(d.nodes[1].handleOut, CGPoint(x: 140, y: 20)))
        #expect(Self.near(d.nodes[1].handleIn, CGPoint(x: 70, y: -30)))
    }

    // Proves dragging a Brush stroke's curve handle drops its raw samples, so
    // a later Smoothing change can't refit the edit away
    @Test func brushHandleEditDropsTheSamples() throws {
        let raw = (0...40).map { CGPoint(x: CGFloat($0) * 5, y: 20 * sin(CGFloat($0) / 6)) }
        let data = try #require(PathData.fitted(raw, smoothing: 0.5))
        let brush = Annotation(kind: .path(data), style: Self.style)
        let grip = try #require(brush.activeTangentGrips(0).first)
        let moved = brush.dragging(grip.handle, from: grip.at, to: CGPoint(x: grip.at.x, y: grip.at.y + 10))
        guard case let .path(d) = moved.kind else { Issue.record(); return }
        #expect(d.rawPoints == nil)
        #expect(d.smoothing == nil)
    }

    // Proves a handle edit on a path attached whole, stored the way the Draw
    // Tool stores it, keeps the other anchors and the dragged handle where
    // the drag left them, and the path stays attached
    @Test func handleEditOnAWholeAttachedPathStaysPut() throws {
        let target = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 300, y: 0, width: 20, height: 20)),
                                style: Self.style)
        let path = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero, handleOut: CGPoint(x: 0, y: 100)),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 100, y: 100)),
        ])), style: Self.style)
        var stack = LayerStack([target, path])
        stack.attach(path.id, .whole, to: target.id, at: .frame(.zero))
        let start = try #require(stack.annotations.first { $0.id == path.id })
        stack.replaceRebasing(start.dragging(.tangent(0, outgoing: true), from: CGPoint(x: 0, y: 100),
                                             to: CGPoint(x: 0, y: 200)))
        let a = try #require(stack.annotations.first { $0.id == path.id })
        guard case let .path(d) = a.kind else { Issue.record(); return }
        let m = a.affineTransform
        #expect(Self.near(d.nodes[0].anchor.applying(m), .zero))
        #expect(Self.near(d.nodes[1].anchor.applying(m), CGPoint(x: 100, y: 0)))
        #expect(Self.near(d.nodes[0].handleOut?.applying(m), CGPoint(x: 0, y: 200)))
        #expect(a.attachments.contains { $0.point == .whole })
    }
}
