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
}
