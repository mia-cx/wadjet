import Foundation
import Testing
import WadjetKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }
private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
}

struct AnnotationGroupTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    static func rect(_ r: CGRect) -> Annotation { Annotation(kind: .shape(.ellipse, rect: r), style: style) }
    static func box(_ a: Annotation) -> CGRect {
        guard case let .shape(_, r) = a.kind else { return .null }
        return r
    }
    // two boxes whose shared bounding box is (0,0)–(100,50)
    static let left = rect(CGRect(x: 0, y: 0, width: 20, height: 20))
    static let right = rect(CGRect(x: 60, y: 10, width: 40, height: 40))

    // Proves the shared box hugs every Annotation's on-screen frame, rotation included.
    @Test func bounds() {
        var turned = Self.rect(CGRect(x: 200, y: 0, width: 20, height: 20))
        turned.transform.rotation = .pi / 4
        let half = 10 * 2.0.squareRoot()
        #expect(near(AnnotationGroup.bounds(of: [Self.left, turned]),
                     CGRect(x: 0, y: 10 - half, width: 210 + half, height: 2 * half)))
    }

    // Proves a corner drag scales every Annotation about the opposite corner:
    // positions and sizes both stretch, x and y independently.
    @Test func resizeCorner() {
        let r = AnnotationGroup.resized([Self.left, Self.right], .resize(x: 1, y: 1),
                                        from: CGPoint(x: 100, y: 50), to: CGPoint(x: 200, y: 75))
        #expect(near(Self.box(r[0]), CGRect(x: 0, y: 0, width: 40, height: 30)))
        #expect(near(Self.box(r[1]), CGRect(x: 120, y: 15, width: 80, height: 60)))
    }

    // Proves Shift keeps the box's proportions (the larger scale wins) and
    // Option scales about the centre instead of the opposite grip.
    @Test func resizeProportionalFromCentre() {
        let p = AnnotationGroup.resized([Self.left, Self.right], .resize(x: 1, y: 1),
                                        from: CGPoint(x: 100, y: 50), to: CGPoint(x: 200, y: 60),
                                        proportional: true)
        #expect(near(AnnotationGroup.bounds(of: p), CGRect(x: 0, y: 0, width: 200, height: 100)))
        let c = AnnotationGroup.resized([Self.left, Self.right], .resize(x: 1, y: 0),
                                        from: CGPoint(x: 100, y: 25), to: CGPoint(x: 150, y: 25),
                                        fromCentre: true)
        #expect(near(AnnotationGroup.bounds(of: c), CGRect(x: -50, y: 0, width: 200, height: 50)))
    }

    // Proves dragging a grip past the opposite edge stops at a sliver
    // instead of collapsing or inverting the Annotations.
    @Test func resizeNeverInverts() {
        let r = AnnotationGroup.resized([Self.left, Self.right], .resize(x: 1, y: 0),
                                        from: CGPoint(x: 100, y: 25), to: CGPoint(x: -300, y: 25))
        let b = AnnotationGroup.bounds(of: r)
        #expect(b.width > 0 && b.width <= 1 + 1e-6 && near(b.minX, 0))
    }

    // Proves a rotated Annotation in a proportional resize keeps its rotation
    // and lands where the scaled box puts it.
    @Test func resizeKeepsRotation() {
        var turned = Self.rect(CGRect(x: 60, y: 10, width: 40, height: 40))
        turned.transform.rotation = 0.3
        let big = AnnotationGroup.scaled([Self.left, turned], x: 2, y: 2, about: .zero)
        #expect(near(Self.box(big[1]), CGRect(x: 120, y: 20, width: 80, height: 80)))
        #expect(near(big[1].transform.rotation, 0.3))
    }

    // Proves rotating the group turns every Annotation about the box's
    // centre: each one's centre swings round it and its own rotation adds up.
    @Test func rotate() {
        let r = AnnotationGroup.rotated([Self.left, Self.right], by: .pi / 2)
        // the box (0,0)–(100,50) turns about (50,25): left's centre (10,10) goes to (65,-15)
        #expect(near(Self.box(r[0]), CGRect(x: 55, y: -25, width: 20, height: 20)))
        #expect(near(r[0].transform.rotation, .pi / 2) && near(r[1].transform.rotation, .pi / 2))
    }

    // Proves a rotate-grip drag measures its angle about the box's centre.
    @Test func rotateDrag() {
        let r = AnnotationGroup.dragging([Self.left, Self.right], .rotate,
                                         from: CGPoint(x: 100, y: 25), to: CGPoint(x: 50, y: 75))
        #expect(near(r[0].transform.rotation, .pi / 2))
    }

    // Proves Flip Horizontal mirrors the group across the box's vertical centre line.
    @Test func flip() {
        let r = AnnotationGroup.flipped([Self.left, Self.right], horizontally: true)
        #expect(near(Self.box(r[0]), CGRect(x: 80, y: 0, width: 20, height: 20)))
        #expect(near(Self.box(r[1]), CGRect(x: 0, y: 10, width: 40, height: 40)))
        #expect(r[0].transform.flipHorizontal)
    }

    // Proves the shared box's grips: four corners, four edge midpoints, and
    // the rotate grip above the top edge — and a press finds the nearest one.
    @Test func handles() {
        let b = CGRect(x: 0, y: 0, width: 100, height: 50)
        let hs = AnnotationGroup.handles(of: b, minExtent: 12, rotateOffset: 20)
        #expect(hs.count == 9)
        #expect(hs.contains { $0.handle == .rotate && $0.at == CGPoint(x: 50, y: 70) })
        #expect(AnnotationGroup.handle(at: CGPoint(x: 99, y: 2), of: b, radius: 6,
                                       minExtent: 12, rotateOffset: 20) == .resize(x: 1, y: -1))
        #expect(AnnotationGroup.handle(at: CGPoint(x: 50, y: 25), of: b, radius: 6,
                                       minExtent: 12, rotateOffset: 20) == nil)
    }
}

struct LayerStackSelectionTests {
    static func a() -> Annotation {
        Annotation(kind: .line(start: .zero, end: CGPoint(x: 1, y: 1)),
                   style: AnnotationStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 1), width: 1))
    }

    // Proves restacking several Annotations moves each one past its unselected
    // neighbour (or all the way) while keeping their order among themselves.
    @Test(arguments: [
        (LayerStack.Restack.up, [1, 0, 2, 4, 3]),
        (.down, [0, 1, 3, 2, 4]),
        (.front, [1, 2, 4, 0, 3]),
        (.back, [0, 3, 1, 2, 4]),
    ])
    func restack(move: LayerStack.Restack, order: [Int]) {
        let xs = (0..<5).map { _ in Self.a() }
        var s = LayerStack(xs)
        s.restack(Set([xs[0].id, xs[3].id]), move)
        #expect(s.annotations.map(\.id) == order.map { xs[$0].id })
    }

    // Proves a selection already at the top stays put on Bring Forward.
    @Test func restackAtTop() {
        let xs = (0..<3).map { _ in Self.a() }
        var s = LayerStack(xs)
        s.restack(Set([xs[1].id, xs[2].id]), .up)
        #expect(s.annotations.map(\.id) == xs.map(\.id))
    }
}

struct MixedTests {
    // Proves a setting reads as one value when every selected Annotation
    // agrees, as mixed when they differ, and as nothing when none is selected.
    @Test func resolve() {
        #expect(Mixed([4.0, 4.0]) == .same(4.0))
        #expect(Mixed([4.0, 2.0]) == .mixed)
        #expect(Mixed([Double]()) == nil)
        #expect(Mixed([4.0, 2.0])?.value == nil && Mixed([4.0])?.value == 4)
    }

    // Proves the shared style resolves field by field: equal colours stay,
    // differing widths turn mixed.
    @Test func sharedStyle() {
        let red = RGBAColour(red: 1, green: 0, blue: 0, alpha: 1)
        let a = AnnotationStyle(colour: red, width: 4), b = AnnotationStyle(colour: red, width: 8, head: .openArrow)
        let s = AnnotationStyle.Shared([a, b])
        #expect(s?.colour == .same(red))
        #expect(s?.width == .mixed)
        #expect(s?.head == .mixed && s?.tail == .same(LineEnd.none))
        #expect(AnnotationStyle.Shared([]) == nil)
    }
}
