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

    // a zero-height line shows only its end grips plus the rotate grip
    @Test func handlesOnALine() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let hs = a.handles(minExtent: 12, rotateOffset: 20)
        #expect(hs.count == 3)
        #expect(hs[0].handle == .resize(x: -1, y: 0) && near(hs[0].at, .zero))
        #expect(hs[1].handle == .resize(x: 1, y: 0) && near(hs[1].at, CGPoint(x: 100, y: 0)))
        #expect(hs[2].handle == .rotate && near(hs[2].at, CGPoint(x: 50, y: 20)))
    }
}
