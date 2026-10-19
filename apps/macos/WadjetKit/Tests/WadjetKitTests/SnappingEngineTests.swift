import CoreGraphics
import Testing
import WadjetKit

struct SnappingEngineTests {
    struct Fixture: Sendable {
        let name: String
        var rect: CGRect? = nil
        var points: [CGPoint] = []
        var targets: [SnapTarget] = []
        var range: CGFloat = 6
        var skip = false
        var offset: CGPoint = .zero
        var guides: [SnapGuide] = []
    }

    // Proves nearest independent axes, range boundaries, deterministic ties, and
    // final-coordinate guides for rects, drawing points, and Measure pixel edges.
    @Test(arguments: [
        Fixture(name: "window edge and unrelated pixel edge",
                rect: CGRect(x: 8, y: 31, width: 10, height: 10),
                targets: [.rect(CGRect(x: 20, y: 0, width: 100, height: 100)), .y(30, span: 0...80)],
                offset: CGPoint(x: 2, y: -1),
                guides: [SnapGuide(start: CGPoint(x: 20, y: 0), end: CGPoint(x: 20, y: 100)),
                         SnapGuide(start: CGPoint(x: 0, y: 30), end: CGPoint(x: 80, y: 30))]),
        Fixture(name: "display centre",
                points: [CGPoint(x: 49, y: 52)], targets: [.rect(CGRect(x: 0, y: 0, width: 100, height: 100))],
                offset: CGPoint(x: 1, y: -2),
                guides: [SnapGuide(start: CGPoint(x: 50, y: 0), end: CGPoint(x: 50, y: 100)),
                         SnapGuide(start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50))]),
        Fixture(name: "nearest target wins and exact range is inclusive",
                points: [CGPoint(x: 12, y: -20)], targets: [.x(6), .x(17), .y(-26, span: -30...30)], range: 6,
                offset: CGPoint(x: 5, y: -6),
                guides: [SnapGuide(start: CGPoint(x: 17, y: -26), end: CGPoint(x: 17, y: -26)),
                         SnapGuide(start: CGPoint(x: -30, y: -26), end: CGPoint(x: 30, y: -26))]),
        Fixture(name: "ties prefer target order", points: [CGPoint(x: 10, y: 0)],
                targets: [.x(12, span: -10...10), .x(8, span: -30...30)],
                offset: CGPoint(x: 2, y: 0),
                guides: [SnapGuide(start: CGPoint(x: 12, y: -10), end: CGPoint(x: 12, y: 10))]),
        Fixture(name: "moving anchor tie prefers min before centre",
                rect: CGRect(x: 0, y: 20, width: 8, height: 10), targets: [.x(2)], range: 2,
                offset: CGPoint(x: 2, y: 0),
                guides: [SnapGuide(start: CGPoint(x: 2, y: 20), end: CGPoint(x: 2, y: 30))]),
        Fixture(name: "rectangle target ties prefer rectangle anchors before extra points",
                rect: CGRect(x: 0, y: 0, width: 20, height: 10), points: [CGPoint(x: 8, y: 0)],
                targets: [.rect(CGRect(x: 6, y: 100, width: 12, height: 10))], range: 2,
                offset: CGPoint(x: 2, y: 0),
                guides: [SnapGuide(start: CGPoint(x: 12, y: 0), end: CGPoint(x: 12, y: 110))]),
        Fixture(name: "rectangle target ties prefer the first drawing point",
                points: [CGPoint(x: 13, y: 0), CGPoint(x: 9, y: 0)],
                targets: [.rect(CGRect(x: 10, y: 100, width: 2, height: 10))], range: 1,
                offset: CGPoint(x: -1, y: 0),
                guides: [SnapGuide(start: CGPoint(x: 12, y: 0), end: CGPoint(x: 12, y: 110))]),
        Fixture(name: "explicit points supplement rectangle anchors",
                rect: CGRect(x: 0, y: 0, width: 20, height: 20), points: [CGPoint(x: 6, y: 8)],
                targets: [.x(7, span: 0...30)], range: 2, offset: CGPoint(x: 1, y: 0),
                guides: [SnapGuide(start: CGPoint(x: 7, y: 0), end: CGPoint(x: 7, y: 30))]),
        Fixture(name: "exact alignment still draws a guide", points: [CGPoint(x: 7, y: 10)],
                targets: [.x(7, span: 0...20)], range: 0,
                guides: [SnapGuide(start: CGPoint(x: 7, y: 0), end: CGPoint(x: 7, y: 20))]),
        Fixture(name: "Control skips snapping", points: [CGPoint(x: 10, y: 10)],
                targets: [.x(12), .y(12)], skip: true),
        Fixture(name: "nothing within range", points: [CGPoint(x: 0, y: 0)], targets: [.x(7), .y(-7)]),
        Fixture(name: "no targets", rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
        Fixture(name: "no moving geometry", targets: [.x(0), .y(0)])
    ])
    func snapping(fixture: Fixture) {
        let result = SnappingEngine.snap(rect: fixture.rect, points: fixture.points,
                                         targets: fixture.targets, range: fixture.range, skip: fixture.skip)
        #expect(result.offset == fixture.offset, "\(fixture.name)")
        #expect(result.guides == fixture.guides, "\(fixture.name)")
    }
}
