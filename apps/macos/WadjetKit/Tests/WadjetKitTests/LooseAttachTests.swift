import Testing
import Foundation
import WadjetKit

struct LooseAttachTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    func box(_ r: CGRect = CGRect(x: 0, y: 0, width: 100, height: 50)) -> Annotation {
        Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: r), style: red4)
    }
    func near(_ a: CGPoint?, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool {
        guard let a else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= tolerance
    }
    func current(_ stack: LayerStack, _ id: Annotation.ID) -> Annotation {
        stack.annotations.first { $0.id == id }!
    }

    // Proves where a loose end stops: on the line from the target's centre
    // toward where its Line comes from, at the outline. Worked by hand on a
    // 100 × 50 box centred on (50, 25), the same box turned 90° (25…75 ×
    // −25…75), and a 100 × 100 ellipse centred on (50, 50).
    @Test func endStopsOnTheOutline() {
        let ellipse = Annotation(kind: .shape(.ellipse, rect: CGRect(x: 0, y: 0, width: 100, height: 100)), style: red4)
        let r = 50 / 2.0.squareRoot()
        let rows: [(String, Annotation, CGPoint, CGPoint, CGFloat)] = [
            ("from the right", box(), CGPoint(x: 250, y: 25), CGPoint(x: 100, y: 25), 1e-6),
            ("from below", box(), CGPoint(x: 50, y: -75), CGPoint(x: 50, y: 0), 1e-6),
            ("through the corner", box(), CGPoint(x: 150, y: 75), CGPoint(x: 100, y: 50), 1e-6),
            ("from inside", box(), CGPoint(x: 60, y: 30), CGPoint(x: 50, y: 25), 1e-6),
            ("turned", box().rotated(by: .pi / 2), CGPoint(x: 250, y: 25), CGPoint(x: 75, y: 25), 1e-6),
            // the ellipse's curves are flattened, so allow a little
            ("ellipse diagonal", ellipse, CGPoint(x: 150, y: 150), CGPoint(x: 50 + r, y: 50 + r), 0.1),
        ]
        for (name, target, origin, want, tolerance) in rows {
            let got = AttachFinder.looseEnd(from: origin, on: target)
            #expect(near(got, want, tolerance), "\(name): \(got)")
        }
    }

    // Proves a loosely attached Line end keeps aiming at its target's centre
    // and stays on the outline as the target moves, resizes and turns, while
    // the free start stays put. The Line comes from (300, 25).
    @Test func endFollowsLoosely() {
        let target = box()
        let edits: [(String, (Annotation) -> Annotation, CGPoint)] = [
            ("attach", { $0 }, CGPoint(x: 100, y: 25)),
            // centre (50, 125): toward (300, 25) it leaves the right edge at y 105
            ("move", { $0.moved(by: CGVector(dx: 0, dy: 100)) }, CGPoint(x: 100, y: 105)),
            // 200 × 100, centre (100, 50): toward (300, 25) it leaves at (200, 37.5)
            ("resize", { $0.dragging(.resize(x: 1, y: 1), from: CGPoint(x: 100, y: 50),
                                     to: CGPoint(x: 200, y: 100)) }, CGPoint(x: 200, y: 37.5)),
            ("rotate", { $0.rotated(by: .pi / 2) }, CGPoint(x: 75, y: 25)),
        ]
        for (name, edit, want) in edits {
            let line = Annotation(kind: .line(start: CGPoint(x: 300, y: 25), end: CGPoint(x: 40, y: 30)), style: red4)
            var stack = LayerStack([target, line])
            let attached = stack.attach(line.id, .end, to: target.id, at: .frame(.zero), loose: true)
            #expect(attached)
            stack.replace(edit(target))
            #expect(near(current(stack, line.id).position(of: .end), want), "\(name)")
            #expect(near(current(stack, line.id).position(of: .start), CGPoint(x: 300, y: 25)), "\(name): start stays")
        }
    }

    // Proves a Line with both ends loose between two boxes runs centre to
    // centre and stops at both outlines, that a path's loose end aims from
    // the node next to it, and that solving again moves nothing, so a no-op
    // edit records no undo step.
    @Test func endsAimFromTheirNeighbour() {
        let a = box(), b = box(CGRect(x: 300, y: 0, width: 100, height: 50))
        let line = Annotation(kind: .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 320, y: 40)), style: red4)
        let path = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: CGPoint(x: 0, y: 300)),
                                                           PathNode(anchor: CGPoint(x: 50, y: 200)),
                                                           PathNode(anchor: CGPoint(x: 60, y: 30))])), style: red4)
        var stack = LayerStack([a, b, line, path])
        stack.attach(line.id, .start, to: a.id, at: .frame(.zero), loose: true)
        stack.attach(line.id, .end, to: b.id, at: .frame(.zero), loose: true)
        stack.attach(path.id, .end, to: a.id, at: .frame(.zero), loose: true)
        #expect(near(current(stack, line.id).position(of: .start), CGPoint(x: 100, y: 25)))
        #expect(near(current(stack, line.id).position(of: .end), CGPoint(x: 300, y: 25)))
        // from (50, 200) straight down to the centre (50, 25): the top edge
        #expect(near(current(stack, path.id).position(of: .end), CGPoint(x: 50, y: 50)))
        let settled = stack
        stack.replace(current(stack, a.id))
        #expect(stack == settled)
    }

    // Proves only a Line's or path's end attaches loosely: a bend or a whole
    // Annotation is refused and left unattached.
    @Test func onlyEndsAttachLoosely() {
        let target = box(), line = Annotation(kind: .line(start: CGPoint(x: 300, y: 25), end: .zero), style: red4)
        var stack = LayerStack([target, line])
        let bend = stack.attach(line.id, .bend, to: target.id, at: .frame(.zero), loose: true)
        let whole = stack.attach(line.id, .whole, to: target.id, at: .frame(.zero), loose: true)
        #expect(!bend && !whole)
        #expect(current(stack, line.id).attachments.isEmpty)
    }

    // Proves the drag tells loose from exact: deep inside a box the end
    // attaches loosely; near a spot it snaps exactly; with snapping off (⌘)
    // even a spot gives a loose drop, but just outside the stroke doesn't;
    // inside a closed path counts; a bend inside attaches nothing loose.
    @Test func hoverPicksTheMode() {
        let target = box(), line = Annotation(kind: .line(start: CGPoint(x: 300, y: 25), end: .zero), style: red4)
        let stack = LayerStack([target, line])
        let inside = AttachFinder.hover(at: CGPoint(x: 40, y: 20), in: stack, attaching: line.id, .end, radius: 8)
        #expect(inside?.loose == true && inside?.snapped == nil)
        let corner = AttachFinder.hover(at: CGPoint(x: 98, y: 48), in: stack, attaching: line.id, .end, radius: 8)
        #expect(corner?.loose == false && corner?.snapped != nil)
        let unsnapped = AttachFinder.hover(at: CGPoint(x: 98, y: 48), in: stack, attaching: line.id, .end,
                                           radius: 8, snapping: false)
        #expect(unsnapped?.loose == true && unsnapped?.snapped == nil)
        let outside = AttachFinder.hover(at: CGPoint(x: 104, y: 25), in: stack, attaching: line.id, .end,
                                         radius: 8, snapping: false)
        #expect(outside?.loose != true)
        let loop = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: CGPoint(x: 200, y: 0)),
                                                           PathNode(anchor: CGPoint(x: 300, y: 0)),
                                                           PathNode(anchor: CGPoint(x: 250, y: 100))], closed: true)),
                              style: red4)
        let withLoop = LayerStack([loop, line])
        let inLoop = AttachFinder.hover(at: CGPoint(x: 250, y: 40), in: withLoop, attaching: line.id, .end, radius: 8)
        #expect(inLoop?.loose == true)
        let bend = AttachFinder.hover(at: CGPoint(x: 40, y: 20), in: stack, attaching: line.id, .bend, radius: 8)
        #expect(bend?.loose == false)
    }
}
