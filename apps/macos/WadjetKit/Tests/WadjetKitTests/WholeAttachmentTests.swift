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
}
