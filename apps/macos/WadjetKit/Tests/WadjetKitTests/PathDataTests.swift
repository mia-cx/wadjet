import Testing
import Foundation
import WadjetKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-3 }
private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

struct PathDataTests {
    // a wiggly fixture, like StrokeFitterTests'
    static let wavy: [CGPoint] = (0...80).map { index in
        CGPoint(x: Double(index) * 2, y: 20 * sin(Double(index) / 8) + (index.isMultiple(of: 2) ? 1 : -1))
    }

    // a fitted stroke chains the fitter's segments: first anchor = first
    // sample, last anchor = last sample, handles are the control points
    @Test func fittedChainsSegments() {
        let raw = Self.wavy
        let d = PathData.fitted(raw, smoothing: 0.5)!
        let stroke = StrokeFitter.fit(raw, smoothing: 0.5)
        #expect(d.nodes.count == stroke.segments.count + 1)
        #expect(d.nodes.first!.anchor == raw.first! && d.nodes.last!.anchor == raw.last!)
        for (i, s) in stroke.segments.enumerated() {
            #expect(d.nodes[i].handleOut == s.control1)
            #expect(d.nodes[i + 1].handleIn == s.control2)
        }
        #expect(d.nodes.last!.handleOut == nil)
        #expect(d.rawPoints == raw && d.smoothing == 0.5 && !d.closed)
    }

    // fewer than 2 distinct points can't fit a segment
    @Test(arguments: [[CGPoint(x: 1, y: 1)], [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1)]])
    func fittedNeedsDistinctPoints(raw: [CGPoint]) {
        #expect(PathData.fitted(raw, smoothing: 0.5) == nil)
    }

    // raising Smoothing never adds nodes; raw samples survive; a Pen path
    // (no raw samples) comes back unchanged
    @Test func refit() {
        let d = PathData.fitted(Self.wavy, smoothing: 0)!
        #expect(d.refitted(smoothing: 1).nodes.count <= d.refitted(smoothing: 0.5).nodes.count)
        #expect(d.refitted(smoothing: 0.8).rawPoints == Self.wavy)
        let pen = PathData(nodes: [PathNode(anchor: .zero), PathNode(anchor: CGPoint(x: 10, y: 0))])
        #expect(pen.refitted(smoothing: 1) == pen)
    }

    // moving a Brush path moves its samples too, so a refit lands where the
    // moved path is
    @Test func movedBrushRefitsInPlace() {
        let d = PathData.fitted(Self.wavy, smoothing: 0.5)!
        let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        let moved = Annotation(kind: .path(d), style: style)
            .moved(by: CGVector(dx: 500, dy: 300))
        guard case let .path(m) = moved.kind else { Issue.record(); return }
        #expect(near(m.rawPoints!.first!, CGPoint(x: Self.wavy.first!.x + 500,
                                                 y: Self.wavy.first!.y + 300)))
        guard case let .path(refit) = Annotation(kind: .path(m.refitted(smoothing: 0.8)),
                                                 style: style).kind else { Issue.record(); return }
        #expect(near(refit.nodes.first!.anchor, CGPoint(x: 500, y: 300 + Self.wavy.first!.y)))
    }

    // refitting moves a transformed stroke's bounds centre — the transform's
    // pivot — so Annotation.refitted pins the first raw sample's screen
    // position. Pullfrog measured a rotated stroke's end jumping (22,−18) →
    // (20,−20) without it.
    @Test func refitKeepsARotatedStrokesEnds() {
        let d = PathData.fitted([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                 CGPoint(x: 20, y: 4), CGPoint(x: 30, y: 0),
                                 CGPoint(x: 40, y: 0)], smoothing: 0.5)!
        let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        let a = Annotation(kind: .path(d), style: style,
                           transform: AnnotationTransform(rotation: .pi / 2))
        let refit = a.refitted(smoothing: 1)
        func screenEnd(_ e: Annotation, _ i: Int) -> CGPoint {
            guard case let .path(p) = e.kind else { Issue.record(); return .zero }
            return p.rawPoints![i].applying(e.affineTransform)
        }
        #expect(near(screenEnd(refit, 0), screenEnd(a, 0)))
        #expect(near(screenEnd(refit, 4), screenEnd(a, 4)))
    }

    // a Brush stroke (rawPoints set) gets frame grips; a Pen path gets node grips
    @Test func brushGetsFrameHandles() {
        let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        let brush = Annotation(kind: .path(PathData.fitted(Self.wavy, smoothing: 0.5)!), style: style)
        #expect(brush.handles(minExtent: 12, rotateOffset: 20).map(\.handle)
            .allSatisfy { if case .resize = $0 { return true }; return $0 == .rotate })
        let pen = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: .zero),
                                                         PathNode(anchor: CGPoint(x: 10, y: 0))])),
                             style: style)
        #expect(pen.handles(minExtent: 12, rotateOffset: 20).map(\.handle)
            == [.vertex(0), .vertex(1), .rotate])
    }

    // style blend decodes absent as normal and round-trips
    @Test func blendRoundTrip() throws {
        let old = Data(#"{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}"#.utf8)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: old).blend == .normal)
        let s = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 20,
                                opacity: 0.4, blend: .multiply)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(s)) == s)
    }

    // raw samples and smoothing ride annotations.json; absent decodes nil
    @Test func rawRoundTrip() throws {
        var stack = LayerStack()
        stack.add(Annotation(kind: .path(PathData.fitted(Self.wavy, smoothing: 0.7)!),
                             style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1),
                                                    width: 4)))
        let s = try LayerStack(json: stack.json())
        guard case let .path(d) = s.annotations[0].kind else { Issue.record(); return }
        #expect(d.rawPoints == Self.wavy && d.smoothing == 0.7)
        let kind = try JSONDecoder().decode(AnnotationKind.self, from: Data(
            #"{"path":{"nodes":[{"anchor":[0,0]},{"anchor":[1,1]}],"closed":false}}"#.utf8))
        guard case let .path(open) = kind else { Issue.record(); return }
        #expect(open.rawPoints == nil && open.smoothing == nil)
    }

    // MarkupTool.smoothing decodes absent as nil and round-trips a value
    @Test func smoothingRoundTrip() throws {
        #expect(try JSONDecoder().decode(WadjetConfig.MarkupTool.self, from: Data("{}".utf8)).smoothing == nil)
        let t = WadjetConfig.MarkupTool(smoothing: 0.8)
        #expect(try JSONDecoder().decode(WadjetConfig.MarkupTool.self,
                                         from: JSONEncoder().encode(t)).smoothing == 0.8)
    }
}
