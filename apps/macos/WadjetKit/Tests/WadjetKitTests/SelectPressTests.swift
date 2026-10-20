import Foundation
import Testing
import WadjetKit

struct SelectPressTests {
    static let red = RGBAColour(red: 1, green: 0, blue: 0, alpha: 1)
    static func box(_ x: CGFloat, _ y: CGFloat, filled: Bool = true, locked: Bool = false) -> Annotation {
        Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: x, y: y, width: 40, height: 40)),
                   style: AnnotationStyle(colour: red, width: 2, fill: filled ? red : nil), locked: locked)
    }
    static func press(_ p: CGPoint, _ stack: [Annotation], _ selection: AnnotationSelection = [],
                      shift: Bool = false) -> SelectPress {
        SelectPress.resolve(at: p, in: stack, selection: selection, shift: shift, tolerance: 4)
    }

    // Proves a press on an unselected Annotation selects it alone and the
    // drag moves it, rather than starting a marquee: Mia's report.
    @Test func pressOnUnselectedGrabsIt() {
        let a = Self.box(0, 0), b = Self.box(100, 0)
        let r = Self.press(CGPoint(x: 120, y: 20), [a, b], [a.id])
        #expect(r == SelectPress(selection: [b.id], action: .move, hit: b.id))
    }

    // Proves a press on a selected Annotation, alone or one of several,
    // keeps the whole selection so the drag moves all of it.
    @Test func pressOnSelectedKeepsTheSelection() {
        let a = Self.box(0, 0), b = Self.box(100, 0)
        #expect(Self.press(CGPoint(x: 20, y: 20), [a, b], [a.id])
                == SelectPress(selection: [a.id], action: .move, hit: a.id))
        #expect(Self.press(CGPoint(x: 120, y: 20), [a, b], [a.id, b.id])
                == SelectPress(selection: [a.id, b.id], action: .move, hit: b.id))
    }

    // Proves the selection wins over an unselected Annotation lying on top
    // of it, so a drag from there moves what is selected.
    @Test func selectedBeneathAnotherStillMoves() {
        let below = Self.box(0, 0), above = Self.box(20, 20)
        #expect(Self.press(CGPoint(x: 30, y: 30), [below, above], [below.id])
                == SelectPress(selection: [below.id], action: .move, hit: below.id))
        #expect(Self.press(CGPoint(x: 30, y: 30), [below, above]).hit == above.id)
    }

    // Proves only empty canvas starts a marquee: a plain one deselects, a
    // Shift one keeps the selection and adds to it.
    @Test func emptyCanvasStartsAMarquee() {
        let a = Self.box(0, 0)
        #expect(Self.press(CGPoint(x: 200, y: 200), [a], [a.id])
                == SelectPress(selection: [], action: .marquee(adding: false), hit: nil))
        #expect(Self.press(CGPoint(x: 200, y: 200), [a], [a.id], shift: true)
                == SelectPress(selection: [a.id], action: .marquee(adding: true), hit: nil))
    }

    // Proves a hollow shape's empty middle is empty canvas, while its outline grabs it.
    @Test func hollowMiddleIsEmptyCanvas() {
        let ring = Self.box(0, 0, filled: false)
        #expect(Self.press(CGPoint(x: 20, y: 20), [ring]).action == .marquee(adding: false))
        #expect(Self.press(CGPoint(x: 1, y: 20), [ring]).action == .move)
    }

    // Proves a locked Annotation is never grabbed: a press on it counts as
    // empty canvas, or reaches what lies beneath.
    @Test func lockedIsNeverGrabbed() {
        let under = Self.box(0, 0), locked = Self.box(0, 0, locked: true)
        #expect(Self.press(CGPoint(x: 20, y: 20), [locked]).action == .marquee(adding: false))
        #expect(Self.press(CGPoint(x: 20, y: 20), [under, locked]).hit == under.id)
    }

    // Proves a thin Line grabs within the stroke tolerance and not beyond.
    @Test func thinLineWithinTolerance() {
        let line = Annotation(kind: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)),
                              style: AnnotationStyle(colour: Self.red, width: 1))
        #expect(Self.press(CGPoint(x: 50, y: 4), [line]) == SelectPress(selection: [line.id], action: .move, hit: line.id))
        #expect(Self.press(CGPoint(x: 50, y: 8), [line]).action == .marquee(adding: false))
    }

    // Proves Text and images grab anywhere inside their box, not just on an edge.
    @Test func textAndImagesGrabTheirWholeBox() {
        let text = Annotation(kind: .text(TextData(string: "Hello", origin: CGPoint(x: 0, y: 0), format: .default)),
                              style: AnnotationStyle(colour: Self.red, width: 2))
        let box = PathGeometry.path(for: text).boundingBox
        #expect(Self.press(CGPoint(x: box.midX, y: box.midY), [text]).action == .move)
        let image = Annotation(kind: .image(asset: UUID(), ImagePlacement(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50), crop: CGRect(x: 0, y: 0, width: 200, height: 100))),
            style: AnnotationStyle(colour: Self.red, width: 1))
        #expect(Self.press(CGPoint(x: 50, y: 25), [image]) == SelectPress(selection: [image.id], action: .move, hit: image.id))
    }

    // Proves Shift toggles: adding an Annotation grabs the selection for the
    // drag, taking one out leaves nothing to drag.
    @Test func shiftToggles() {
        let a = Self.box(0, 0), b = Self.box(100, 0)
        #expect(Self.press(CGPoint(x: 120, y: 20), [a, b], [a.id], shift: true)
                == SelectPress(selection: [a.id, b.id], action: .move, hit: b.id))
        #expect(Self.press(CGPoint(x: 120, y: 20), [a, b], [a.id, b.id], shift: true)
                == SelectPress(selection: [a.id], action: .none, hit: b.id))
    }
}
