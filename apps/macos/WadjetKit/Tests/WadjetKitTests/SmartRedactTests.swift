import CoreGraphics
import CoreText
import Foundation
import Testing
import WadjetKit

struct SmartRedactTests {
    // Proves Freeze Frame displays of different scales and a flattened Canvas
    // place each match on its own display in global points.
    @Test func boxesAcrossDisplaysAndFlattenedCanvas() async throws {
        let leftFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rightFrame = CGRect(x: 800, y: -200, width: 1000, height: 800)
        let (leftImage, leftInk) = try display("mia@example.com", at: CGPoint(x: 100, y: 250),
                                               frame: leftFrame, scale: 2)
        let (rightImage, rightInk) = try display("mia@example.com", at: CGPoint(x: 900, y: 300),
                                                 frame: rightFrame, scale: 1)

        try await expectBoxesPerDisplay(
            in: [.init(image: leftImage, frame: leftFrame), .init(image: rightImage, frame: rightFrame)],
            inks: [(leftInk, leftFrame), (rightInk, rightFrame)])

        // the same read through the extended-linear flattened image the
        // Editor and auto-redact feed Vision
        let crop = leftFrame.union(rightFrame)
        let canvas = CanvasDocument(
            layout: [CanvasDisplay(id: 1, frame: leftFrame, scaleFactor: 2),
                     CanvasDisplay(id: 2, frame: rightFrame, scaleFactor: 1)],
            crop: crop, displayImages: [1: leftImage, 2: rightImage])
        let flat = try canvas.flatten(scale: 2)
        try await expectBoxesPerDisplay(in: [.init(image: flat, frame: crop)],
                                        inks: [(leftInk, leftFrame), (rightInk, rightFrame)])
    }

    // Proves placed Censors are padded Black outs that skip covered spots,
    // and one undo removes them all.
    @Test func censorsPadSkipAndUndo() {
        let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 2)
        var existing = LayerStack()
        existing.add(Annotation(kind: .censor(rect: CGRect(x: 300, y: 300, width: 50, height: 50),
                                              method: .blackOut), style: style))
        let placed = SmartRedact.censors(covering: [
            CGRect(x: 110, y: 105, width: 10, height: 10),  // inside the outer box once padded
            CGRect(x: 100, y: 100, width: 50, height: 20),
            CGRect(x: 200, y: 200, width: 30, height: 10),
            CGRect(x: 310, y: 310, width: 10, height: 10),  // inside the existing Black out
        ], style: style, existing: existing)
        let pad = SmartRedact.padding
        #expect(placed.map(\.kind) == [
            .censor(rect: CGRect(x: 100 - pad, y: 100 - pad, width: 50 + 2 * pad, height: 20 + 2 * pad),
                    method: .blackOut),
            .censor(rect: CGRect(x: 200 - pad, y: 200 - pad, width: 30 + 2 * pad, height: 10 + 2 * pad),
                    method: .blackOut),
        ])
        #expect(placed.allSatisfy { $0.style == style })

        var stack = LayerStack()
        var history = LayerHistory()
        let before = stack
        placed.forEach { stack.add($0) }
        history.record(from: before, to: stack)
        #expect(history.undo(from: stack) == before)
    }

    // Proves coverage needs the Black out still on top there, and edge-sharing boxes dedupe.
    @Test func censorsCoverageRules() {
        let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 2)
        var existing = LayerStack()
        existing.add(Annotation(kind: .censor(rect: CGRect(x: 400, y: 400, width: 54, height: 24),
                                              method: .blackOut), style: style))
        existing.add(Annotation(kind: .censor(rect: CGRect(x: 300, y: 300, width: 50, height: 50),
                                              method: .blackOut), style: style))
        // a later Blur over the second Black out repaints the pixels beneath it
        existing.add(Annotation(kind: .censor(rect: CGRect(x: 315, y: 305, width: 20, height: 20),
                                              method: .blur(radius: 4)), style: style))
        let placed = SmartRedact.censors(covering: [
            CGRect(x: 402, y: 402, width: 50, height: 20),   // padded = the (400,400) Black out's rect
            CGRect(x: 100, y: 100, width: 200, height: 20),
            CGRect(x: 150, y: 100, width: 100, height: 20), // edge-shares inside the box above
            CGRect(x: 310, y: 310, width: 10, height: 10),  // inside a Black out a later Blur repaints
        ], style: style, existing: existing)
        let pad = SmartRedact.padding
        #expect(placed.map(\.kind) == [
            .censor(rect: CGRect(x: 100 - pad, y: 100 - pad, width: 200 + 2 * pad, height: 20 + 2 * pad),
                    method: .blackOut),
            .censor(rect: CGRect(x: 310 - pad, y: 310 - pad, width: 10 + 2 * pad, height: 10 + 2 * pad),
                    method: .blackOut),
        ])
    }

    // Proves a later Magnify repainting the spot invalidates an older Black
    // out — its path is only the source outline; the pixels land in `frame`.
    @Test func censorsMagnifyInvalidatesCoverage() {
        let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 2)
        var existing = LayerStack()
        existing.add(Annotation(kind: .censor(rect: CGRect(x: 400, y: 400, width: 200, height: 80),
                                              method: .blackOut), style: style))
        existing.add(Annotation(kind: .magnify(Magnifier(
            source: CGRect(x: 0, y: 0, width: 100, height: 40),
            frame: CGRect(x: 400, y: 400, width: 200, height: 80), zoom: 2,
            options: MagnifierOptions(shape: .rectangle, leader: false, glass: false))), style: style))
        let pad = SmartRedact.padding
        let placed = SmartRedact.censors(covering: [CGRect(x: 420, y: 420, width: 100, height: 20)],
                                         style: style, existing: existing)
        #expect(placed.map(\.kind) == [
            .censor(rect: CGRect(x: 420 - pad, y: 420 - pad, width: 100 + 2 * pad, height: 20 + 2 * pad),
                    method: .blackOut),
        ])
    }

    /// one box per display's frame, padded by `SmartRedact.padding` covering
    /// the text's ink
    private func expectBoxesPerDisplay(in sources: [SmartRedactSource],
                                       inks: [(ink: CGRect, frame: CGRect)]) async throws {
        let boxes = try await SmartRedact.boxes(in: sources, categories: [.email])
        #expect(boxes.count == inks.count)
        for (ink, frame) in inks {
            let box = try #require(boxes.first { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) })
            #expect(frame.contains(box))
            #expect(box.insetBy(dx: -SmartRedact.padding, dy: -SmartRedact.padding).contains(ink))
        }
    }

    /// black `text` (~40 pt Helvetica) on white at `origin` global points, in
    /// a whole-display image: `frame` global points at `scale` px per point.
    /// Returns the image and the text's ink rect in global points.
    private func display(_ text: String, at origin: CGPoint, frame: CGRect,
                         scale: CGFloat) throws -> (image: CGImage, ink: CGRect) {
        let ctx = try #require(CGContext(
            data: nil, width: Int((frame.width * scale).rounded()), height: Int((frame.height * scale).rounded()),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: frame.size))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 40, nil)]))
        ctx.textPosition = CGPoint(x: origin.x - frame.minX, y: origin.y - frame.minY)
        let ink = CTLineGetImageBounds(line, ctx).offsetBy(dx: frame.minX, dy: frame.minY)
        CTLineDraw(line, ctx)
        return (try #require(ctx.makeImage()), ink)
    }
}
