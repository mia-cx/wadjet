import Testing
import Foundation
import WadjetKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-3 }
private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

struct AnnotationTransformTests {
    let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    // the anchor stays put; dragging past it mirrors (resize(x:1,y:0) to a negative x)
    @Test(arguments: [
        (SelectionHandle.resize(x: 1, y: 1), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 100)),
        (.resize(x: 1, y: 0), CGPoint(x: 150, y: 999), CGPoint(x: 150, y: 50)),
        (.resize(x: 1, y: 0), CGPoint(x: -100, y: 0), CGPoint(x: -100, y: 50)),
    ])
    func resize(handle: SelectionHandle, to: CGPoint, end: CGPoint) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 50)), style: style)
        let r = a.dragging(handle, from: .zero, to: to)
        guard case let .line(s, e) = r.kind else { Issue.record(); return }
        #expect(near(s, .zero) && near(e, end))
    }

    // the resize happens in the annotation's own space; the anchor (the line's
    // left end, displayed at (50,-50) after the pi/2 rotation) stays put
    @Test func rotatedResize() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style,
                           transform: AnnotationTransform(rotation: .pi / 2))
        let r = a.dragging(.resize(x: 1, y: 0), from: .zero, to: CGPoint(x: 50, y: 150))
        guard case let .line(s, e) = r.kind else { Issue.record(); return }
        #expect(near(s, CGPoint(x: -50, y: 50)) && near(e, CGPoint(x: 150, y: 50)))
        #expect(near(r.transform.rotation, .pi / 2))
    }

    @Test func rotateDrag() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let r = a.dragging(.rotate, from: CGPoint(x: 50, y: 30), to: CGPoint(x: 20, y: 0))
        #expect(near(r.transform.rotation, .pi / 2))
    }

    // a mirror across the screen's vertical axis through the centre: the
    // pi/4-tilted line ends up tilted -pi/4, ends swapped
    @Test func flipAfterRotate() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style,
                           transform: AnnotationTransform(rotation: .pi / 4))
            .flipped(horizontally: true)
        guard case let .line(s, e) = a.kind else { Issue.record(); return }
        let shown = [s, e].map { $0.applying(a.affineTransform) }
        let want = [CGPoint(x: 14.645, y: 35.355), CGPoint(x: 85.355, y: -35.355)]
        #expect(want.allSatisfy { w in shown.contains { near($0, w) } })
    }

    // corners first (a 0-extent axis zeroes that component, deduplicated), then
    // edge midpoints only when both extents reach minExtent, then rotate
    @Test(arguments: [
        // a zero-height line: only its end grips
        (CGPoint(x: 100, y: 0),
         [(SelectionHandle.resize(x: -1, y: 0), CGPoint(x: 0, y: 0)),
          (.resize(x: 1, y: 0), CGPoint(x: 100, y: 0)),
          (.rotate, CGPoint(x: 50, y: 20))]),
        // a short one keeps them under minExtent
        (CGPoint(x: 10, y: 0),
         [(.resize(x: -1, y: 0), CGPoint(x: 0, y: 0)),
          (.resize(x: 1, y: 0), CGPoint(x: 10, y: 0)),
          (.rotate, CGPoint(x: 5, y: 20))]),
        // an undersized diagonal keeps all 4 corners, no edge midpoints
        (CGPoint(x: 8, y: 8),
         [(.resize(x: -1, y: -1), CGPoint(x: 0, y: 0)),
          (.resize(x: -1, y: 1), CGPoint(x: 0, y: 8)),
          (.resize(x: 1, y: -1), CGPoint(x: 8, y: 0)),
          (.resize(x: 1, y: 1), CGPoint(x: 8, y: 8)),
          (.rotate, CGPoint(x: 4, y: 28))]),
        // full set: 4 corners, then the 4 edge midpoints (bottom, top, left, right)
        (CGPoint(x: 100, y: 100),
         [(.resize(x: -1, y: -1), CGPoint(x: 0, y: 0)),
          (.resize(x: -1, y: 1), CGPoint(x: 0, y: 100)),
          (.resize(x: 1, y: -1), CGPoint(x: 100, y: 0)),
          (.resize(x: 1, y: 1), CGPoint(x: 100, y: 100)),
          (.resize(x: 0, y: -1), CGPoint(x: 50, y: 0)),
          (.resize(x: 0, y: 1), CGPoint(x: 50, y: 100)),
          (.resize(x: -1, y: 0), CGPoint(x: 0, y: 50)),
          (.resize(x: 1, y: 0), CGPoint(x: 100, y: 50)),
          (.rotate, CGPoint(x: 50, y: 120))]),
    ])
    func handles(end: CGPoint, expected: [(SelectionHandle, CGPoint)]) {
        let a = Annotation(kind: .line(start: .zero, end: end), style: style)
        let hs = a.handles(minExtent: 12, rotateOffset: 20)
        #expect(hs.count == expected.count)
        for (h, e) in zip(hs, expected) {
            #expect(h.handle == e.0 && near(h.at, e.1))
        }
    }

    // shrunk below minExtent the corner grips stay — and still resize back
    @Test func shrinkThenEnlarge() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 50)), style: style)
        let small = a.dragging(.resize(x: 1, y: 1), from: .zero, to: CGPoint(x: 5, y: 3))
        guard case let .line(s1, e1) = small.kind else { Issue.record(); return }
        #expect(near(s1, .zero) && near(e1, CGPoint(x: 5, y: 3)))
        #expect(small.handles(minExtent: 12, rotateOffset: 20)
            .contains { $0.handle == .resize(x: 1, y: 1) && near($0.at, CGPoint(x: 5, y: 3)) })
        let back = small.dragging(.resize(x: 1, y: 1), from: .zero, to: CGPoint(x: 100, y: 50))
        guard case let .line(s2, e2) = back.kind else { Issue.record(); return }
        #expect(near(s2, .zero) && near(e2, CGPoint(x: 100, y: 50)))
    }
}
