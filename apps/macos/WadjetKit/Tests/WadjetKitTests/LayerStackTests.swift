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

    @Test func annotationsJSONRoundTrip() throws {
        let fixture = """
            {"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"line":{"start":[10,20],"end":[110,20]}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}}]}
            """
        var expected = LayerStack()
        expected.add(Annotation(id: UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!,
                                kind: .line(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 110, y: 20)),
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
