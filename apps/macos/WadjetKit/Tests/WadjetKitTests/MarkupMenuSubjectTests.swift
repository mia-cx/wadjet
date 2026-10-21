import Foundation
import Testing
@testable import WadjetKit

struct MarkupMenuSubjectTests {
    static let rect = CGRect(x: 0, y: 0, width: 40, height: 30)

    // Proves a selected Annotation's kind picks the menu's controls whatever
    // Tool is armed; with nothing selected the armed Tool's defaults do.
    @Test(arguments: [
        (nil, .magnify(Magnifier(source: rect, frame: rect, options: MagnifierOptions())), .selected(.magnify)),
        (.shapes, .censor(rect: rect, method: .defaultBlur), .selected(.censor)),
        (.draw, .path(PathData()), .selected(.draw)),
        (nil, .line(start: .zero, end: CGPoint(x: 10, y: 10)), .selected(.draw)),
        (nil, .counter(center: .zero, radius: 12, value: 1, format: .numbers), .selected(.counter)),
        (nil, .text(TextData(string: "hi", origin: .zero, format: .default)), .selected(.text)),
        (.magnify, .image(asset: UUID(), ImagePlacement(frame: rect, crop: rect)), .selected(nil)),
        (.censor, nil, .armed(.censor)),
        (nil, nil, .armed(nil)),
    ] as [(ToolID?, AnnotationKind?, MarkupMenuSubject)])
    func subject(armed: ToolID?, kind: AnnotationKind?, expected: MarkupMenuSubject) {
        #expect(MarkupMenuSubject(armed: armed, selected: kind) == expected)
    }

    // Proves several selected Annotations show their kind's Tool when they
    // share it, and Select's style-only controls when their kinds differ.
    @Test func several() {
        let line = AnnotationKind.line(start: .zero, end: CGPoint(x: 10, y: 10))
        #expect(MarkupMenuSubject(armed: .shapes, selected: [line, .path(PathData())]) == .selected(.draw))
        #expect(MarkupMenuSubject(armed: .draw, selected: [line, .shape(.ellipse, rect: Self.rect)]) == .selected(nil))
        #expect(MarkupMenuSubject(armed: .draw, selected: [AnnotationKind]()) == .armed(.draw))
    }
}
