import Foundation
import Testing
import WadjetKit

struct AnnotationSelectionTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    static func box(_ x: CGFloat, _ y: CGFloat, locked: Bool = false, hidden: Bool = false) -> Annotation {
        Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: x, y: y, width: 20, height: 20)),
                   style: AnnotationStyle(colour: style.colour, width: 2, fill: style.colour),
                   hidden: hidden, locked: locked)
    }

    // Proves a Select press follows Illustrator: Shift toggles the hit in or
    // out, a plain press on a selected Annotation keeps the whole selection
    // (so the drag moves them all), on another one replaces it, and a press on
    // empty canvas deselects unless Shift is held.
    @Test func clicking() {
        let a = UUID(), b = UUID(), c = UUID()
        let ab = AnnotationSelection([a, b])
        #expect(ab.clicking(c, shift: true).ids == [a, b, c])
        #expect(ab.clicking(a, shift: true).ids == [b])
        #expect(ab.clicking(a, shift: false) == ab)
        #expect(ab.clicking(c, shift: false).ids == [c])
        #expect(ab.clicking(nil, shift: false).isEmpty)
        #expect(ab.clicking(nil, shift: true) == ab)
    }

    // Proves a marquee selects every Annotation it touches, even partly, and
    // never a locked or hidden one; Shift keeps what was already selected.
    @Test func marquee() {
        let inside = Self.box(0, 0), straddling = Self.box(50, 0), outside = Self.box(200, 0)
        let locked = Self.box(10, 30, locked: true), hidden = Self.box(30, 30, hidden: true)
        let line = Annotation(kind: .line(start: CGPoint(x: -20, y: 70), end: CGPoint(x: 20, y: 70)), style: Self.style)
        let stack = [inside, straddling, outside, locked, hidden, line]
        let rect = CGRect(x: -5, y: -5, width: 65, height: 80)
        #expect(AnnotationSelection().marquee(rect, in: stack, adding: false).set
                == [inside.id, straddling.id, line.id])
        #expect(AnnotationSelection([outside.id]).marquee(rect, in: stack, adding: true).set
                == [outside.id, inside.id, straddling.id, line.id])
        #expect(AnnotationSelection([outside.id]).marquee(rect, in: stack, adding: false).set
                == [inside.id, straddling.id, line.id])
    }

    // Proves a marquee inside an unfilled shape's hollow middle doesn't select
    // it: only painted area counts, as a click does.
    @Test func marqueeSkipsHollowInside() {
        let ring = Annotation(kind: .shape(.ellipse, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                              style: Self.style)
        #expect(AnnotationSelection().marquee(CGRect(x: 40, y: 40, width: 20, height: 20),
                                              in: [ring], adding: false).isEmpty)
    }

    // Proves ⌘A skips locked and hidden Annotations, keeping stack order.
    @Test func selectAll() {
        let a = Self.box(0, 0), l = Self.box(0, 0, locked: true), h = Self.box(0, 0, hidden: true), b = Self.box(9, 9)
        #expect(AnnotationSelection.all(in: [a, l, h, b]).ids == [a.id, b.id])
    }

    // Proves an Annotation deleted, hidden, or locked under the selection
    // (undo, the Layers window) drops out of it.
    @Test func pruned() {
        let a = Self.box(0, 0), b = Self.box(0, 0), gone = UUID()
        var lockedB = b; lockedB.locked = true
        #expect(AnnotationSelection([a.id, b.id, gone]).pruned(to: [a, lockedB]).ids == [a.id])
    }
}
