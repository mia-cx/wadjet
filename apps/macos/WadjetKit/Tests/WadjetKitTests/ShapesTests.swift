import Testing
import Foundation
import WadjetKit

struct ShapesTests {
    // Proves a drag's rect: Shift takes the longer side on both axes keeping
    // the drag's direction, Option centres on the drag's start.
    @Test(arguments: [
        // start, end, square, fromCentre, expected rect
        (CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 20), false, false, CGRect(x: 0, y: 0, width: 40, height: 20)),
        (CGPoint(x: 0, y: 0), CGPoint(x: -40, y: 20), false, false, CGRect(x: -40, y: 0, width: 40, height: 20)),
        (CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 20), true, false, CGRect(x: 0, y: 0, width: 40, height: 40)),
        (CGPoint(x: 0, y: 0), CGPoint(x: -40, y: 20), true, false, CGRect(x: -40, y: 0, width: 40, height: 40)),
        (CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 20), false, true, CGRect(x: -20, y: 0, width: 60, height: 20)),
        (CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 20), true, true, CGRect(x: -20, y: -20, width: 60, height: 60)),
    ])
    func dragRect(start: CGPoint, end: CGPoint, square: Bool, fromCentre: Bool, expected: CGRect) {
        #expect(CGRect(dragFrom: start, to: end, square: square, fromCentre: fromCentre) == expected)
    }

    // Proves each variant's outline sits in its rect the way the menu promises:
    // a rounded corner cuts the corner, a polygon points up and inscribes an
    // ellipse, a star pinches between its tips.
    @Test func variantPaths() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(!ShapeKind.rectangle(cornerRadius: 20).path(in: rect).contains(CGPoint(x: 1, y: 1)))
        #expect(ShapeKind.rectangle(cornerRadius: 20).path(in: rect).contains(CGPoint(x: 50, y: 50)))
        #expect(ShapeKind.rectangle(cornerRadius: 0).path(in: rect).contains(CGPoint(x: 1, y: 1)))
        // a radius past half the short side clamps rather than trapping
        let wide = CGRect(x: 0, y: 0, width: 100, height: 40)
        #expect(ShapeKind.rectangle(cornerRadius: 500).path(in: wide).contains(CGPoint(x: 2, y: 20)))
        #expect(!ShapeKind.rectangle(cornerRadius: 500).path(in: wide).contains(CGPoint(x: 1, y: 1)))
        let tri = ShapeKind.polygon(sides: 3).path(in: rect).boundingBox
        #expect(abs(tri.minX - 6.7) < 0.01 && abs(tri.minY - 25) < 0.01
                && abs(tri.width - 86.6) < 0.01 && abs(tri.height - 75) < 0.01)
        #expect(ShapeKind.polygon(sides: 4).path(in: rect).contains(CGPoint(x: 50, y: 90)))
        #expect(!ShapeKind.polygon(sides: 4).path(in: rect).contains(CGPoint(x: 90, y: 90)))
        let star = ShapeKind.star(points: 5, innerRatio: 0.4).path(in: rect)
        #expect(star.contains(CGPoint(x: 50, y: 50)))
        #expect(star.contains(CGPoint(x: 50, y: 95)))
        // between two tips the outline dips to the inner radius (20 at 126°)
        let notch = CGPoint(x: 50 + 30 * cos(126 * .pi / 180), y: 50 + 30 * sin(126 * .pi / 180))
        #expect(!star.contains(notch))
    }

    // Proves hit testing follows what the user sees: a filled shape hits
    // inside, an unfilled one only on its stroked outline.
    @Test func fillHitTesting() {
        let kind = AnnotationKind.shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        var style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        #expect(!PathGeometry.hitTest(Annotation(kind: kind, style: style), at: CGPoint(x: 50, y: 50)))
        #expect(PathGeometry.hitTest(Annotation(kind: kind, style: style), at: CGPoint(x: 0, y: 50)))
        style.fill = RGBAColour(red: 0, green: 0, blue: 1, alpha: 1)
        #expect(PathGeometry.hitTest(Annotation(kind: kind, style: style), at: CGPoint(x: 50, y: 50)))
        style.stroked = false
        #expect(PathGeometry.hitTest(Annotation(kind: kind, style: style), at: CGPoint(x: 50, y: 50)))
        #expect(!PathGeometry.hitTest(Annotation(kind: kind, style: style), at: CGPoint(x: -1.5, y: 50)))
    }

    // Proves a corner grip resizes a shape's rect like a line's endpoints.
    @Test func resizingAShape() {
        let a = Annotation(kind: .shape(.ellipse, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                           style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4))
        let r = a.dragging(.resize(x: 1, y: 1), from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 50))
        #expect(r.kind == .shape(.ellipse, rect: CGRect(x: 0, y: 0, width: 200, height: 50)))
    }
}
