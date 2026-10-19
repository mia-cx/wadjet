import Testing
import Foundation
import WadjetKit

struct LayerStackTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    @Test func addRemoveClear() {
        var stack = LayerStack()
        let a = Annotation(kind: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0)), style: red4)
        let b = Annotation(kind: .line(start: CGPoint(x: 0, y: 5), end: CGPoint(x: 10, y: 5)), style: red4)
        stack.add(a); stack.add(b)
        #expect(stack.annotations == [a, b])
        stack.remove(id: a.id)
        #expect(stack.annotations == [b])
        stack.clear()
        #expect(stack.isEmpty)
    }

    // the front-most stroke wins where two lines cross; a miss returns nil
    @Test func topmostHit() {
        var stack = LayerStack()
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: red4)
        let b = Annotation(kind: .line(start: CGPoint(x: 50, y: -50), end: CGPoint(x: 50, y: 50)), style: red4)
        stack.add(a); stack.add(b)
        #expect(stack.topmost(at: CGPoint(x: 50, y: 0), tolerance: 0)?.id == b.id)
        #expect(stack.topmost(at: CGPoint(x: 500, y: 500), tolerance: 0) == nil)
    }

    // each Restack goes exactly as far as its name says; the edges are no-ops
    @Test func restack() {
        func stroke(_ y: CGFloat) -> Annotation {
            Annotation(kind: .line(start: CGPoint(x: 0, y: y), end: CGPoint(x: 10, y: y)), style: red4)
        }
        let a = stroke(0), b = stroke(1), c = stroke(2), d = stroke(3)
        let rows: [(Annotation.ID, LayerStack.Restack, [Annotation])] = [
            (b.id, .up, [a, c, b, d]),
            (b.id, .down, [b, a, c, d]),
            (b.id, .front, [a, c, d, b]),
            (c.id, .back, [c, a, b, d]),
            (d.id, .up, [a, b, c, d]),
            (a.id, .down, [a, b, c, d]),
        ]
        for (id, move, want) in rows {
            var stack = LayerStack([a, b, c, d])
            stack.restack(id, move)
            #expect(stack.annotations == want)
        }
    }

    // hidden and locked Annotations survive the annotations.json round trip
    @Test func hiddenAndLockedRoundTrip() throws {
        var stack = LayerStack()
        stack.add(Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 0)), style: red4, hidden: true))
        stack.add(Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 5)), style: red4, locked: true))
        #expect(try LayerStack(json: stack.json()) == stack)
    }

    // a hidden or locked Annotation is not what a click selects
    @Test func topmostSkipsHiddenAndLocked() {
        var stack = LayerStack()
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: red4)
        var b = Annotation(kind: .line(start: CGPoint(x: 50, y: -50), end: CGPoint(x: 50, y: 50)), style: red4)
        b.hidden = true
        stack.add(a); stack.add(b)
        #expect(stack.topmost(at: CGPoint(x: 50, y: 0), tolerance: 0)?.id == a.id)
        var locked = a
        locked.locked = true
        stack = LayerStack([locked, b])
        #expect(stack.topmost(at: CGPoint(x: 50, y: 0), tolerance: 0) == nil)
    }

    @Test func annotationsJSONRoundTrip() throws {
        // the first annotation predates `transform` (decodes as .identity) and
        // `hidden`/`locked` (decode as false)
        let fixture = """
            {"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"line":{"start":[10,20],"end":[110,20]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}},{"id":"7A2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A","kind":{"line":{"start":[0,0],"end":[5,5]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4},"transform":{"flipHorizontal":true,"flipVertical":false,"rotation":1.5}}]}
            """
        var expected = LayerStack()
        expected.add(Annotation(id: UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!,
                                kind: .line(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 20)),
                                style: red4))
        expected.add(Annotation(id: UUID(uuidString: "7A2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A")!,
                                kind: .line(start: .zero, end: CGPoint(x: 5, y: 5)),
                                style: red4,
                                transform: AnnotationTransform(rotation: 1.5, flipHorizontal: true)))
        let stack = try LayerStack(json: Data(fixture.utf8))
        #expect(stack == expected)
        #expect(try LayerStack(json: stack.json()) == stack)
    }

    // Proves every Censor method survives the annotations.json round trip, transform included.
    @Test func censorJSONRoundTrip() throws {
        let fixture = """
            {"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"censor":{"method":"blackOut","rect":[10,20,30,40]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4},"transform":{"flipHorizontal":false,"flipVertical":false,"rotation":0.5}},{"id":"7B2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A","kind":{"censor":{"method":{"blur":{"radius":12}},"rect":[0,0,5,5]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}},{"id":"8C3E4F5A-2D3E-4F4A-9E4F-3C4D5E6F7A8B","kind":{"censor":{"method":{"pixelate":{"blockSize":9}},"rect":[1,2,3,4]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}}]}
            """
        var expected = LayerStack()
        expected.add(Annotation(id: UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!,
                                kind: .censor(rect: CGRect(x: 10, y: 20, width: 30, height: 40),
                                              method: .blackOut),
                                style: red4,
                                transform: AnnotationTransform(rotation: 0.5)))
        expected.add(Annotation(id: UUID(uuidString: "7B2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A")!,
                                kind: .censor(rect: CGRect(x: 0, y: 0, width: 5, height: 5),
                                              method: .blur(radius: 12)),
                                style: red4))
        expected.add(Annotation(id: UUID(uuidString: "8C3E4F5A-2D3E-4F4A-9E4F-3C4D5E6F7A8B")!,
                                kind: .censor(rect: CGRect(x: 1, y: 2, width: 3, height: 4),
                                              method: .pixelate(blockSize: 9)),
                                style: red4))
        let stack = try LayerStack(json: Data(fixture.utf8))
        #expect(stack == expected)
        #expect(try LayerStack(json: stack.json()) == stack)
    }

    // Proves styles saved before Shapes decode unfilled and stroked, and a
    // filled, unstroked style survives a save/load round trip.
    @Test func styleJSONRoundTrip() throws {
        let old = try JSONDecoder().decode(AnnotationStyle.self, from: Data(
            #"{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}"#.utf8))
        #expect(old.fill == nil && old.stroked)
        let filled = AnnotationStyle(colour: old.colour, width: 4,
            fill: RGBAColour(red: 0, green: 0, blue: 1, alpha: 1), stroked: false)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(filled)) == filled)
    }

    // Proves a shape on the wire — {"shape":{"kind":{…},"rect":[x,y,w,h]}} —
    // decodes to the expected Annotation and round-trips.
    @Test func shapeAnnotationsJSONRoundTrip() throws {
        let fixture = """
            {"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"shape":{"kind":{"star":{"innerRatio":0.4,"points":5}},"rect":[0,0,100,50]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}}]}
            """
        var expected = LayerStack()
        expected.add(Annotation(id: UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!,
                                kind: .shape(.star(points: 5, innerRatio: 0.4),
                                             rect: CGRect(x: 0, y: 0, width: 100, height: 50)),
                                style: red4))
        let stack = try LayerStack(json: Data(fixture.utf8))
        #expect(stack == expected)
        #expect(try LayerStack(json: stack.json()) == stack)
    }

    // Proves a counter on the wire — {"counter":{"center":[x,y],"radius":…,
    // "value":…,"format":"letters"}} — decodes to the expected Annotation and
    // round-trips.
    @Test func counterAnnotationsJSONRoundTrip() throws {
        let fixture = """
            {"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"counter":{"center":[50,60],"format":"letters","radius":14,"value":3}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}}]}
            """
        var expected = LayerStack()
        expected.add(Annotation(id: UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!,
                                kind: .counter(center: CGPoint(x: 50, y: 60), radius: 14,
                                               value: 3, format: .letters),
                                style: red4))
        let stack = try LayerStack(json: Data(fixture.utf8))
        #expect(stack == expected)
        #expect(try LayerStack(json: stack.json()) == stack)
    }

    // styles saved before ends/dashes existed decode with the defaults
    @Test func styleDefaultsDecode() throws {
        let fixture = Data(#"{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}"#.utf8)
        let s = try JSONDecoder().decode(AnnotationStyle.self, from: fixture)
        #expect(s.head == .none && s.tail == .none && s.dash == .solid && s.opacity == 1)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: JSONEncoder().encode(
            AnnotationStyle(colour: s.colour, width: 6, opacity: 0.5,
                            head: .filledArrow, tail: .dot, dash: .dotted)))
            == AnnotationStyle(colour: s.colour, width: 6, opacity: 0.5,
                               head: .filledArrow, tail: .dot, dash: .dotted))
    }

    // a bent Line round-trips through annotations.json; one saved before
    // `bend` existed decodes nil
    @Test func bentLineJSON() throws {
        var stack = LayerStack()
        stack.add(Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0),
                                       bend: CGPoint(x: 50, y: 40)), style: red4))
        #expect(try LayerStack(json: stack.json()) == stack)
        let old = Data(#"{"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"line":{"start":[0,0],"end":[100,0]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}}]}"#.utf8)
        let s = try LayerStack(json: old)
        guard case let .line(_, _, bend) = s.annotations[0].kind else { Issue.record(); return }
        #expect(bend == nil)
    }

    // Pen paths round-trip — nil and non-nil handles, closed and open — and
    // the style's fill with them; an old style without fill decodes nil
    @Test func pathJSONRoundTrip() throws {
        var stack = LayerStack()
        stack.add(Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 80, y: -20)),
            PathNode(anchor: CGPoint(x: 200, y: 0), handleOut: CGPoint(x: 220, y: 20)),
        ], closed: true)), style: red4))
        stack.add(Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: CGPoint(x: 0, y: 100)),
            PathNode(anchor: CGPoint(x: 100, y: 100)),
        ])), style: red4))
        #expect(try LayerStack(json: stack.json()) == stack)
        // a closed path in the wire form
        let fixture = Data(#"{"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"path":{"nodes":[{"anchor":[0,0]},{"anchor":[100,0],"in":[80,-20],"out":[120,20]}],"closed":true}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}}]}"#.utf8)
        let s = try LayerStack(json: fixture)
        guard case let .path(d) = s.annotations[0].kind else { Issue.record(); return }
        #expect(d.closed && d.nodes[0].handleIn == nil && d.nodes[0].handleOut == nil)
        #expect(d.nodes[1].handleIn == CGPoint(x: 80, y: -20)
                && d.nodes[1].handleOut == CGPoint(x: 120, y: 20))
    }

    @Test func styleFillRoundTrip() throws {
        let red = RGBAColour(red: 1, green: 0, blue: 0, alpha: 1)
        let filled = AnnotationStyle(colour: red, width: 4, fill: red)
        #expect(try JSONDecoder().decode(AnnotationStyle.self,
                                       from: JSONEncoder().encode(filled)) == filled)
        // styles saved before fills existed decode fill nil
        let old = Data(#"{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4,"head":"dot"}"#.utf8)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: old).fill == nil)
    }

    // Proves a .window Annotation on the wire — {"window":{"layer":"<UUID>",
    // "frame":[x,y,w,h]}} — decodes to the expected Annotation and round-trips.
    @Test func windowAnnotationJSONRoundTrip() throws {
        let layerID = UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!
        var stack = LayerStack()
        stack.add(Annotation(kind: .window(layerID: layerID, frame: CGRect(x: 1, y: 2, width: 3, height: 4)),
                             style: red4))
        let json = try stack.json()
        let root = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let annotation = try #require((root["annotations"] as? [[String: Any]])?.first)
        let kind = try #require(annotation["kind"] as? [String: Any])
        let window = try #require(kind["window"] as? [String: Any])
        #expect(window["layer"] as? String == "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")
        #expect(window["frame"] as? [Double] == [1, 2, 3, 4])
        #expect(try LayerStack(json: json) == stack)
    }

    // Proves image and canvas Annotations survive the annotations.json round
    // trip in their wire format — {"image":{"asset":…,"frame":…,"crop":…}}.
    @Test func imageAnnotationsJSONRoundTrip() throws {
        let fixture = """
            {"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"image":{"asset":"8C9A0B1C-2D3E-4F5A-8B9C-0D1E2F3A4B5C","frame":[10,20,100,50],"crop":[0,0,200,100],"cornerRadius":4,"border":"difference"}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}},{"id":"7A2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A","kind":{"canvas":{"link":{"url":"file:///tmp/linked.wadjet"},"frame":[0,0,80,80],"crop":[5,5,40,40],"cornerRadius":0,"border":"colour"}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}}]}
            """
        var expected = LayerStack()
        expected.add(Annotation(id: UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!,
            kind: .image(asset: UUID(uuidString: "8C9A0B1C-2D3E-4F5A-8B9C-0D1E2F3A4B5C")!,
                ImagePlacement(frame: CGRect(x: 10, y: 20, width: 100, height: 50),
                               crop: CGRect(x: 0, y: 0, width: 200, height: 100), cornerRadius: 4)),
            style: red4))
        expected.add(Annotation(id: UUID(uuidString: "7A2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A")!,
            kind: .canvas(CanvasLink(url: URL(fileURLWithPath: "/tmp/linked.wadjet")),
                ImagePlacement(frame: CGRect(x: 0, y: 0, width: 80, height: 80),
                               crop: CGRect(x: 5, y: 5, width: 40, height: 40), border: .colour)),
            style: red4))
        let stack = try LayerStack(json: Data(fixture.utf8))
        #expect(stack == expected)
        #expect(try LayerStack(json: stack.json()) == stack)
    }

    @Test func newerVersionIsRejected() {
        let json = Data(#"{"version":2,"annotations":[]}"#.utf8)
        #expect(throws: (any Error).self) { try LayerStack(json: json) }
    }
}
