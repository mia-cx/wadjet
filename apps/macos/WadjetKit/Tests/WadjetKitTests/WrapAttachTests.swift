import Testing
import Foundation
import WadjetKit

/// An exactly attached end wraps around its target, as Excalidraw's and
/// tldraw's arrows do: it keeps its spot while the Line can reach it from
/// outside, and slides to the side facing the Line's other end once the
/// target moves round to put the spot on its far side.
struct WrapAttachTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    /// a box shaped like a one-line Text: 200 × 24, its left edge at `x`, centred on y = `y`
    func strip(x: CGFloat, y: CGFloat = 0) -> CGRect { CGRect(x: x, y: y - 12, width: 200, height: 24) }
    func box(_ r: CGRect) -> Annotation { Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: r), style: red4) }
    func current(_ stack: LayerStack, _ id: Annotation.ID) -> Annotation { stack.annotations.first { $0.id == id }! }
    func near(_ a: CGPoint?, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool {
        guard let a else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= tolerance
    }
    /// how far the segment `a`→`b` reaches inside `r`, sampled
    func depth(_ a: CGPoint, _ b: CGPoint, in r: CGRect) -> CGFloat {
        (0...2000).map { k -> CGFloat in
            let t = CGFloat(k) / 2000, p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            guard r.contains(p) else { return 0 }
            return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
        }.max() ?? 0
    }
    /// a Line from `start`, its end attached exactly to the strip's left-edge middle, then the strip moved to `r`
    func attachedEnd(from start: CGPoint, stripAt r: CGRect) -> (LayerStack, Annotation.ID, Annotation.ID) {
        let target = box(strip(x: 100)), line = Annotation(kind: .line(start: start, end: .zero), style: red4)
        var stack = LayerStack([target, line])
        stack.attach(line.id, .end, to: target.id, at: .frame(CGPoint(x: 0, y: 0.5)))
        stack.replace(box(r).withID(target.id))
        return (stack, line.id, target.id)
    }

    // Proves the spot holds while the Line reaches it from outside: from the
    // left, from above-left, and from below-left of the strip's left edge.
    @Test func keepsItsSpotWhileFacing() {
        for start in [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 200), CGPoint(x: 90, y: -300)] {
            let (stack, line, _) = attachedEnd(from: start, stripAt: strip(x: 100))
            #expect(near(current(stack, line).position(of: .end), CGPoint(x: 100, y: 0)), "\(start)")
        }
    }

    // Proves the case Mia hit: the strip moved to the far side of the Line's
    // start. The end leaves the left edge for the right edge's middle, the
    // side facing the start, and the Line no longer runs through the strip.
    @Test func wrapsToTheFacingSide() {
        let r = strip(x: -300), (stack, line, _) = attachedEnd(from: .zero, stripAt: r)
        let end = current(stack, line).position(of: .end)!
        #expect(near(end, CGPoint(x: -100, y: 0), 0.01), "\(end)")
        #expect(depth(.zero, end, in: r) < 0.01)
    }

    // Proves the end is never on the strip's far side: with the strip
    // circling the start one degree at a time, the Line reaches at most a
    // couple of points into it, and never once the start is clear of it.
    @Test func neverOnTheFarSide() {
        for deg in 0..<360 {
            let a = CGFloat(deg) * .pi / 180, c = CGPoint(x: 250 * cos(a), y: 250 * sin(a))
            let r = CGRect(x: c.x - 100, y: c.y - 12, width: 200, height: 24)
            let (stack, line, _) = attachedEnd(from: .zero, stripAt: r)
            let end = current(stack, line).position(of: .end)!
            #expect(depth(.zero, end, in: r) <= 2, "\(deg)°: \(end)")
            // the start right of the strip: the end has left the strip's left edge
            if r.maxX < 0 { #expect(end.x > r.minX + 1, "\(deg)°: \(end)") }
        }
    }

    // Proves the end slides rather than jumps: moving the strip 1 pt at a
    // time across the point where its left edge turns away from the start
    // (from 100 pt above it, and from 40 pt), and round the start 1 pt at a
    // time, the end never moves more than a few points per step. Round the
    // start it moves fastest where the Line meets the strip's long edge at a
    // glancing angle, as a loose end does.
    @Test func slidesWithoutJumping() {
        for height in [CGFloat(100), 40] {
            var last: CGPoint?
            for x in stride(from: CGFloat(40), through: -240, by: -1) {
                let (stack, line, _) = attachedEnd(from: CGPoint(x: 0, y: height), stripAt: strip(x: x))
                let end = current(stack, line).position(of: .end)!
                if let last { #expect(hypot(end.x - last.x, end.y - last.y) <= 4, "\(height) x \(x): \(last) → \(end)") }
                last = end
            }
        }
        var last: CGPoint?
        let radius: CGFloat = 250, steps = Int((2 * .pi * radius).rounded())
        for k in 0...steps {
            let a = CGFloat(k) / radius, c = CGPoint(x: radius * cos(a), y: radius * sin(a))
            let (stack, line, _) = attachedEnd(from: .zero, stripAt: CGRect(x: c.x - 100, y: c.y - 12,
                                                                            width: 200, height: 24))
            let end = current(stack, line).position(of: .end)!
            if let last { #expect(hypot(end.x - last.x, end.y - last.y) <= 6, "step \(k): \(last) → \(end)") }
            last = end
        }
    }

    // Proves a far-off neighbour still sees the strip: from 3200 pt above,
    // an end on the bottom edge's middle moves to the top edge, though the
    // segment spends only 24 of its 3200 pt inside.
    @Test func farNeighbourStillWraps() {
        let r = CGRect(x: 0, y: 0, width: 200, height: 24)
        let end = AttachFinder.exactEnd(at: CGPoint(x: 100, y: 0), from: CGPoint(x: 100, y: 3200), on: box(r))
        #expect(near(end, CGPoint(x: 100, y: 24), 0.01), "\(end)")
    }

    // Proves a thin target gives way all the way: an 8 pt strip whose left
    // edge's middle faces away from a neighbour level with it puts the end
    // on its right edge, and nudging the strip up and down through that
    // level moves the end smoothly, never jumping from edge to edge.
    @Test func thinTargetWrapsSmoothly() {
        let o = CGPoint(x: 201, y: 0)
        func end(_ t: CGFloat) -> CGPoint {
            AttachFinder.exactEnd(at: CGPoint(x: 0, y: t), from: o,
                                  on: box(CGRect(x: 0, y: t - 4, width: 200, height: 8)))
        }
        #expect(near(end(0), CGPoint(x: 200, y: 0), 0.01), "\(end(0))")
        var last = end(-20)
        for k in -1999...2000 {
            let p = end(CGFloat(k) / 100)
            #expect(hypot(p.x - last.x, p.y - last.y) <= 2, "t \(CGFloat(k) / 100): \(last) → \(p)")
            last = p
        }
    }

    // Proves the attachment itself never changes: it stays exact on the
    // left-edge middle, so moving the strip back restores that spot.
    @Test func movingBackRestoresTheSpot() {
        var (stack, line, target) = attachedEnd(from: .zero, stripAt: strip(x: -300))
        stack.replace(box(strip(x: 100)).withID(target))
        let a = current(stack, line)
        #expect(near(a.position(of: .end), CGPoint(x: 100, y: 0)))
        #expect(a.attachments == [Attachment(point: .end, target: target, spot: .frame(CGPoint(x: 0, y: 0.5)))])
    }

    // Proves a Text wraps as the box does: its left edge's middle, with the
    // Text moved to the far side, gives way to its right edge.
    @Test func textWraps() {
        let text = Annotation(kind: .text(TextData(string: "Hello", origin: CGPoint(x: 100, y: 12),
            format: TextFormat(font: "Monaco", size: 20, weight: .regular, alignment: .left, pill: false))), style: red4)
        let line = Annotation(kind: .line(start: .zero, end: .zero), style: red4)
        var stack = LayerStack([text, line])
        stack.attach(line.id, .end, to: text.id, at: .frame(CGPoint(x: 0, y: 0.5)))
        let b = text.kind.bounds
        #expect(near(current(stack, line.id).position(of: .end), CGPoint(x: b.minX, y: b.midY)))
        let moved = text.moved(by: CGVector(dx: -200 - b.width, dy: 0))
        stack.replace(moved)
        let mb = moved.kind.bounds, end = current(stack, line.id).position(of: .end)!
        #expect(abs(end.x - mb.maxX) < 0.01, "\(end) on \(mb)")
        #expect(depth(.zero, end, in: mb) < 0.01)
    }

    // Proves a Line with both ends on the same strip keeps both spots: each
    // end's neighbour sits on the strip, so there is no outside to reach from.
    @Test func bothEndsOnOneTargetHold() {
        let target = box(strip(x: 100)), line = Annotation(kind: .line(start: .zero, end: .zero), style: red4)
        var stack = LayerStack([target, line])
        stack.attach(line.id, .start, to: target.id, at: .frame(CGPoint(x: 0, y: 0.5)))
        stack.attach(line.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 0.5)))
        #expect(near(current(stack, line.id).position(of: .start), CGPoint(x: 100, y: 0)))
        #expect(near(current(stack, line.id).position(of: .end), CGPoint(x: 300, y: 0)))
    }

    // Proves a drop inside a Text-sized strip attaches loosely even near its
    // edge, as tldraw's does: only a highlighted spot gives an exact drop
    // from inside. From just outside, the edge still snaps exactly, and a
    // bend dropped inside near the edge still snaps to it.
    @Test func dropsInsideAreLoose() {
        let target = box(strip(x: 100)), line = Annotation(kind: .line(start: CGPoint(x: 0, y: 200), end: .zero), style: red4)
        let stack = LayerStack([target, line])
        let inside = AttachFinder.hover(at: CGPoint(x: 150, y: 8), in: stack, attaching: line.id, .end, radius: 8)
        #expect(inside?.loose == true && inside?.snapped == nil)
        let spot = AttachFinder.hover(at: CGPoint(x: 102, y: 1), in: stack, attaching: line.id, .end, radius: 8)
        #expect(spot?.snapped?.spot == .frame(CGPoint(x: 0, y: 0.5)))
        let outside = AttachFinder.hover(at: CGPoint(x: 150, y: 16), in: stack, attaching: line.id, .end, radius: 8)
        #expect(outside?.loose == false && near(outside?.snapped?.at, CGPoint(x: 150, y: 12), 0.01))
        let bend = AttachFinder.hover(at: CGPoint(x: 150, y: 8), in: stack, attaching: line.id, .bend, radius: 8)
        #expect(near(bend?.snapped?.at, CGPoint(x: 150, y: 12), 0.01))
    }
}

extension Annotation {
    /// this Annotation under another id, so a test can swap a target's geometry
    func withID(_ id: Annotation.ID) -> Annotation {
        Annotation(id: id, kind: kind, style: style)
    }
}
