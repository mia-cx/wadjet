import Foundation
import Testing
import WadjetKit

struct ShapeWidgetsTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    static func near(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 1e-6) -> Bool { hypot(a.x - b.x, a.y - b.y) < e }
    static func shape(_ k: ShapeKind, _ rect: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
                      _ t: AnnotationTransform = .identity) -> Annotation {
        Annotation(kind: .shape(k, rect: rect), style: style, transform: t)
    }
    static func widget(_ a: Annotation, _ h: SelectionHandle, inset: CGFloat = 8) throws -> CGPoint {
        try #require(a.shapeWidgets(inset: inset).first { $0.handle == h }).at
    }

    // Proves a rectangle shows a corner widget in each corner, `inset` of
    // radius in, and dragging any of them inward rounds every corner by the
    // drag's travel along that corner's diagonal, clamped to half the shorter side
    @Test(arguments: [(0, CGFloat(10), CGFloat(10)), (2, 10, 10), (3, -50, 0), (1, 200, 40)])
    func rectangleCorner(corner: Int, inward: CGFloat, expected: CGFloat) throws {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 80)
        let a = Self.shape(.rectangle(cornerRadius: 0), rect)
        #expect(a.shapeWidgets(inset: 8).map(\.handle) == (0..<4).map { .cornerRadius($0) })
        #expect(Self.near(try Self.widget(a, .cornerRadius(0)), CGPoint(x: 8, y: 72)))
        #expect(Self.near(try Self.widget(a, .cornerRadius(2)), CGPoint(x: 112, y: 8)))
        let w = try Self.widget(a, .cornerRadius(corner))
        // each corner's inward diagonal, in y-up screen space
        let dir = [CGVector(dx: 1, dy: -1), CGVector(dx: -1, dy: -1), CGVector(dx: -1, dy: 1), CGVector(dx: 1, dy: 1)][corner]
        let r = a.dragging(.cornerRadius(corner), from: w,
                           to: CGPoint(x: w.x + dir.dx * inward, y: w.y + dir.dy * inward))
        guard case let .shape(.rectangle(radius), rect) = r.kind, rect == a.kind.bounds
        else { Issue.record(); return }
        #expect(abs(radius - expected) < 1e-6)
    }

    // Proves a polygon's corner widget rounds it: the sharp tip leaves the
    // outline, the radius stops where the arcs meet (a regular hexagon's
    // inradius), and its sides stay
    @Test func polygonCorner() throws {
        let a = Self.shape(.polygon(sides: 6))
        #expect(a.shapeWidgets(inset: 8).filter { if case .cornerRadius = $0.handle { true } else { false } }.count == 6)
        let w = try Self.widget(a, .cornerRadius(0)) // below the top vertex
        #expect(abs(w.x - 50) < 1e-6 && w.y < 100)
        let rounded = a.dragging(.cornerRadius(0), from: w, to: CGPoint(x: w.x, y: w.y - 20))
        guard case let .shape(.polygon(6, r), _) = rounded.kind else { Issue.record(); return }
        // a 120° corner: the arc centre travels 1/sin 60° per point of radius
        #expect(abs(r - 20 * sin(CGFloat.pi / 3)) < 1e-6)
        #expect(!PathGeometry.path(for: rounded).contains(CGPoint(x: 50, y: 99)))
        #expect(PathGeometry.path(for: a).contains(CGPoint(x: 50, y: 99)))
        let full = a.dragging(.cornerRadius(0), from: w, to: CGPoint(x: w.x, y: w.y - 500))
        // a square rect holds a regular hexagon: the arcs meet at its inradius
        #expect(full.kind == .shape(.polygon(sides: 6, cornerRadius: ShapeKind.polygon(sides: 6)
            .maxCornerRadius(in: CGRect(x: 0, y: 0, width: 100, height: 100))), rect: a.kind.bounds))
        #expect(abs(ShapeKind.polygon(sides: 6).maxCornerRadius(in: CGRect(x: 0, y: 0, width: 100, height: 100))
                    - 50 * cos(CGFloat.pi / 6)) < 1e-6)
    }

    // Proves the sides diamond adds a side per step dragged down and removes
    // one per step up, within the menu's range, keeping the corner radius
    @Test(arguments: [(CGFloat(-20), 7), (10, 4), (-500, 12), (500, 3), (4, 5)])
    func sides(dy: CGFloat, expected: Int) throws {
        let a = Self.shape(.polygon(sides: 5, cornerRadius: 6))
        let w = try Self.widget(a, .sides)
        #expect(Self.near(w, CGPoint(x: 100, y: 75)))
        let r = a.dragging(.sides, from: w, to: CGPoint(x: w.x + 30, y: w.y + dy))
        #expect(r.kind == .shape(.polygon(sides: expected, cornerRadius: 6), rect: a.kind.bounds))
    }

    // Proves the star's inner-radius dot sits on the top point's spoke at the
    // inner radius and follows the pointer along it, within the menu's range
    @Test(arguments: [(CGFloat(10), CGFloat(0.6)), (-10, 0.2), (200, 0.8)])
    func innerRadius(dy: CGFloat, expected: CGFloat) throws {
        let a = Self.shape(.star(points: 5, innerRatio: 0.4))
        let w = try Self.widget(a, .innerRadius)
        #expect(Self.near(w, CGPoint(x: 50, y: 70)))
        guard case let .shape(.star(5, ratio), _) = a.dragging(.innerRadius, from: w, to: CGPoint(x: w.x, y: w.y + dy)).kind
        else { Issue.record(); return }
        #expect(abs(ratio - expected) < 1e-6)
    }

    // Proves a rotated shape's widget sits on its rotated corner and a drag
    // along that corner's on-screen diagonal still rounds it
    @Test func rotatedCorner() throws {
        let a = Self.shape(.rectangle(cornerRadius: 0), CGRect(x: 0, y: 0, width: 100, height: 100),
                           AnnotationTransform(rotation: .pi / 2))
        let w = try Self.widget(a, .cornerRadius(0))
        // the top-left corner (0,100) turns a quarter about (50,50) to (0,0)
        #expect(Self.near(w, CGPoint(x: 8, y: 8)))
        let r = a.dragging(.cornerRadius(0), from: w, to: CGPoint(x: w.x + 5, y: w.y + 5))
        guard case let .shape(.rectangle(radius), _) = r.kind else { Issue.record(); return }
        #expect(abs(radius - 5) < 1e-6)
    }

    // Proves which shapes get which widgets, under Select's grips and Direct
    // Select's chrome alike, and that a shape too small to hold them shows none
    @Test func whichWidgets() {
        func kinds(_ k: ShapeKind, _ side: CGFloat = 100) -> [SelectionHandle] {
            let a = Self.shape(k, CGRect(x: 0, y: 0, width: side, height: side))
            return a.handles(.frame, minExtent: 8, rotateOffset: 20).map(\.handle).filter(\.isShapeWidget)
        }
        #expect(kinds(.ellipse).isEmpty)
        #expect(kinds(.star(points: 5, innerRatio: 0.4)) == [.innerRadius])
        #expect(kinds(.polygon(sides: 3)).last == .sides)
        #expect(kinds(.rectangle(cornerRadius: 0), 12).isEmpty)
        let a = Self.shape(.polygon(sides: 4))
        var nodes = NodeSelection()
        nodes.show(a.id, adding: false)
        let chrome = DirectSelectChrome([a], selection: nodes, inset: 8)
        #expect(chrome.grips.map(\.handle).filter(\.isShapeWidget).count == 5)
        #expect(chrome.hit(at: CGPoint(x: 100, y: 75), radius: 4) == .grip(a.id, .sides))
    }

    // Proves a polygon's corner radius is an option the Shapes menu shares
    // with rectangles (Mixed across both), and older files without it still read
    @Test func polygonRadiusOption() throws {
        let kinds: [ShapeKind] = [.rectangle(cornerRadius: 4), .polygon(sides: 5, cornerRadius: 4)]
        #expect(Mixed(kinds.compactMap { $0.value(of: .cornerRadius) }) == .same(4))
        #expect(ShapeKind.polygon(sides: 5).setting(.cornerRadius, to: 9) == .polygon(sides: 5, cornerRadius: 9))
        let old = try JSONDecoder().decode(ShapeKind.self, from: Data(#"{"polygon":{"sides":5}}"#.utf8))
        #expect(old == .polygon(sides: 5, cornerRadius: 0))
        #expect(String(decoding: try JSONEncoder().encode(old), as: UTF8.self) == #"{"polygon":{"sides":5}}"#)
        for k: ShapeKind in [.polygon(sides: 7, cornerRadius: 3), .rectangle(cornerRadius: 2), .ellipse,
                             .star(points: 6, innerRatio: 0.5)] {
            #expect(try JSONDecoder().decode(ShapeKind.self, from: JSONEncoder().encode(k)) == k)
        }
    }
}
