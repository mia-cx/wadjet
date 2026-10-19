import CoreGraphics
import Testing
import WadjetKit

struct RecropTests {
    static let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    static let minSize: CGFloat = 16
    static let crop = CGRect(x: 100, y: 100, width: 400, height: 300)

    // a left-edge drag past the displays stops at their edge
    @Test func edgeStopsAtBounds() {
        let r = Recrop.drag(Self.crop, edges: .minX, by: CGVector(dx: -500, dy: 0),
                            within: Self.bounds, minSize: Self.minSize)
        #expect(r == CGRect(x: 0, y: 100, width: 500, height: 300))
    }

    // a right-edge drag past the left edge stops minSize short of it
    @Test func edgeStopsAtMinSize() {
        let r = Recrop.drag(Self.crop, edges: .maxX, by: CGVector(dx: -900, dy: 0),
                            within: Self.bounds, minSize: Self.minSize)
        #expect(r == CGRect(x: 100, y: 100, width: 16, height: 300))
    }

    // a whole-crop move past the bounds keeps its size and stays inside
    @Test func moveStaysInside() {
        let r = Recrop.drag(Self.crop, edges: [], by: CGVector(dx: 800, dy: -400),
                            within: Self.bounds, minSize: Self.minSize)
        #expect(r == CGRect(x: 600, y: 0, width: 400, height: 300))
    }

    // a corner drag moves both edges
    @Test func cornerMovesBothEdges() {
        let r = Recrop.drag(Self.crop, edges: [.minX, .maxY], by: CGVector(dx: -40, dy: 60),
                            within: Self.bounds, minSize: Self.minSize)
        #expect(r == CGRect(x: 60, y: 100, width: 440, height: 360))
    }

    @Test(arguments: [
        // a corner press takes that corner's two edges
        (CGPoint(x: 103, y: 397), [.minX, .maxY] as CropEdges?),
        // an edge press takes that edge
        (CGPoint(x: 300, y: 104), .minY),
        // an inside press takes no edges — a move
        (CGPoint(x: 300, y: 250), CropEdges()),
        // anywhere else grabs nothing
        (CGPoint(x: 50, y: 50), nil),
    ])
    func edgesAt(point: CGPoint, expected: CropEdges?) {
        #expect(Recrop.edges(at: point, of: Self.crop, radius: 6) == expected)
    }

    // two side-by-side displays of different heights bound to their union
    @Test func displayBoundsUnionsLayout() {
        let canvas = CanvasDocument(layout: [
            CanvasDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scaleFactor: 2),
            CanvasDisplay(id: 2, frame: CGRect(x: 1920, y: 200, width: 1080, height: 1920), scaleFactor: 2),
        ], crop: CGRect(x: 0, y: 0, width: 100, height: 100), displayImages: [:])
        #expect(canvas.displayBounds == CGRect(x: 0, y: 0, width: 3000, height: 2120))
        #expect(canvas.maxCornerRadius == 50)
    }
}
