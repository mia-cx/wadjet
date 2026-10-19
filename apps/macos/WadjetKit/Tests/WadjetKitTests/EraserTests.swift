import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct EraserTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    // Proves a drag removes exactly the painted-over Annotations — hidden and
    // locked ones under the same path stay — and that the whole sweep is a
    // single undo step
    @Test func dragErasesOnlyTouched() {
        var stack = LayerStack()
        let far = Annotation(kind: .line(start: CGPoint(x: 50, y: 80), end: CGPoint(x: 150, y: 80)),
                             style: red4)
        let hit = Annotation(kind: .line(start: CGPoint(x: 50, y: -20), end: CGPoint(x: 50, y: 20)),
                             style: red4)
        let locked = Annotation(kind: .line(start: CGPoint(x: 60, y: -20), end: CGPoint(x: 60, y: 20)),
                                style: red4, locked: true)
        let hidden = Annotation(kind: .line(start: CGPoint(x: 70, y: -20), end: CGPoint(x: 70, y: 20)),
                                style: red4, hidden: true)
        stack.add(hit); stack.add(far); stack.add(locked); stack.add(hidden)
        var sweep = EraserSweep(stack: stack, at: CGPoint(x: 0, y: 0), radius: 6)
        sweep.drag(to: CGPoint(x: 100, y: 0))
        #expect(sweep.marked == [hit.id])
        let before = stack
        stack.erase(sweep.marked)
        #expect(stack.annotations.map(\.id) == [far.id, locked.id, hidden.id])
        var history = LayerHistory()
        history.record(from: before, to: stack)
        #expect(history.undo(from: stack) == before)
    }

    // Proves the swept segment between two sparse samples catches an
    // Annotation the eraser circle never covered
    @Test func sparseSamplesStillTouchBetween() {
        var stack = LayerStack()
        let a = Annotation(kind: .line(start: CGPoint(x: 50, y: -20), end: CGPoint(x: 50, y: 20)),
                           style: red4)
        stack.add(a)
        var sweep = EraserSweep(stack: stack, at: CGPoint(x: 0, y: 0), radius: 4)
        sweep.drag(to: CGPoint(x: 100, y: 0)) // one jump across x = 50
        #expect(sweep.marked == [a.id])
    }

    // Proves erasing counters in one batch still closes the sequence's gaps:
    // sweeping counters 2 and 3 of 1…4 leaves values 1, 2 whatever order the
    // set iterates the renumbering in
    @Test func eraseCountersRenumbersLikeSequentialRemove() {
        var stack = LayerStack()
        for v in 1...4 {
            stack.add(Annotation(kind: .counter(center: CGPoint(x: CGFloat(v) * 20, y: 0),
                                                radius: 8, value: v, format: .numbers),
                                 style: red4))
        }
        // ids 2 and 3, the middle pair
        let ids = Set(stack.annotations.dropFirst().dropLast().map(\.id))
        stack.erase(ids)
        #expect(stack.annotations.map { a -> Int in
            guard case let .counter(_, _, value, _) = a.kind else { return -1 }
            return value
        } == [1, 2])
    }

    // Proves a press that never leaves clickSlop marks only the front-most
    // Annotation under the circle, while a real drag marks them all
    @Test func clickMarksOnlyFrontmost() {
        var filled = red4
        filled.fill = RGBAColour(red: 0, green: 0, blue: 1, alpha: 1)
        let back = Annotation(kind: .shape(.rectangle(cornerRadius: 0),
                                           rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                              style: filled)
        let front = Annotation(kind: .shape(.rectangle(cornerRadius: 0),
                                            rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                               style: filled)
        var stack = LayerStack([back, front])
        var click = EraserSweep(stack: stack, at: CGPoint(x: 50, y: 50), radius: 6)
        click.drag(to: CGPoint(x: 51, y: 50)) // inside clickSlop
        #expect(click.marked == [front.id])
        var drag = EraserSweep(stack: stack, at: CGPoint(x: 50, y: 50), radius: 6)
        drag.drag(to: CGPoint(x: 60, y: 50))
        #expect(drag.marked == [back.id, front.id])
        stack.erase(click.marked)
        #expect(stack.annotations.map(\.id) == [back.id])
    }

    // Proves every kind erases through its painted area: a filled Shape inside
    // (not just on its outline), a Censor's rect, a counter's circle, a
    // Magnify's magnifier box, an open path's stroke
    @Test(arguments: [
        Annotation(kind: .shape(.rectangle(cornerRadius: 0),
                                rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1),
                                          width: 4,
                                          fill: RGBAColour(red: 0, green: 0, blue: 1, alpha: 1))),
        Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                 method: .blackOut),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)),
        Annotation(kind: .counter(center: CGPoint(x: 50, y: 50), radius: 14, value: 1,
                                  format: .numbers),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)),
        Annotation(kind: .magnify(Magnifier(source: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            frame: CGRect(x: 10, y: 10, width: 80, height: 80),
                                            options: MagnifierOptions())),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)),
        Annotation(kind: .path(PathData(nodes: [PathNode(anchor: CGPoint(x: 0, y: 50)),
                                                PathNode(anchor: CGPoint(x: 100, y: 50))])),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)),
        // a plain Text's painted area is its glyph box, which extends down
        // from the origin — placed so (50,50) lands inside it
        Annotation(kind: .text(TextData(string: "Hello", origin: CGPoint(x: 10, y: 80),
                                       format: .default)),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)),
    ])
    func everyKindErasesThroughPaintedArea(a: Annotation) {
        let stack = LayerStack([a])
        // (50,50) lands inside each fixture's painted area
        let sweep = EraserSweep(stack: stack, at: CGPoint(x: 50, y: 50), radius: 4)
        #expect(sweep.marked == [a.id])
    }
}
