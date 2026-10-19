import Testing
import Foundation
import WadjetKit

struct StepCounterTests {
    let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    func counter(_ v: Int, _ f: CounterFormat = .numbers, id: UUID = UUID()) -> Annotation {
        Annotation(id: id, kind: .counter(center: .zero, radius: 14, value: v, format: f), style: style)
    }
    func values(_ s: LayerStack, _ f: CounterFormat = .numbers) -> [Int] {
        s.annotations.compactMap {
            if case let .counter(_, _, v, format) = $0.kind, format == f { v } else { nil }
        }
    }

    // Proves the labels: numbers read plainly, letters count bijective base 26.
    @Test(arguments: [
        (CounterFormat.numbers, 1, "1"), (.numbers, 42, "42"),
        (.letters, 1, "A"), (.letters, 26, "Z"), (.letters, 27, "AA"), (.letters, 28, "AB"),
        (.letters, 52, "AZ"), (.letters, 53, "BA"), (.letters, 702, "ZZ"), (.letters, 703, "AAA"),
    ])
    func labels(format: CounterFormat, value: Int, expected: String) {
        #expect(format.label(value) == expected)
    }

    // Proves a click continues the newest counter of its own format.
    @Test func nextValue() {
        var s = LayerStack()
        #expect(s.nextCounterValue(.numbers) == 1)
        for v in 1...3 { s.add(counter(v)) }
        #expect(s.nextCounterValue(.numbers) == 4)
        #expect(s.nextCounterValue(.letters) == 1) // a separate sequence
        s.add(counter(1)) // a restarted run places 1, so the next continues it
        #expect(s.nextCounterValue(.numbers) == 2)
    }

    // Proves deleting a counter closes the gap only within its own sequence.
    @Test func deletingRenumbers() {
        var s = LayerStack()
        let ids = (1...4).map { _ in UUID() }
        for (v, id) in zip(1...4, ids) { s.add(counter(v, id: id)) }
        s.remove(id: ids[1]) // the 2
        #expect(values(s) == [1, 2, 3])

        s = LayerStack()
        let n2 = UUID(), last = UUID()
        s.add(counter(1)); s.add(counter(2, id: n2))
        s.add(counter(1, .letters)) // another format between them keeps its value
        s.add(counter(3)); s.add(counter(4, id: last))
        s.remove(id: n2)
        #expect(values(s) == [1, 2, 3])
        #expect(values(s, .letters) == [1])
        s.remove(id: last) // deleting the tail renumbers nothing
        #expect(values(s) == [1, 2])

        // removing a non-counter between counters changes no values
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 1, y: 0)), style: style)
        s.add(counter(3)); s.add(line); s.add(counter(4))
        s.remove(id: line.id)
        #expect(values(s) == [1, 2, 3, 4])
    }

    // Proves Option continuation: a run picked up mid-sequence renumbers only
    // to the end of that run, and a restarted run is a run of its own.
    @Test func continuationRuns() {
        var s = LayerStack()
        // values [1,2,3] then a 3 continued from 2, then 4: [1,2,3,3,4]
        let ids = (1...5).map { _ in UUID() }
        for (v, id) in zip([1, 2, 3, 3, 4], ids) { s.add(counter(v, id: id)) }
        s.remove(id: ids[1]) // the first 2 — the run ends at the second 3
        #expect(values(s) == [1, 2, 3, 4])

        // a restarted run: [1,2,1,2], deleting the first 1
        s = LayerStack()
        for (v, id) in zip([1, 2, 1, 2], ids) { s.add(counter(v, id: id)) }
        s.remove(id: ids[0])
        #expect(values(s) == [1, 1, 2])
    }

    // Proves a counter hits inside its circle and its label sits centred and
    // scaled to fit.
    @Test func hitAndLabel() throws {
        let a = Annotation(kind: .counter(center: CGPoint(x: 50, y: 50), radius: 14,
                                        value: 100, format: .numbers), style: style)
        #expect(PathGeometry.hitTest(a, at: CGPoint(x: 50, y: 60)))
        #expect(!PathGeometry.hitTest(a, at: CGPoint(x: 50, y: 66)))
        let label = try #require(PathGeometry.labelPath(for: a))
        let bb = label.boundingBox
        #expect(abs(bb.midX - 50) < 0.5 && abs(bb.midY - 50) < 0.5)
        #expect(bb.width < 28)
    }

    // Proves a corner grip resizes a counter's circle, keeping it circular.
    @Test func resizingACounter() {
        let a = Annotation(kind: .counter(center: .zero, radius: 10, value: 3, format: .letters),
                           style: style)
        let r = a.dragging(.resize(x: 1, y: 1), from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 20))
        #expect(r.kind == .counter(center: CGPoint(x: 10, y: 5), radius: 15, value: 3, format: .letters))
    }
}
