import Testing
import Foundation
import WadjetKit

struct WholeAttachmentTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    func box(_ r: CGRect = CGRect(x: 0, y: 0, width: 100, height: 50)) -> Annotation {
        Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: r), style: red4)
    }
    func current(_ stack: LayerStack, _ id: Annotation.ID) -> Annotation {
        stack.annotations.first { $0.id == id }!
    }

    // Proves an Annotation attached whole keeps a rotation of its own: the
    // turn holds, and a later turn of the target adds to it.
    @Test func wholeFollowerKeepsItsOwnRotation() {
        let target = box(), label = box(CGRect(x: 120, y: 20, width: 10, height: 10))
        var stack = LayerStack([target, label])
        stack.attach(label.id, .whole, to: target.id, at: .frame(CGPoint(x: 1, y: 0.5)))
        stack.replaceRebasing(current(stack, label.id).rotated(by: .pi / 4))
        #expect(abs(current(stack, label.id).transform.rotation - .pi / 4) < 1e-9)
        #expect(current(stack, label.id).attachments.count == 1)
        stack.replace(target.rotated(by: .pi / 2))
        #expect(abs(current(stack, label.id).transform.rotation - 3 * .pi / 4) < 1e-9)
    }

    // Proves editing one end of a Line attached whole, then snapping that end
    // onto a spot, moves only that end: the start stays at x 0 through the
    // preview and after the end attaches.
    @Test func snappingAnEditedEndKeepsTheRest() {
        let a = box(CGRect(x: 0, y: 0, width: 4, height: 4)), b = box(CGRect(x: 120, y: 0, width: 4, height: 4))
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: red4)
        var stack = LayerStack([a, b, line])
        stack.attach(line.id, .whole, to: a.id, at: .frame(.zero))
        stack.replaceEditingAnchors([(current(stack, line.id).movingAnchors([1], by: CGVector(dx: 14, dy: 0)), [1])])
        stack.replaceRebasing(current(stack, line.id).moving(.end, to: CGPoint(x: 120, y: 0)))
        #expect(current(stack, line.id).position(of: .start) == .zero)
        stack.attach(line.id, .end, to: b.id, at: .frame(.zero))
        #expect(current(stack, line.id).position(of: .start) == .zero)
        #expect(current(stack, line.id).position(of: .end) == CGPoint(x: 120, y: 0))
    }
}

