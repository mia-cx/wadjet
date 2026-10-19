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

    @Test func annotationsJSONRoundTrip() throws {
        // the first annotation predates `transform` — it decodes as .identity
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

    @Test func newerVersionIsRejected() {
        let json = Data(#"{"version":2,"annotations":[]}"#.utf8)
        #expect(throws: (any Error).self) { try LayerStack(json: json) }
    }
}
