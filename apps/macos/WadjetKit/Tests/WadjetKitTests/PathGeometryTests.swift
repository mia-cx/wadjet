import Testing
import Foundation
import WadjetKit

struct PathGeometryTests {
    // a horizontal line (0,0)->(100,0); the stroke reaches width/2 to each side
    @Test(arguments: [
        (4.0, CGPoint(x: 50, y: 1.9), 0.0, true),   // inside the 4-pt stroke
        (4.0, CGPoint(x: 50, y: 2.1), 0.0, false),  // just outside it
        (10.0, CGPoint(x: 50, y: 4.9), 0.0, true),  // a wider stroke reaches further
        (10.0, CGPoint(x: 50, y: 5.1), 0.0, false),
        (4.0, CGPoint(x: 101.9, y: 0), 0.0, true),  // round cap extends past the end point
        (4.0, CGPoint(x: 102.1, y: 0), 0.0, false),
        (4.0, CGPoint(x: 50, y: 3), 2.0, true),     // tolerance widens the stroke on each side
    ])
    func lineHitTest(width: Double, point: CGPoint, tolerance: Double, expected: Bool) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: width))
        #expect(PathGeometry.hitTest(a, at: point, tolerance: tolerance) == expected)
    }

    // rotated pi/2 about the bounds centre, a (0,0)->(100,0) line displays
    // vertical at x=50, y -50…50 — drawing and hit-testing follow the transform
    @Test(arguments: [
        (CGPoint(x: 50, y: 40), true),
        (CGPoint(x: 90, y: 0), false),
    ])
    func rotatedLineHitTest(point: CGPoint, expected: Bool) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4),
                           transform: AnnotationTransform(rotation: .pi / 2))
        #expect(PathGeometry.hitTest(a, at: point) == expected)
    }

    // flipped horizontally about the centre, a (0,0)->(100,50) line displays (0,50)->(100,0)
    @Test(arguments: [
        (CGPoint(x: 10, y: 45), true),
        (CGPoint(x: 10, y: 5), false),
    ])
    func flippedLineHitTest(point: CGPoint, expected: Bool) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 50)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4),
                           transform: AnnotationTransform(flipHorizontal: true))
        #expect(PathGeometry.hitTest(a, at: point) == expected)
    }
}
