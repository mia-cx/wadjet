import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct DirectSelectTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    static func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 1e-6 }

    static let curve = Annotation(kind: .path(PathData(nodes: [
        PathNode(anchor: .zero, handleOut: CGPoint(x: 0, y: 40)),
        PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 60, y: -40), handleOut: CGPoint(x: 140, y: 40)),
        PathNode(anchor: CGPoint(x: 200, y: 0)),
        PathNode(anchor: CGPoint(x: 300, y: 0), handleIn: CGPoint(x: 300, y: 40)),
    ])), style: style)

    // Proves Illustrator's click rules: a press selects an anchor alone,
    // Shift adds and toggles, and a press on an already-selected anchor keeps
    // the set so one drag carries them all
    @Test func pressRules() {
        let id = Self.curve.id
        let a0 = AnchorRef(id: id, index: 0), a2 = AnchorRef(id: id, index: 2)
        var s = NodeSelection()
        s.press(a0, adding: false)
        #expect(s.anchors == [a0] && s.shown == [id])
        s.press(a2, adding: true)
        #expect(s.anchors == [a0, a2])
        s.press(a0, adding: false)
        #expect(s.anchors == [a0, a2])
        s.press(a0, adding: true)
        #expect(s.anchors == [a2])
        s.press(a0, adding: false)
        #expect(s.anchors == [a0])
    }

    // Proves a marquee selects the anchors inside it across Annotations,
    // skips locked ones, and Shift adds to what was selected
    @Test func marqueeAcrossPaths() {
        let line = Annotation(kind: .line(start: CGPoint(x: 0, y: 100), end: CGPoint(x: 300, y: 100)), style: Self.style)
        var locked = Annotation(kind: .line(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 60, y: 60)), style: Self.style)
        locked.locked = true
        var s = NodeSelection()
        s.marquee(CGRect(x: -10, y: -10, width: 120, height: 120), in: [Self.curve, line, locked], adding: false)
        #expect(s.anchors == [AnchorRef(id: Self.curve.id, index: 0), AnchorRef(id: Self.curve.id, index: 1),
                              AnchorRef(id: line.id, index: 0)])
        #expect(Set(s.shown) == [Self.curve.id, line.id])
        s.marquee(CGRect(x: 290, y: -10, width: 20, height: 20), in: [Self.curve, line], adding: true)
        #expect(s.anchors.count == 4)
        s.marquee(CGRect(x: 1000, y: 1000, width: 1, height: 1), in: [Self.curve, line], adding: false)
        #expect(s.isEmpty)
    }

    // Proves bezier handles show only on selected anchors and their
    // neighbours, and anchors draw filled only once selected
    @Test func handlesOnlyNearSelection() {
        var s = NodeSelection()
        s.press(AnchorRef(id: Self.curve.id, index: 3), adding: false)
        let chrome = DirectSelectChrome([Self.curve], selection: s, inset: 8)
        #expect(chrome.anchors.map(\.selected) == [false, false, false, true])
        #expect(Set(chrome.grips.map(\.handle)) == [.tangent(3, outgoing: false)])
        s.press(AnchorRef(id: Self.curve.id, index: 0), adding: false)
        let first = DirectSelectChrome([Self.curve], selection: s, inset: 8)
        #expect(Set(first.grips.map(\.handle)) == [.tangent(0, outgoing: true), .tangent(1, outgoing: false),
                                                    .tangent(1, outgoing: true)])
    }

    // Proves moving selected anchors carries their handles and leaves the
    // rest, and a Line's two ends together move the whole Line
    @Test func movingAnchors() throws {
        let moved = Self.curve.movingAnchors([1], by: CGVector(dx: 5, dy: 10))
        guard case let .path(d) = moved.kind else { Issue.record(); return }
        #expect(Self.near(d.nodes[1].anchor, CGPoint(x: 105, y: 10)))
        #expect(Self.near(d.nodes[1].handleIn!, CGPoint(x: 65, y: -30)))
        #expect(Self.near(d.nodes[0].anchor, .zero) && Self.near(d.nodes[2].anchor, CGPoint(x: 200, y: 0)))
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 0), bend: CGPoint(x: 5, y: 5)),
                              style: Self.style)
        #expect(line.movingAnchors([0, 1], by: CGVector(dx: 1, dy: 1)).kind
                == .line(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 11, y: 1), bend: CGPoint(x: 6, y: 6)))
    }

    // Proves dragging a Shape's vertex reshapes it into a path that keeps
    // every other vertex where it was on screen, even rotated
    @Test func shapeVertexBecomesPath() throws {
        let tri = Annotation(kind: .shape(.polygon(sides: 3), rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                             style: Self.style).rotated(by: 0.4)
        let before = tri.anchors
        let moved = tri.movingAnchors([1], by: CGVector(dx: 20, dy: 0))
        guard case .path = moved.kind else { Issue.record("still a shape"); return }
        let after = moved.anchors
        #expect(after.count == before.count)
        #expect(Self.near(after[0], before[0]) && Self.near(after[2], before[2]))
        #expect(Self.near(after[1], CGPoint(x: before[1].x + 20, y: before[1].y)))
    }

    // Proves Delete joins the neighbours across removed anchors, and drops an
    // Annotation left with too few to draw
    @Test func removingAnchors() throws {
        let r = try #require(Self.curve.removingAnchors([1, 2]))
        guard case let .path(d) = r.kind else { Issue.record(); return }
        #expect(d.nodes.map(\.anchor) == [.zero, CGPoint(x: 300, y: 0)])
        #expect(Self.curve.removingAnchors([0, 1, 2]) == nil)
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 0)), style: Self.style)
        #expect(line.removingAnchors([0]) == nil)
    }

    // Proves two curved anchors left of a closed filled ellipse still close
    // and fill, while two corner anchors left of a square open into a line
    @Test func twoAnchorsStayClosedOnlyIfCurved() throws {
        var style = Self.style
        style.fill = style.colour
        let ellipse = Annotation(kind: .shape(.ellipse, rect: CGRect(x: 0, y: 0, width: 100, height: 60)), style: style)
        let kept = try #require(ellipse.removingAnchors([1, 3]))
        guard case let .path(d) = kept.kind else { Issue.record(); return }
        #expect(d.nodes.count == 2 && d.closed && kept.fillColour != nil)
        let square = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 0, y: 0, width: 50, height: 50)),
                                style: style)
        guard case let .path(s)? = square.removingAnchors([1, 3])?.kind else { Issue.record(); return }
        #expect(s.nodes.count == 2 && !s.closed)
    }

    // Proves locking or hiding a layer drops its anchors from Direct Select,
    // and keeps the selection on the others
    @Test func pruneDropsLockedAndHidden() {
        var other = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 10)), style: Self.style)
        var s = NodeSelection()
        s.marquee(CGRect(x: -1, y: -1, width: 400, height: 50), in: [Self.curve, other], adding: false)
        other.locked = true
        s.prune(to: [Self.curve, other])
        #expect(s.shown == [Self.curve.id] && s.anchors.allSatisfy { $0.id == Self.curve.id } && !s.anchors.isEmpty)
        var hidden = Self.curve
        hidden.hidden = true
        s.prune(to: [hidden, other])
        #expect(s.isEmpty)
    }

    // Proves ⌥ on a smooth node's handle breaks it into a corner, while a
    // plain drag keeps the opposite handle collinear
    @Test func optionBreaksHandle() {
        let from = CGPoint(x: 140, y: 40), to = CGPoint(x: 100, y: 60)
        guard case let .path(smooth) = Self.curve.dragging(.tangent(1, outgoing: true), from: from, to: to).kind,
              case let .path(broken) = Self.curve.dragging(.tangent(1, outgoing: true), from: from, to: to,
                                                            breaking: true).kind
        else { Issue.record(); return }
        #expect(Self.near(broken.nodes[1].handleIn!, CGPoint(x: 60, y: -40)))
        #expect(!Self.near(smooth.nodes[1].handleIn!, CGPoint(x: 60, y: -40)))
        #expect(Self.near(smooth.nodes[1].handleOut!, to) && Self.near(broken.nodes[1].handleOut!, to))
    }

    // Proves a press on a curved segment ((250,15) at t = ½) finds the two anchors it joins, and a
    // press off the stroke finds none
    @Test func segmentHit() {
        #expect(Self.curve.segment(at: CGPoint(x: 250, y: 16), tolerance: 2)?.anchors == [2, 3])
        #expect(Self.curve.segment(at: CGPoint(x: 250, y: 40), tolerance: 2) == nil)
    }

    // Proves the corner widget rounds a rectangle by the drag's inward
    // distance, clamped to half the shorter side, and the rect stays put
    @Test(arguments: [(CGFloat(10), CGFloat(10)), (-50, 0), (200, 40)])
    func cornerRadius(inward: CGFloat, expected: CGFloat) throws {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 80)
        let a = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: rect), style: Self.style)
        let w = try #require(a.cornerWidget(inset: 8))
        #expect(Self.near(w, CGPoint(x: 8, y: 72)))
        let r = a.dragging(.cornerRadius, from: w, to: CGPoint(x: w.x + inward, y: w.y - inward))
        #expect(r.kind == .shape(.rectangle(cornerRadius: expected), rect: rect))
    }
}
