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

    // Proves a censor rect hit-tests as a filled shape: inside counts, and
    // tolerance reaches past its edge; rotated pi/2 about the centre (50,25),
    // (0,0,100,50) displays x 25…75, y -25…75
    @Test(arguments: [
        (CGPoint(x: 50, y: 25), 0.0, 0.0, true),    // centre: filled area hits
        (CGPoint(x: 101, y: 25), 0.0, 0.0, false),  // just past the edge
        (CGPoint(x: 101, y: 25), 2.0, 0.0, true),   // tolerance reaches outside
        (CGPoint(x: 50, y: 70), 0.0, .pi / 2, true),  // inside once rotated
        (CGPoint(x: 90, y: 25), 0.0, .pi / 2, false), // outside the rotated span
    ])
    func censorHitTest(point: CGPoint, tolerance: Double, rotation: Double, expected: Bool) {
        let a = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 100, height: 50),
                                         method: .blackOut),
                           style: AnnotationStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 1), width: 4),
                           transform: AnnotationTransform(rotation: rotation))
        #expect(PathGeometry.hitTest(a, at: point, tolerance: tolerance) == expected)
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
