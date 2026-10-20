import Testing
import Foundation
import WadjetKit

struct AttachFinderTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    func box(_ r: CGRect = CGRect(x: 0, y: 0, width: 100, height: 50)) -> Annotation {
        Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: r), style: red4)
    }
    func near(_ a: CGPoint?, _ b: CGPoint) -> Bool {
        guard let a else { return false }
        return hypot(a.x - b.x, a.y - b.y) < 1e-3
    }

    // Proves what a dragged end snaps to over a 100 × 50 box: a named spot
    // within range beats the outline, the outline catches a point between
    // spots, a point deep inside highlights the box without snapping, and a
    // point far outside finds nothing.
    @Test func dragOverABox() {
        let target = box(), arrow = Annotation(kind: .line(start: CGPoint(x: -90, y: -90), end: .zero), style: red4)
        let stack = LayerStack([target, arrow])
        let rows: [(String, CGPoint, AttachAnchor?, Bool)] = [
            ("corner", CGPoint(x: 103, y: 52), .frame(CGPoint(x: 1, y: 1)), true),
            ("edge midpoint", CGPoint(x: 52, y: -4), .frame(CGPoint(x: 0.5, y: 0)), true),
            // 12 pt up the right edge: (1, 0.24) on the outline, no named spot within 8
            ("outline", CGPoint(x: 104, y: 12), .frame(CGPoint(x: 1, y: 0.24)), true),
            ("inside", CGPoint(x: 30, y: 30), nil, true),
            ("far", CGPoint(x: 300, y: 300), nil, false),
        ]
        for (name, p, anchor, hovers) in rows {
            let h = AttachFinder.hover(at: p, in: stack, attaching: arrow.id, .end, radius: 8)
            #expect((h != nil) == hovers, "\(name)")
            guard let h else { continue }
            #expect(h.target.id == target.id, "\(name)")
            switch (h.snapped?.anchor, anchor) {
            case (nil, nil): break
            case let (.frame(got)?, .frame(want)?):
                #expect(near(got, want), "\(name): \(got)")
            default: Issue.record("\(name): snapped \(String(describing: h.snapped))")
            }
        }
    }

    // Proves a Line target snaps along its path by segment and t, and that
    // the source itself and a target that would close a cycle are skipped.
    @Test func lineTargetsAndSkips() {
        let target = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: red4)
        let arrow = Annotation(kind: .line(start: CGPoint(x: 0, y: 80), end: CGPoint(x: 30, y: 50)), style: red4)
        var stack = LayerStack([target, arrow])
        let h = AttachFinder.hover(at: CGPoint(x: 30, y: 3), in: stack, attaching: arrow.id, .end, radius: 8)
        guard case let .segment(i, t)? = h?.snapped?.anchor else { Issue.record("no segment anchor"); return }
        #expect(i == 0 && abs(t - 0.3) < 1e-6)

        #expect(AttachFinder.hover(at: CGPoint(x: 0, y: 80), in: stack, attaching: arrow.id, .start, radius: 8) == nil)
        stack.attach(target.id, .end, to: arrow.id, at: .segment(0, t: 0))
        #expect(AttachFinder.hover(at: CGPoint(x: 30, y: 3), in: stack, attaching: arrow.id, .end, radius: 8) == nil)
    }

    // Proves a dragged grip names the point it would attach: a Line's ends
    // and bend, an open path's ends and the nodes between.
    @Test func gripsThatAttach() {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 1, y: 1)), style: red4)
        let pen = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 5, y: 0)),
                                                          PathNode(anchor: CGPoint(x: 9, y: 0))])), style: red4)
        #expect(line.attachPoint(for: .vertex(0)) == .start)
        #expect(line.attachPoint(for: .vertex(1)) == .end)
        #expect(line.attachPoint(for: .bend) == .bend)
        #expect(pen.attachPoint(for: .vertex(0)) == .start)
        #expect(pen.attachPoint(for: .vertex(1)) == .node(1))
        #expect(pen.attachPoint(for: .bend) == nil)
        #expect(pen.attachPoint(for: .vertex(2)) == .end)
    }
}
