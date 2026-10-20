import Testing
import Foundation
import WadjetKit

struct AttachingTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    func box(_ r: CGRect = CGRect(x: 0, y: 0, width: 100, height: 50)) -> Annotation {
        Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: r), style: red4)
    }
    func arrow(from s: CGPoint = CGPoint(x: -50, y: -50), to e: CGPoint = .zero, bend: CGPoint? = nil) -> Annotation {
        Annotation(kind: .line(start: s, end: e, bend: bend), style: red4)
    }
    func near(_ a: CGPoint?, _ b: CGPoint, _ tolerance: CGFloat = 1e-6) -> Bool {
        guard let a else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= tolerance
    }
    func current(_ stack: LayerStack, _ id: Annotation.ID) -> Annotation {
        stack.annotations.first { $0.id == id }!
    }

    // Proves an attached Line end lands on its anchor and follows the target
    // through a move, a resize, a rotation, and a flip. Expected points are
    // worked by hand from the 100 × 50 box's top-right corner.
    @Test func endFollowsItsTarget() {
        let target = box()
        let edits: [(String, (Annotation) -> Annotation, CGPoint)] = [
            ("move", { $0.moved(by: CGVector(dx: 10, dy: 20)) }, CGPoint(x: 110, y: 70)),
            ("resize", { $0.dragging(.resize(x: 1, y: 1), from: CGPoint(x: 100, y: 50),
                                     to: CGPoint(x: 200, y: 100)) }, CGPoint(x: 200, y: 100)),
            // 90° counterclockwise about the centre (50, 25): (50, 25) → (−25, 50)
            ("rotate", { $0.rotated(by: .pi / 2) }, CGPoint(x: 25, y: 75)),
            ("flip", { $0.flipped(horizontally: true) }, CGPoint(x: 0, y: 50)),
        ]
        for (name, edit, want) in edits {
            let a = arrow()
            var stack = LayerStack([target, a])
            let attached = stack.attach(a.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 1)))
            #expect(attached)
            #expect(near(current(stack, a.id).position(of: .end), CGPoint(x: 100, y: 50)), "\(name): attaching")
            stack.replace(edit(target))
            #expect(near(current(stack, a.id).position(of: .end), want), "\(name)")
            #expect(near(current(stack, a.id).position(of: .start), CGPoint(x: -50, y: -50)), "\(name): start stays")
        }
    }

    // Proves a bent Line re-aims when its attached end follows: the bend keeps
    // its place relative to the chord. Chord (0,0)→(10,0) with bend (5,5) is
    // z = 0.5 + 0.5i; the end moving to (0,10) puts the bend at z·10i = (−5, 5).
    @Test func bendKeepsItsPlaceOnTheChord() {
        let target = box(CGRect(x: 0, y: 10, width: 4, height: 4))
        let a = arrow(from: .zero, to: CGPoint(x: 10, y: 0), bend: CGPoint(x: 5, y: 5))
        var stack = LayerStack([target, a])
        stack.attach(a.id, .end, to: target.id, at: .frame(.zero))
        #expect(near(current(stack, a.id).position(of: .bend), CGPoint(x: -5, y: 5)))
    }

    // Proves a point anchored along a path rides that path's reshaping, and
    // that a path node attaches with its handles riding along.
    @Test func segmentAnchorFollowsReshape() {
        let path = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: .zero),
                                                           PathNode(anchor: CGPoint(x: 10, y: 0))])),
                              style: red4)
        let a = arrow(from: CGPoint(x: 0, y: 20), to: CGPoint(x: 3, y: 20))
        var stack = LayerStack([path, a])
        stack.attach(a.id, .end, to: path.id, at: .segment(0, t: 0.5))
        #expect(near(current(stack, a.id).position(of: .end), CGPoint(x: 5, y: 0)))
        stack.replace(path.dragging(.vertex(1), from: CGPoint(x: 10, y: 0), to: CGPoint(x: 10, y: 10)))
        #expect(near(current(stack, a.id).position(of: .end), CGPoint(x: 5, y: 5)))

        let pen = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 10, y: 0), handleIn: CGPoint(x: 8, y: 2), handleOut: CGPoint(x: 12, y: -2)),
            PathNode(anchor: CGPoint(x: 20, y: 0)),
        ])), style: red4)
        let target = box(CGRect(x: 10, y: 30, width: 10, height: 10))
        stack = LayerStack([target, pen])
        stack.attach(pen.id, .node(1), to: target.id, at: .frame(.zero))
        guard case let .path(d) = current(stack, pen.id).kind else { Issue.record("not a path"); return }
        #expect(d.nodes[1] == PathNode(anchor: CGPoint(x: 10, y: 30), handleIn: CGPoint(x: 8, y: 32),
                                       handleOut: CGPoint(x: 12, y: 28)))
    }

    // Proves a whole Annotation keeps its offset from its anchor as the
    // target moves, and turns with it: a Text 20 pt right of the box's
    // right-edge midpoint (100, 25) sits 20 pt above it after a 90° turn.
    @Test func wholeAnnotationKeepsItsOffset() {
        let target = box()
        let text = Annotation(kind: .text(TextData(string: "hi", origin: CGPoint(x: 120, y: 40),
                                                   format: .default)), style: red4)
        let c0 = CGPoint(x: text.kind.bounds.midX, y: text.kind.bounds.midY)
        var stack = LayerStack([target, text])
        let attached = stack.attach(text.id, .whole, to: target.id, at: .frame(CGPoint(x: 1, y: 0.5)))
        #expect(attached)
        #expect(current(stack, text.id).kind == text.kind)

        stack.replace(target.moved(by: CGVector(dx: -30, dy: 5)))
        var b = current(stack, text.id).kind.bounds
        #expect(near(CGPoint(x: b.midX, y: b.midY), CGPoint(x: c0.x - 30, y: c0.y + 5)))

        stack.replace(target.rotated(by: .pi / 2))
        let t = current(stack, text.id)
        b = t.kind.bounds
        // the anchor (100, 25) turns to (50, 75); the offset (c0 − anchor) turns with it
        let off = CGVector(dx: c0.x - 100, dy: c0.y - 25)
        #expect(near(CGPoint(x: b.midX, y: b.midY), CGPoint(x: 50 - off.dy, y: 75 + off.dx)))
        #expect(abs(t.transform.rotation - .pi / 2) < 1e-9)
    }

    // Proves attaching refuses itself, a missing target, a point the kind
    // lacks, and any attachment that would close a cycle — through a chain.
    @Test func cyclesAreRefused() {
        let a = arrow(), b = box(), c = box(CGRect(x: 200, y: 0, width: 10, height: 10))
        var stack = LayerStack([a, b, c])
        let toItself = stack.attach(a.id, .end, to: a.id, at: .segment(0, t: 0))
        #expect(!toItself)
        let toNothing = stack.attach(a.id, .end, to: UUID(), at: .frame(.zero))
        #expect(!toNothing)
        let missingPoint = stack.attach(b.id, .end, to: a.id, at: .segment(0, t: 0))
        #expect(!missingPoint)
        let boxToBox = stack.attach(b.id, .whole, to: c.id, at: .frame(.zero))
        #expect(boxToBox)
        let arrowToBox = stack.attach(a.id, .end, to: b.id, at: .frame(.zero))
        #expect(arrowToBox)
        let before = stack
        let closingTheCycle = stack.attach(c.id, .whole, to: a.id, at: .segment(0, t: 0.5))
        #expect(!closingTheCycle)
        #expect(!stack.canAttach(c.id, .whole, to: b.id))
        #expect(stack == before)
        #expect(stack.followers(of: c.id) == [a.id, b.id])
    }

    // Proves deleting a target frees what followed it, left where it was.
    @Test func removingTheTargetFreesItsFollowers() {
        let target = box(), a = arrow()
        var stack = LayerStack([target, a])
        stack.attach(a.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 1)))
        stack.remove(id: target.id)
        let left = current(stack, a.id)
        #expect(left.attachments.isEmpty)
        stack.add(target) // the same id back: nothing re-attaches
        #expect(current(stack, a.id).attachments.isEmpty)
        #expect(near(left.position(of: .end), CGPoint(x: 100, y: 50)))
    }

    // Proves a multi-selection moving an arrow with its target moves the
    // arrow's ends once, and an arrow moved without its target lets go.
    @Test func translateMovesFollowersOnce() {
        let target = box(), a = arrow(), label = box(CGRect(x: 120, y: 0, width: 10, height: 10))
        let d = CGVector(dx: 30, dy: -10)
        var stack = LayerStack([target, a, label])
        stack.attach(a.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 1)))
        stack.attach(label.id, .whole, to: target.id, at: .frame(CGPoint(x: 1, y: 0)))
        stack.translate([target.id, a.id], by: d)
        #expect(near(current(stack, a.id).position(of: .end), CGPoint(x: 130, y: 40)))
        #expect(near(current(stack, a.id).position(of: .start), CGPoint(x: -20, y: -60)))
        #expect(current(stack, label.id).kind.bounds == CGRect(x: 150, y: -10, width: 10, height: 10))
        #expect(current(stack, a.id).attachments.count == 1)

        // a Line attached to the label, which moves only because it follows the target
        let b = arrow(from: CGPoint(x: 0, y: 100), to: .zero)
        stack.add(b)
        stack.attach(b.id, .end, to: label.id, at: .frame(.zero))
        stack.translate([target.id, b.id], by: d)
        #expect(current(stack, b.id).attachments.count == 1)
        #expect(near(current(stack, b.id).position(of: .end), CGPoint(x: 180, y: -20)))

        stack.translate([a.id], by: d)
        #expect(current(stack, a.id).attachments.isEmpty)
        #expect(near(current(stack, a.id).position(of: .end), CGPoint(x: 190, y: 20)))
    }

    // Proves the follow-along is part of the edit's undo step, and that an
    // edit changing nothing records no step.
    @Test func followingIsInTheSameUndoStep() {
        let target = box(), a = arrow()
        var stack = LayerStack([target, a])
        stack.attach(a.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 1)))
        var history = LayerHistory()
        let before = stack
        stack.replace(target.moved(by: CGVector(dx: 10, dy: 0)))
        history.record(from: before, to: stack)
        let undone = history.undo(from: stack)
        #expect(undone == before)

        var same = before
        same.replace(current(before, a.id))
        same.replace(current(before, target.id))
        #expect(same == before)
    }

    // Proves every kind of attachment round-trips through annotations.json,
    // and that a file from before attaching loads with nothing attached and
    // re-saves byte for byte.
    @Test func attachmentsRoundTrip() throws {
        let target = box(), path = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 5, y: 5)), PathNode(anchor: CGPoint(x: 9, y: 0)),
        ])), style: red4)
        let a = arrow(bend: CGPoint(x: -20, y: -30)), text = box(CGRect(x: 150, y: 0, width: 5, height: 5))
        var stack = LayerStack([target, path, a, text])
        stack.attach(a.id, .start, to: path.id, at: .segment(1, t: 0.25))
        stack.attach(a.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 0.5)))
        stack.attach(a.id, .bend, to: target.id, at: .frame(.zero))
        stack.attach(path.id, .node(1), to: target.id, at: .frame(CGPoint(x: 0.5, y: 1)))
        stack.attach(text.id, .whole, to: target.id, at: .frame(CGPoint(x: 1, y: 1)))
        #expect(try LayerStack(json: stack.json()) == stack)

        let old = """
        {"version":1,"annotations":[{"id":"\(target.id)","kind":{"shape":{"kind":{"rectangle":{"cornerRadius":0}},\
        "rect":[0,0,100,50]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4},\
        "transform":{"rotation":0,"flipHorizontal":false,"flipVertical":false},"hidden":false,"locked":false}]}
        """
        let loaded = try LayerStack(json: Data(old.utf8))
        #expect(loaded.annotations.first?.attachments == [])
        #expect(try !String(decoding: loaded.json(), as: UTF8.self).contains("attachments"))
    }

    // Proves a saved attachment whose target is missing loads freed, in place.
    @Test func danglingAttachmentLoadsFreed() throws {
        let a = arrow()
        var withTarget = LayerStack([box(), a])
        withTarget.attach(a.id, .end, to: withTarget.annotations[0].id, at: .frame(CGPoint(x: 1, y: 1)))
        let json = try withTarget.json()
        var raw = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        raw["annotations"] = (raw["annotations"] as? [Any])?.dropFirst().map { $0 }
        let loaded = try LayerStack(json: JSONSerialization.data(withJSONObject: raw))
        #expect(loaded.annotations.count == 1)
        #expect(loaded.annotations[0].attachments.isEmpty)
        #expect(near(loaded.annotations[0].position(of: .end), CGPoint(x: 100, y: 50)))
    }

    // Proves restacking a target, even to the layer it already holds, keeps
    // what is attached to it following.
    @Test func restackingKeepsFollowers() {
        let target = box(), a = arrow(), other = box(CGRect(x: 300, y: 0, width: 5, height: 5))
        var stack = LayerStack([target, a, other])
        stack.attach(a.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 1)))
        stack.move(target.id, to: 0)
        stack.restack(target.id, .front)
        stack.replace(current(stack, target.id).moved(by: CGVector(dx: 0, dy: 10)))
        #expect(current(stack, a.id).attachments.count == 1)
        #expect(near(current(stack, a.id).position(of: .end), CGPoint(x: 100, y: 60)))
    }

    // Proves a Line's attached points solve together, whatever order they
    // were attached in. Start (0,0), end (10,0), bend (5,5): with bend and
    // end attached and both targets moved up 10, the bend sits on its anchor
    // (5,15); with both ends attached and their targets moved right 10, the
    // whole curve shifts, bend to (15,5).
    @Test func linePointsSolveTogether() {
        let line = arrow(from: .zero, to: CGPoint(x: 10, y: 0), bend: CGPoint(x: 5, y: 5))
        let atBend = box(CGRect(x: 5, y: 5, width: 2, height: 2)), atEnd = box(CGRect(x: 10, y: 0, width: 2, height: 2))
        var stack = LayerStack([atBend, atEnd, line])
        stack.attach(line.id, .bend, to: atBend.id, at: .frame(.zero))
        stack.attach(line.id, .end, to: atEnd.id, at: .frame(.zero))
        stack.translate([atBend.id, atEnd.id], by: CGVector(dx: 0, dy: 10))
        #expect(near(current(stack, line.id).position(of: .bend), CGPoint(x: 5, y: 15)))
        let settled = stack
        stack.replace(current(stack, atEnd.id))
        #expect(stack == settled)

        let atStart = box(CGRect(x: 0, y: 0, width: 2, height: 2))
        stack = LayerStack([atStart, atEnd, line])
        stack.attach(line.id, .start, to: atStart.id, at: .frame(.zero))
        stack.attach(line.id, .end, to: atEnd.id, at: .frame(.zero))
        stack.translate([atStart.id, atEnd.id], by: CGVector(dx: 10, dy: 0))
        #expect(near(current(stack, line.id).position(of: .bend), CGPoint(x: 15, y: 5)))
    }

    // Proves a Brush refit, which rebuilds the stroke's segments, keeps an
    // attached end near where it held instead of jumping to whatever the old
    // segment index now names.
    @Test func refitKeepsAnchorsInPlace() {
        let brush = Annotation(kind: .path(PathData.fitted(PathDataTests.wavy, smoothing: 0)!), style: red4)
        let a = arrow(from: CGPoint(x: 40, y: 80), to: CGPoint(x: 40, y: 60))
        var stack = LayerStack([brush, a])
        stack.attach(a.id, .end, to: brush.id, at: .segment(20, t: 0.5))
        let was = current(stack, a.id).position(of: .end)!
        stack.replaceReshaping(brush.refitted(smoothing: 1))
        let now = current(stack, a.id).position(of: .end)!
        // the refit moves the stroke itself by a few points at most
        #expect(hypot(now.x - was.x, now.y - was.y) < 4)
    }

    // Proves translate keeps an attachment whose target moves rigidly only
    // because all of its own points follow the moved Annotations: a label on
    // a Line strung between two moved boxes.
    @Test func translateKeepsIndirectTargets() {
        let b1 = box(CGRect(x: 0, y: 0, width: 10, height: 10)), b2 = box(CGRect(x: 100, y: 0, width: 10, height: 10))
        let line = arrow(from: .zero, to: CGPoint(x: 100, y: 0))
        let label = box(CGRect(x: 45, y: 10, width: 10, height: 10))
        var stack = LayerStack([b1, b2, line, label])
        stack.attach(line.id, .start, to: b1.id, at: .frame(.zero))
        stack.attach(line.id, .end, to: b2.id, at: .frame(.zero))
        stack.attach(label.id, .whole, to: line.id, at: .segment(0, t: 0.5))
        stack.translate([b1.id, b2.id, label.id], by: CGVector(dx: 7, dy: 3))
        #expect(current(stack, label.id).attachments.count == 1)
        #expect(current(stack, label.id).kind.bounds == CGRect(x: 52, y: 13, width: 10, height: 10))
    }

    // Proves a reshape that merges two attached nodes into one keeps the
    // nearer attachment in control and frees the other, rather than keeping
    // two that fight over one node. Nodes at x 40 and 60 collapse onto the
    // new middle node at x 50; the x-40 one was attached first, so on a tie
    // it wins, and its target still steers the node.
    @Test func reshapeMergingNodesFreesTheLoser() {
        func path(_ xs: [CGFloat]) -> AnnotationKind {
            .path(PathData(nodes: xs.map { PathNode(anchor: CGPoint(x: $0, y: 0)) }))
        }
        let p = Annotation(kind: path([0, 40, 60, 100]), style: red4)
        let t1 = box(CGRect(x: 40, y: 0, width: 5, height: 5)), t2 = box(CGRect(x: 60, y: 0, width: 5, height: 5))
        var stack = LayerStack([t1, t2, p])
        stack.attach(p.id, .node(1), to: t1.id, at: .frame(.zero))
        stack.attach(p.id, .node(2), to: t2.id, at: .frame(.zero))
        var reshaped = current(stack, p.id)
        reshaped.kind = path([0, 50, 100])
        stack.replaceReshaping(reshaped)
        #expect(current(stack, p.id).attachments.map(\.target) == [t1.id])
        stack.replace(t1.moved(by: CGVector(dx: 0, dy: 20)))
        #expect(near(current(stack, p.id).position(of: .node(1)), CGPoint(x: 40, y: 20)))
    }

    // Proves adding a node keeps attachments on the same physical spots: a
    // follower at 75% of the first segment stays at x = 75, and an attached
    // node keeps steering the node it held, before and after its target moves.
    @Test func insertingANodeKeepsAttachments() throws {
        let path = Annotation(kind: .path(PathData(nodes: [0, 100, 200, 300].map {
            PathNode(anchor: CGPoint(x: $0, y: 0)) })), style: red4)
        let follower = arrow(from: CGPoint(x: 75, y: 50), to: CGPoint(x: 75, y: 10))
        let target = box(CGRect(x: 200, y: 0, width: 5, height: 5))
        var stack = LayerStack([path, follower, target])
        stack.attach(follower.id, .end, to: path.id, at: .segment(0, t: 0.75))
        stack.attach(path.id, .node(2), to: target.id, at: .frame(.zero))
        let (inserted, i, t) = try #require(current(stack, path.id).insertingNodeSplit(near: CGPoint(x: 50, y: 0)))
        stack.replaceInsertingNode(inserted, at: i, splitAt: t)
        #expect(near(current(stack, follower.id).position(of: .end), CGPoint(x: 75, y: 0)))
        stack.replace(target.moved(by: CGVector(dx: 0, dy: 30)))
        #expect(near(current(stack, path.id).position(of: .node(3)), CGPoint(x: 200, y: 30)))
        #expect(near(current(stack, path.id).position(of: .node(2)), CGPoint(x: 100, y: 0)))
    }

    // Proves an insertion keeps a follower on the segment it was on, even
    // with another stroke closer than the split half's samples: on a hairpin
    // (0,0)→(1000,0)→(1000,5)→(0,5), a split at x = 100 keeps the follower
    // at (500, 0) on the lower stroke, t = 4/9 of the new segment 1, so
    // dragging the new node up 100 lifts it to 500 · 100/900 ≈ 55.6.
    @Test func insertingANodeKeepsTheSegment() throws {
        let hairpin = Annotation(kind: .path(PathData(nodes: [(0, 0), (1000, 0), (1000, 5), (0, 5)].map {
            PathNode(anchor: CGPoint(x: $0.0, y: $0.1)) })), style: red4)
        let follower = arrow(from: CGPoint(x: 500, y: -50), to: CGPoint(x: 500, y: -10))
        var stack = LayerStack([hairpin, follower])
        stack.attach(follower.id, .end, to: hairpin.id, at: .segment(0, t: 0.5))
        let (inserted, i, t) = try #require(current(stack, hairpin.id).insertingNodeSplit(near: CGPoint(x: 100, y: 0)))
        stack.replaceInsertingNode(inserted, at: i, splitAt: t)
        #expect(near(current(stack, follower.id).position(of: .end), CGPoint(x: 500, y: 0)))
        stack.replace(current(stack, hairpin.id).dragging(.vertex(i), from: CGPoint(x: 100, y: 0),
                                                         to: CGPoint(x: 100, y: 100)))
        #expect(near(current(stack, follower.id).position(of: .end), CGPoint(x: 500, y: 500.0 / 9), 1e-3))
    }

    // Proves a split on a looping cubic keeps a follower exactly in place:
    // the split's own t is used, not one recovered from where the new node
    // landed, which a loop makes ambiguous.
    @Test func insertingIntoALoopKeepsTheFollower() throws {
        let loop = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero, handleOut: CGPoint(x: 341, y: 97)),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 364, y: 220)),
        ])), style: red4)
        let follower = arrow(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 10, y: 190))
        var stack = LayerStack([loop, follower])
        stack.attach(follower.id, .end, to: loop.id, at: .segment(0, t: 0.2))
        let was = try #require(current(stack, follower.id).position(of: .end))
        let (inserted, i, t) = try #require(current(stack, loop.id).insertingNodeSplit(near: CGPoint(x: 175, y: 65)))
        stack.replaceInsertingNode(inserted, at: i, splitAt: t)
        #expect(near(current(stack, follower.id).position(of: .end), was, 1e-6))
    }

    // Proves a multi-selection replaced as a group re-solves once: moving
    // both end targets of an unselected bent Line shifts the whole curve
    // (bend (5,5) → (15,5)) instead of flattening it mid-way; and a selected
    // follower carried away from an unselected target lets go of it.
    @Test func groupReplaceSolvesOnce() {
        let line = arrow(from: .zero, to: CGPoint(x: 10, y: 0), bend: CGPoint(x: 5, y: 5))
        let s1 = box(CGRect(x: 0, y: 0, width: 2, height: 2)), s2 = box(CGRect(x: 10, y: 0, width: 2, height: 2))
        var stack = LayerStack([s1, s2, line])
        stack.attach(line.id, .start, to: s1.id, at: .frame(.zero))
        stack.attach(line.id, .end, to: s2.id, at: .frame(.zero))
        let d = CGVector(dx: 10, dy: 0)
        stack.replaceGroup([s1, s2].map { current(stack, $0.id).moved(by: d) })
        #expect(near(current(stack, line.id).position(of: .bend), CGPoint(x: 15, y: 5)))

        stack.replaceGroup([current(stack, line.id).moved(by: CGVector(dx: 0, dy: 40))])
        #expect(current(stack, line.id).attachments.isEmpty)
        #expect(near(current(stack, line.id).position(of: .start), CGPoint(x: 10, y: 40)))
    }

    // Proves copying a box with its arrow gives a copied arrow that follows
    // the copied box, and copying the arrow alone lets go of the original.
    @Test func copiesFollowCopies() {
        let target = box(), a = arrow()
        var stack = LayerStack([target, a])
        stack.attach(a.id, .end, to: target.id, at: .frame(CGPoint(x: 1, y: 1)))
        let ids = [target.id: UUID(), a.id: UUID()]
        let copies = LayerStack.copies(of: stack.annotations.map { $0.moved(by: CGVector(dx: 0, dy: 200)) }, ids: ids)
        copies.forEach { stack.add($0) }
        stack.replace(current(stack, ids[target.id]!).moved(by: CGVector(dx: 10, dy: 0)))
        #expect(near(current(stack, ids[a.id]!).position(of: .end), CGPoint(x: 110, y: 250)))
        #expect(near(current(stack, a.id).position(of: .end), CGPoint(x: 100, y: 50)))

        let lone = LayerStack.copies(of: [current(stack, a.id)], ids: [a.id: UUID()])
        #expect(lone[0].attachments.isEmpty)
    }

    // Proves a batch of refits made from one snapshot keeps each other's
    // remaps: Brush B's end on Brush A stays put whichever is refitted first.
    @Test func batchRefitKeepsRemaps() {
        func brush() -> Annotation {
            Annotation(kind: .path(PathData.fitted(PathDataTests.wavy, smoothing: 0)!), style: red4)
        }
        var results: [CGPoint] = []
        for aFirst in [true, false] {
            let a = brush(), b = brush().moved(by: CGVector(dx: 0, dy: 100))
            var stack = LayerStack([a, b])
            stack.attach(b.id, .end, to: a.id, at: .segment(20, t: 0.5))
            let snapshot = [current(stack, a.id), current(stack, b.id)].map { $0.refitted(smoothing: 1) }
            for r in aFirst ? snapshot : snapshot.reversed() { stack.replaceReshaping(r) }
            results.append(current(stack, b.id).position(of: .end)!)
        }
        #expect(near(results[0], results[1], 1e-6))
    }

    // Proves a group resize keeps a selected whole follower where the resize
    // put it: doubling a box at the origin with its label (centre x 125, on
    // the anchor at x 100) leaves the label's centre at x 250, and it still
    // follows the box afterwards.
    @Test func groupResizeKeepsSelectedFollowers() {
        let target = box(), label = box(CGRect(x: 120, y: 20, width: 10, height: 10))
        var stack = LayerStack([target, label])
        stack.attach(label.id, .whole, to: target.id, at: .frame(CGPoint(x: 1, y: 0.5)))
        let doubled = AnnotationGroup.dragging([current(stack, target.id), current(stack, label.id)],
                                               .resize(x: 1, y: 1), from: CGPoint(x: 130, y: 50),
                                               to: CGPoint(x: 260, y: 100))
        stack.replaceGroup(doubled)
        var b = current(stack, label.id).kind.bounds
        #expect(abs(b.midX - 250) < 1e-6)
        stack.replace(current(stack, target.id).moved(by: CGVector(dx: 10, dy: 0)))
        b = current(stack, label.id).kind.bounds
        #expect(abs(b.midX - 260) < 1e-6)
        #expect(current(stack, label.id).attachments.count == 1)
    }

    // Proves deleting an anchor that leaves the stroke unchanged keeps a
    // follower in place: nodes at x 0, 25, 50, 100 lose the one at 25, and a
    // label halfway between 25 and 50 stays at x 37.5.
    @Test func removingAnAnchorKeepsFollowers() throws {
        let path = Annotation(kind: .path(PathData(nodes: [0, 25, 50, 100].map {
            PathNode(anchor: CGPoint(x: $0, y: 0)) })), style: red4)
        let label = box(CGRect(x: 32.5, y: 10, width: 10, height: 10))
        var stack = LayerStack([path, label])
        stack.attach(label.id, .whole, to: path.id, at: .segment(1, t: 0.5))
        let kept = try #require(current(stack, path.id).removingAnchors([1]))
        stack.replaceRemovingAnchors(kept, removed: [1])
        #expect(abs(current(stack, label.id).kind.bounds.midX - 37.5) < 1e-6)
    }

    // Proves dragging an attached anchor carries it away free, while an
    // anchor left where it was stays attached.
    @Test func draggedAnchorsLetGo() {
        let path = Annotation(kind: .path(PathData(nodes: [0, 50, 100].map {
            PathNode(anchor: CGPoint(x: $0, y: 0)) })), style: red4)
        let t1 = box(CGRect(x: 0, y: 0, width: 5, height: 5)), t2 = box(CGRect(x: 100, y: 0, width: 5, height: 5))
        var stack = LayerStack([t1, t2, path])
        stack.attach(path.id, .start, to: t1.id, at: .frame(.zero))
        stack.attach(path.id, .end, to: t2.id, at: .frame(.zero))
        let moved = current(stack, path.id).movingAnchors([2], by: CGVector(dx: 0, dy: 30))
        stack.replaceEditingAnchors([(moved, [2])])
        #expect(current(stack, path.id).attachments.map(\.point) == [.start])
        #expect(near(current(stack, path.id).position(of: .end), CGPoint(x: 100, y: 30)))
    }

    // Proves deleting an anchor keeps a follower on its own, unchanged
    // segment, even beside a closer stroke: on the hairpin
    // (0,0)→(100,0)→(1000,0)→(1000,5)→(0,5), deleting the first anchor
    // leaves the follower at (500, 0), and a deleted attached node lets go.
    @Test func removingAnAnchorKeepsTheSegment() throws {
        let hairpin = Annotation(kind: .path(PathData(nodes: [(0, 0), (100, 0), (1000, 0), (1000, 5), (0, 5)].map {
            PathNode(anchor: CGPoint(x: $0.0, y: $0.1)) })), style: red4)
        let follower = arrow(from: CGPoint(x: 500, y: -50), to: CGPoint(x: 500, y: -10))
        let t = box(CGRect(x: 0, y: 0, width: 5, height: 5))
        var stack = LayerStack([t, hairpin, follower])
        stack.attach(follower.id, .end, to: hairpin.id, at: .segment(1, t: 4.0 / 9))
        stack.attach(hairpin.id, .start, to: t.id, at: .frame(.zero))
        let kept = try #require(current(stack, hairpin.id).removingAnchors([0]))
        stack.replaceRemovingAnchors(kept, removed: [0])
        #expect(near(current(stack, follower.id).position(of: .end), CGPoint(x: 500, y: 0)))
        #expect(current(stack, hairpin.id).attachments.isEmpty)
    }

    // Proves a group resize keeps a selected label's placement when its
    // target only follows the group: two boxes and a label on the Line
    // between them, doubled about the origin, leave the label's centre at
    // (100, 30), and it stays attached.
    @Test func groupResizeKeepsFollowersOfIndirectTargets() {
        let b1 = box(CGRect(x: 0, y: 0, width: 0.001, height: 0.001))
        let b2 = box(CGRect(x: 100, y: 0, width: 0.001, height: 0.001))
        let line = arrow(from: .zero, to: CGPoint(x: 100, y: 0))
        let label = box(CGRect(x: 45, y: 10, width: 10, height: 10))
        var stack = LayerStack([b1, b2, line, label])
        stack.attach(line.id, .start, to: b1.id, at: .frame(.zero))
        stack.attach(line.id, .end, to: b2.id, at: .frame(.zero))
        stack.attach(label.id, .whole, to: line.id, at: .segment(0, t: 0.5))
        let ids: Set = [b1.id, b2.id, label.id]
        // each member's rect doubled about the origin, as a 2× group resize does
        let doubled = stack.annotations.filter { ids.contains($0.id) }.map { a -> Annotation in
            guard case let .shape(k, r) = a.kind else { return a }
            var a = a
            a.kind = .shape(k, rect: CGRect(x: r.minX * 2, y: r.minY * 2, width: r.width * 2, height: r.height * 2))
            return a
        }
        stack.replaceGroup(doubled)
        let b = current(stack, label.id).kind.bounds
        #expect(abs(b.midX - 100) < 1e-6 && abs(b.midY - 30) < 1e-6)
        #expect(current(stack, label.id).attachments.count == 1)
    }
}

