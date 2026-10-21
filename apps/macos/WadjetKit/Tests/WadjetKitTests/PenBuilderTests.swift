import Testing
import Foundation
import WadjetKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-3 }
private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

struct PenBuilderTests {
    // click adds corner nodes; the path stays open
    @Test func threeClicks() {
        var b = PenBuilder()
        #expect(b.press(at: .zero, closeRadius: 6) == false)
        #expect(b.press(at: CGPoint(x: 100, y: 0), closeRadius: 6) == false)
        #expect(b.press(at: CGPoint(x: 100, y: 100), closeRadius: 6) == false)
        #expect(b.path.nodes.count == 3 && !b.path.closed)
        #expect(b.path.nodes.allSatisfy { $0.handleIn == nil && $0.handleOut == nil })
    }

    // press-drag pulls handleOut to the pointer and mirrors handleIn through the anchor
    @Test func dragPullsHandles() {
        var b = PenBuilder()
        _ = b.press(at: .zero, closeRadius: 6)
        _ = b.press(at: CGPoint(x: 100, y: 0), closeRadius: 6)
        b.drag(to: CGPoint(x: 120, y: 30))
        let n = b.path.nodes[1]
        #expect(n.handleOut == CGPoint(x: 120, y: 30))
        #expect(n.handleIn == CGPoint(x: 80, y: -30))
    }

    // Shift snaps the pulled handle to 45° from the anchor, and a constrained
    // press snaps the new node to 45° from the previous one
    @Test func constrainedPressAndDrag() {
        var b = PenBuilder()
        _ = b.press(at: .zero, closeRadius: 6)
        _ = b.press(at: CGPoint(x: 100, y: 80), closeRadius: 6, constrained: true)
        #expect(near(b.path.nodes[1].anchor, CGPoint(x: 90, y: 90))) // 38.7° -> the diagonal, x kept
        b.drag(to: CGPoint(x: 90, y: 170))
        #expect(near(b.path.nodes[1].handleOut!, CGPoint(x: 90, y: 170))) // 89.9° -> vertical
    }

    // a press on the first node of a ≥2-node path closes it and finishes;
    // with only one node, pressing near the first node adds a node instead
    @Test func closingPress() {
        var b = PenBuilder()
        _ = b.press(at: .zero, closeRadius: 6)
        #expect(b.press(at: CGPoint(x: 2, y: 2), closeRadius: 6) == false) // near node 0, but alone
        #expect(b.path.nodes.count == 2)
        #expect(b.press(at: CGPoint(x: -3, y: 1), closeRadius: 6) == true)
        #expect(b.path.closed)
        // dragging after the closing press shapes the first node
        b.drag(to: CGPoint(x: -20, y: 0))
        #expect(b.path.nodes[0].handleOut == CGPoint(x: -20, y: 0))
        #expect(b.path.nodes[0].handleIn == CGPoint(x: 20, y: 0))
    }

    // a path needs two nodes to keep
    @Test func finishedNeedsTwoNodes() {
        var b = PenBuilder()
        #expect(b.finished == nil)
        _ = b.press(at: .zero, closeRadius: 6)
        #expect(b.finished == nil)
        _ = b.press(at: CGPoint(x: 50, y: 0), closeRadius: 6)
        #expect(b.finished?.nodes.count == 2)
    }

    // the rubber-band preview is the path plus a corner node at the pointer
    @Test func previewAddsHoverNode() {
        var b = PenBuilder()
        _ = b.press(at: .zero, closeRadius: 6)
        let d = b.preview(to: CGPoint(x: 30, y: 40))
        #expect(d.nodes.count == 2 && d.nodes[1].anchor == CGPoint(x: 30, y: 40) && !d.closed)
    }
}
