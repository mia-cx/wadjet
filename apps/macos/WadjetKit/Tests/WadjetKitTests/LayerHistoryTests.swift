import Testing
import Foundation
import WadjetKit

struct LayerHistoryTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    // undo walks back action by action, redo replays them, and a new action drops the redo steps
    @Test func undoAndRedoAcrossClear() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 0)), style: red4)
        let b = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 5)), style: red4)
        let c = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 10)), style: red4)
        let s0 = LayerStack()
        let s1 = LayerStack([a])
        let s2 = LayerStack([a, b])
        let s3 = LayerStack()
        var h = LayerHistory()
        h.record(from: s0, to: s1)
        h.record(from: s1, to: s2)
        h.record(from: s2, to: s3)
        #expect(h.undo(from: s3) == s2)
        #expect(h.undo(from: s2) == s1)
        #expect(h.redo(from: s1) == s2)
        #expect(h.redo(from: s2) == s3)
        #expect(h.redo(from: s3) == nil)

        #expect(h.undo(from: s3) == s2)
        let s4 = LayerStack([a, b, c])
        h.record(from: s2, to: s4)
        #expect(h.redo(from: s4) == nil)
    }

    // a drag records one step and a change-nothing action records none
    @Test func aDragIsOneStep() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 0)), style: red4)
        let before = LayerStack([a])
        let after = LayerStack([a.moved(by: CGVector(dx: 5, dy: 5))])
        var h = LayerHistory()
        h.record(from: before, to: after)
        h.record(from: after, to: after)
        #expect(h.undo(from: after) == before)
        #expect(h.undo(from: before) == nil)
    }

    // history survives a Clear while the session is open, and ends once cleared and closed
    @Test func historyEndsWhenClearedAndClosed() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 0)), style: red4)
        let cleared = LayerStack()
        var h = LayerHistory()
        h.record(from: cleared, to: LayerStack([a]))
        h.record(from: LayerStack([a]), to: cleared)
        h.end(ifCleared: LayerStack([a]))
        #expect(h.undo(from: cleared) == LayerStack([a]))
        #expect(h.redo(from: LayerStack([a])) == cleared)
        h.end(ifCleared: cleared)
        #expect(h.undo(from: cleared) == nil)
    }
}
