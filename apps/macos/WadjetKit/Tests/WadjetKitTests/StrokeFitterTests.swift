import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct StrokeFitterTests {
    private static let strokes: [[CGPoint]] = [
        // A wavy drag, a corner, and a returning stroke exercise different fits.
        (0...80).map { index -> CGPoint in
            let noise: Double = index.isMultiple(of: 2) ? 1 : -1
            let y = 20 * sin(Double(index) / 8) + noise
            return CGPoint(x: Double(index) * 2, y: y)
        },
        [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 40, y: 0),
         CGPoint(x: 40, y: 20), CGPoint(x: 40, y: 40)],
        [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0),
         CGPoint(x: 10, y: -10), CGPoint(x: 0, y: 0)]
    ]

    // Proves fitted geometry follows sample fixtures within the published point tolerance.
    @Test(arguments: strokes.indices, [CGFloat(0), 0.5, 1])
    func fixtureTolerance(fixture: Int, smoothing: CGFloat) throws {
        let points = Self.strokes[fixture]
        let stroke = StrokeFitter.fit(points, smoothing: smoothing)
        #expect(stroke.rawPoints == points)
        #expect(stroke.segments.first?.start == points.first)
        #expect(stroke.segments.last?.end == points.last)
        for (left, right) in zip(stroke.segments, stroke.segments.dropFirst()) {
            #expect(left.end == right.start)
        }
        // Flatten independently, then measure distance to each little line segment.
        let flattened = stroke.segments.map { curve in (0...1000).map { curve.point(at: CGFloat($0) / 1000) } }
        for point in points {
            let error = flattened.flatMap { polyline in
                zip(polyline, polyline.dropFirst()).map { distance(point, to: $0, $1) }
            }.min()!
            #expect(error <= stroke.tolerance + 0.01)
        }
        let restored = try JSONDecoder().decode(FittedStroke.self, from: JSONEncoder().encode(stroke))
        #expect(restored.refitted(smoothing: smoothing) == stroke)
    }

    // Proves increasing Smoothing removes segments and refitting uses the raw stroke.
    @Test func smoothingReducesSegments() {
        let precise = StrokeFitter.fit(Self.strokes[0], smoothing: 0)
        let medium = precise.refitted(smoothing: 0.5)
        let smooth = medium.refitted(smoothing: 1)
        #expect(precise.segments.count > medium.segments.count)
        // Segment counts have plateaus as tolerance changes.
        #expect(medium.segments.count >= smooth.segments.count)
        #expect(precise.segments.count > smooth.segments.count)
        #expect(smooth.rawPoints == precise.rawPoints)
    }

    // Proves empty strokes, dots, duplicate samples, and two-point lines remain usable.
    @Test func degenerateStrokes() {
        let a = CGPoint(x: 2, y: 3), b = CGPoint(x: 8, y: 3)
        for points in [[], [a], [a, a, a]] as [[CGPoint]] {
            let stroke = StrokeFitter.fit(points, smoothing: 0)
            #expect(stroke.rawPoints == points)
            #expect(stroke.segments.isEmpty)
        }
        let line = StrokeFitter.fit([a, a, b, b], smoothing: 1)
        #expect(line.segments == [CubicBezierSegment(start: a, control1: CGPoint(x: 4, y: 3),
                                                     control2: CGPoint(x: 6, y: 3), end: b)])
    }

    private func distance(_ point: CGPoint, to start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : min(1, max(0,
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
    }
}
