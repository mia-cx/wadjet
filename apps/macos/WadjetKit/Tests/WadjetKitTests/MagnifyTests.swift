import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct MagnifyTests {
    // Proves a Magnify Annotation round-trips through LayerStack as one flat
    // JSON object — rects as 4-element arrays, zoom/border absent when nil,
    // every option key defaulting when missing.
    @Test func magnifierJSONRoundTrip() throws {
        var options = MagnifierOptions()
        options.border = RGBAColour(red: 0, green: 1, blue: 0, alpha: 1)
        options.scaling = .lanczos
        let cases = [
            Magnifier(source: CGRect(x: 1, y: 2, width: 30, height: 40),
                      frame: CGRect(x: 100, y: 50, width: 160, height: 200), zoom: nil,
                      options: .init()),
            Magnifier(source: CGRect(x: -20, y: 5, width: 10, height: 10),
                      frame: CGRect(x: 0, y: 0, width: 80, height: 80), zoom: 3,
                      options: options),
            Magnifier(source: .zero, frame: .zero, zoom: 8,
                      options: .init(shape: .circle, leader: false, glass: false)),
        ]
        let stack = LayerStack(cases.map {
            Annotation(kind: .magnify($0), style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))
        })
        let decoded = try LayerStack(json: stack.json())
        #expect(decoded == stack)
        // the exact wire shape: flat, rects as arrays, nil zoom/border omitted
        var flat = Magnifier(source: CGRect(x: 1, y: 2, width: 3, height: 4),
                             frame: CGRect(x: 5, y: 6, width: 7, height: 8), zoom: nil,
                             options: .init(border: RGBAColour(red: 1, green: 1, blue: 1, alpha: 1)))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(flat)) as? [String: Any])
        #expect(object["source"] as? [Double] == [1, 2, 3, 4])
        #expect(object["frame"] as? [Double] == [5, 6, 7, 8])
        #expect(object["zoom"] == nil)
        #expect(object["border"] is [String: Double])
        #expect(object["shape"] as? String == "superellipse")
        flat.options.border = nil
        let bare = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(flat)) as? [String: Any])
        #expect(bare["border"] == nil)
        // an empty object decodes to the stock options
        #expect(try JSONDecoder().decode(MagnifierOptions.self, from: Data("{}".utf8)) == .init())
    }

    // Proves auto zoom follows the source's longer side: 4× at ≤64, 2× at ≥256, linear between.
    @Test func autoZoomFollowsLongerSide() {
        #expect(MagnifyZoom.auto(for: CGSize(width: 10, height: 8)) == 4)
        #expect(MagnifyZoom.auto(for: CGSize(width: 64, height: 64)) == 4)
        #expect(MagnifyZoom.auto(for: CGSize(width: 256, height: 100)) == 2)
        #expect(MagnifyZoom.auto(for: CGSize(width: 1000, height: 1000)) == 2)
        #expect(MagnifyZoom.auto(for: CGSize(width: 160, height: 10)) == 3)
        #expect(MagnifyZoom.auto(for: CGSize(width: 20, height: 160)) == 3)
    }

    // Proves scroll zoom steps on the quarter grid and clamps to 1.5…8.
    @Test func steppedZoom() {
        #expect(MagnifyZoom.stepped(3, by: 1) == 3.25)
        #expect(MagnifyZoom.stepped(3.1, by: 1) == 3.25)
        #expect(MagnifyZoom.stepped(2, by: -100) == 1.5)
        #expect(MagnifyZoom.stepped(7, by: 100) == 8)
    }

    // Proves a fresh Magnify lands opposite the source's nearest display edge
    // with a 24 pt gap, sized 64…320 pt, fully inside the display's margin.
    @Test func placementOppositeNearestEdge() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func placed(nearX x: CGFloat, y: CGFloat, w: CGFloat = 40, h: CGFloat = 40,
                    shape: MagnifierShape = .superellipse) -> Magnifier {
            Magnifier.placed(source: CGRect(x: x, y: y, width: w, height: h),
                             options: .init(shape: shape), on: display)
        }
        // near the left edge → right of the source, vertically centred
        var m = placed(nearX: 20, y: 400)
        #expect(m.frame.minX == 84) // 20 + 40 + a 24 pt gap
        #expect(m.frame.midY == 420)
        // right → left of the source
        m = placed(nearX: 1380, y: 400)
        #expect(m.frame.maxX == 1356)
        // bottom → above, horizontally centred
        m = placed(nearX: 700, y: 10)
        #expect(m.frame.minY == 74)
        #expect(m.frame.midX == 720)
        // top → below
        m = placed(nearX: 700, y: 850)
        #expect(m.frame.maxY == 826)
        // a corner source still lands fully inside the margin
        m = placed(nearX: 0, y: 0)
        #expect(display.insetBy(dx: 8, dy: 8).contains(m.frame))
        // a display at a negative origin works
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let off = Magnifier.placed(source: CGRect(x: -700, y: 430, width: 40, height: 40),
                                   options: .init(), on: left)
        #expect(left.insetBy(dx: 8, dy: 8).contains(off.frame))
        // circles are square — the larger of the two clamped sides
        m = placed(nearX: 700, y: 400, w: 100, h: 20, shape: .circle)
        #expect(m.frame.width == m.frame.height)
        // size clamps: tiny source → 64, huge → 320
        #expect(placed(nearX: 700, y: 400, w: 2, h: 2).frame.width == 64)
        #expect(placed(nearX: 700, y: 400, w: 500, h: 500).frame.width == 320)
        // zoom starts on auto
        #expect(placed(nearX: 20, y: 400).zoom == nil)
    }

    // Proves the leader runs from the source's edge to the magnifier's shape
    // edge along the centre line — and is nil when they overlap.
    @Test func leaderRunsEdgeToEdge() throws {
        // centres level, so the horizontal ray exits each at its midpoint
        let m = Magnifier(source: CGRect(x: 0, y: 0, width: 20, height: 20),
                          frame: CGRect(x: 60, y: -10, width: 40, height: 40), zoom: 4,
                          options: .init(shape: .circle))
        let l = try #require(m.leader)
        #expect(l.start == CGPoint(x: 20, y: 10)) // the source's right-edge midpoint
        #expect(l.end == CGPoint(x: 60, y: 10))   // the circle's leftmost point
        // a superellipse end satisfies |x/a|^4 + |y/b|^4 = 1
        let s = Magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                          frame: CGRect(x: 30, y: 30, width: 60, height: 60), zoom: 4,
                          options: .init(shape: .superellipse))
        let end = try #require(s.leader).end
        let dx = (end.x - s.frame.midX) / 30, dy = (end.y - s.frame.midY) / 30
        #expect(abs(pow(dx * dx * dx * dx + dy * dy * dy * dy, 0.25) - 1) < 0.001)
        // overlapping source and frame leave no gap for a leader
        let overlap = Magnifier(source: CGRect(x: 0, y: 0, width: 100, height: 100),
                                frame: CGRect(x: 20, y: 0, width: 100, height: 100), zoom: 4,
                                options: .init())
        #expect(overlap.leader == nil)
        // leader off → the path is just the source rect
        var off = s
        off.options.leader = false
        let a = Annotation(kind: .magnify(off),
                           style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))
        #expect(PathGeometry.path(for: a).boundingBox == s.source)
    }

    // Proves the drawn/selectable source outline is the magnifier's shape:
    // its corners hit for the rectangle only, its mid-edges for all three,
    // and the superellipse's 45° point for the superellipse only.
    @Test func sourceOutlineTakesMagnifierShape() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        func annotation(_ shape: MagnifierShape) -> Annotation {
            Annotation(kind: .magnify(Magnifier(source: source,
                                                frame: CGRect(x: 400, y: 400, width: 100, height: 100),
                                                options: .init(shape: shape, leader: false))),
                       style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))
        }
        func hits(_ shape: MagnifierShape, _ x: CGFloat, _ y: CGFloat) -> Bool {
            PathGeometry.hitTest(annotation(shape), at: CGPoint(x: x, y: y), tolerance: 0)
        }
        // (0,0): the rect's corner — the circle and superellipse bow inside it
        #expect(hits(.rectangle, 0, 0))
        #expect(!hits(.superellipse, 0, 0))
        #expect(!hits(.circle, 0, 0))
        // (50,0): a mid-edge point all three shapes share
        for shape in MagnifierShape.allCases {
            #expect(hits(shape, 50, 0))
        }
        // 50 + 50·(1/2)^(1/4): on |x/a|^4 + |y/b|^4 = 1 at 45°, inside the
        // rect's corner and outside the circle's √2·a diagonal reach
        let d = 50 + 50 * pow(0.5, 0.25)
        #expect(hits(.superellipse, d, d))
        #expect(!hits(.rectangle, d, d))
        #expect(!hits(.circle, d, d))
    }

    // Proves the leader starts where the centre ray exits the source's own
    // shape — the L∞ box for a rectangle, u²+v²=1 for a circle, u⁴+v⁴=1 for
    // the superellipse — not the source's bounding box.
    @Test func leaderStartsOnShapedOutline() throws {
        // a diagonal ray: 40×20 source at the origin, frame down-right
        for shape in MagnifierShape.allCases {
            let m = Magnifier(source: CGRect(x: 0, y: 0, width: 40, height: 20),
                              frame: CGRect(x: 200, y: 150, width: 80, height: 80),
                              options: .init(shape: shape))
            let l = try #require(m.leader)
            // the start sits on the ray from the source's centre to the frame's
            let cross = (l.start.x - 20) * 180 - (l.start.y - 10) * 220
            #expect(abs(cross) < 1e-6)
            let u = (l.start.x - 20) / 20, v = (l.start.y - 10) / 10
            switch shape {
            case .rectangle:
                #expect(abs(max(abs(u), abs(v)) - 1) < 1e-6)
            case .circle:
                #expect(abs(u * u + v * v - 1) < 1e-6)
            case .superellipse:
                #expect(abs(u * u * u * u + v * v * v * v - 1) < 1e-6)
            }
        }
    }

    // Proves the shape paths mask inside their edge: corners belong to
    // rectangle and superellipse only, mid-edge neighbourhoods to all three.
    @Test func shapeMasks() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        func inside(_ x: CGFloat, _ y: CGFloat, _ shape: MagnifierShape) -> Bool {
            shape.path(in: rect).contains(CGPoint(x: 50 + x * 50, y: 50 + y * 50))
        }
        for shape in MagnifierShape.allCases {
            #expect(inside(0, 0, shape))
            #expect(inside(0.99, 0, shape))
            #expect(!inside(1.01, 0, shape))
        }
        #expect(inside(0.9, 0.9, .rectangle))
        #expect(!inside(0.9, 0.9, .superellipse))
        #expect(!inside(0.9, 0.9, .circle))
        #expect(inside(0.78, 0.78, .rectangle))
        #expect(inside(0.78, 0.78, .superellipse))
        #expect(!inside(0.78, 0.78, .circle))
    }

    // Proves a Magnify's geometry: the viewport is the frame scaled by zoom
    // centred on the source, hit-testing covers the magnifier and the source
    // outline, the frame moves/resizes without rotate or flips, and moving it
    // never re-aims the source.
    @Test func magnifierGeometry() throws {
        let m = Magnifier(source: CGRect(x: 0, y: 0, width: 20, height: 20),
                          frame: CGRect(x: 100, y: 100, width: 200, height: 100), zoom: 4,
                          options: .init(shape: .rectangle))
        // viewport: 200×100 at 4× shows 50×25 centred on the source's centre
        #expect(m.viewport == CGRect(x: -15, y: -2.5, width: 50, height: 25))
        let a = Annotation(kind: .magnify(m),
                           style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))
        // hit: inside the magnifier, on the source outline, not between them
        #expect(PathGeometry.hitTest(a, at: CGPoint(x: 150, y: 150)))
        #expect(PathGeometry.hitTest(a, at: CGPoint(x: 20, y: 10)))
        #expect(!PathGeometry.hitTest(a, at: CGPoint(x: 40, y: 90)))
        // grips: resizes but no rotate
        let handles = a.handles(minExtent: 12, rotateOffset: 20).map(\.handle)
        #expect(handles.contains(.resize(x: 1, y: 1)))
        #expect(!handles.contains(.rotate))
        // a grip dragged past its anchor re-standardizes — no flip, no rotation
        let flipped = a.dragging(.resize(x: 1, y: 1), from: CGPoint(x: 300, y: 200), to: CGPoint(x: 50, y: 50))
        #expect(flipped.transform == .identity)
        // moving offsets the frame, never the source
        let moved = a.moved(by: CGVector(dx: 7, dy: -3))
        guard case let .magnify(mm) = moved.kind else { Issue.record(); return }
        #expect(mm.frame == m.frame.offsetBy(dx: 7, dy: -3))
        #expect(mm.source == m.source)
        // and the transform stays identity whatever is recorded on it
        var t = a
        t.transform = .init(rotation: 1, flipHorizontal: true)
        #expect(t.affineTransform == .identity)
    }
}
