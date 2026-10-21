import CoreGraphics
import CoreText
import Foundation
import Testing
import WadjetKit

struct TextAnnotationTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    // Proves the "text" wire shape: one without width, one wrapped + centred + pill
    @Test func annotationsJSONRoundTrip() throws {
        let fixture = """
            {"version":1,"annotations":[{"id":"6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F","kind":{"text":{"string":"Hello","origin":[100,500],"format":{"font":"Monaco","size":20,"weight":"regular","alignment":"left","pill":false}}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4}},{"id":"7A2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A","kind":{"text":{"string":"Two\\nlines","origin":[0,0],"width":120,"format":{"font":"Noteworthy","size":24,"weight":"bold","alignment":"centre","pill":true}}},"style":{"colour":{"red":1,"green":0,"blue":0,"alpha":1},"width":4,"opacity":0.5}}]}
            """
        var expected = LayerStack()
        expected.add(Annotation(id: UUID(uuidString: "6F1C2C3A-0B7E-4C1D-9C2E-1A2B3C4D5E6F")!,
                                kind: .text(TextData(string: "Hello", origin: CGPoint(x: 100, y: 500),
                                    format: TextFormat(font: "Monaco", size: 20, weight: .regular,
                                                       alignment: .left, pill: false))),
                                style: red4))
        expected.add(Annotation(id: UUID(uuidString: "7A2D3E4F-1C2D-4E3F-8D3E-2B3C4D5E6F7A")!,
                                kind: .text(TextData(string: "Two\nlines", origin: .zero, width: 120,
                                    format: TextFormat(font: "Noteworthy", size: 24, weight: .bold,
                                                       alignment: .centre, pill: true))),
                                style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1),
                                                       width: 4, opacity: 0.5)))
        let stack = try LayerStack(json: Data(fixture.utf8))
        #expect(stack == expected)
        #expect(try LayerStack(json: stack.json()) == stack)
    }

    // Proves the layout's box (padding included) is what hit testing sees
    @Test func layoutBoundsForHitTesting() {
        let a = Annotation(kind: .text(TextData(string: "Hello", origin: CGPoint(x: 100, y: 500),
            format: TextFormat(font: "Monaco", size: 20, weight: .regular, alignment: .left, pill: false))),
            style: red4)
        let b = a.kind.bounds
        #expect(b.minX == 100)
        #expect(b.maxY == 500)
        // Monaco advances are 0.6 em: 5 × 12 pt of text + 2 × 7 pt padding;
        // the framesetter rounds the suggestion up, so allow a point either way
        #expect(b.width >= 5 * 12.0 + 2 * 7 && b.width <= 5 * 12.0 + 2 * 7 + 2)
        let stack = LayerStack([a])
        #expect(stack.topmost(at: CGPoint(x: b.midX, y: b.midY), tolerance: 0)?.id == a.id)
        #expect(stack.topmost(at: CGPoint(x: b.maxX + 2, y: b.midY), tolerance: 0) == nil)
        // `a` has no pill — the box still hits because Text's fillColour is
        // the text colour, so the generic filled-area rule drives its hit area
        #expect(PathGeometry.hitTest(a, at: CGPoint(x: b.midX, y: b.midY), tolerance: 0))
        // a narrow wrap makes a long string at least two lines tall
        let wrapped = Annotation(kind: .text(TextData(string: "Hello world",
            origin: CGPoint(x: 100, y: 500), width: 30,
            format: TextFormat(font: "Monaco", size: 20, weight: .regular, alignment: .left, pill: false))),
            style: red4)
        let format = wrapped.kind.textData!.format
        let lineHeight = TextLayout(TextData(string: "x", origin: .zero, format: format)).lineHeight
        #expect(wrapped.kind.bounds.height >= 2 * lineHeight + 2 * 0.15 * 20 - 0.01)
        // a trailing newline still costs a line — the caret lives there
        let trailing = Annotation(kind: .text(TextData(string: "Hi\n",
            origin: CGPoint(x: 100, y: 500), format: format)), style: red4)
        let plain = Annotation(kind: .text(TextData(string: "Hi",
            origin: CGPoint(x: 100, y: 500), format: format)), style: red4)
        #expect(abs(trailing.kind.bounds.height - plain.kind.bounds.height - lineHeight) < 0.01)
    }

    // Proves the default really is Noteworthy Bold, weights reach the system
    // font, and a missing family falls back to the system font at that weight
    @Test func fontResolution() {
        func ps(_ family: String, _ weight: TextWeight) -> String {
            CTFontCopyPostScriptName(TextFonts.font(family: family, weight: weight, size: 20)) as String
        }
        #expect(ps(TextFormat.default.font, TextFormat.default.weight) == "Noteworthy-Bold")
        let regular = ps(TextFonts.system, .regular), bold = ps(TextFonts.system, .bold)
        #expect(regular != bold)
        #expect(ps("NoSuchFamily", .bold) == bold)
    }

    // Proves Text's grips only set the wrapping width and moving keeps a nil width nil
    @Test func resizingSetsWidthOnly() throws {
        var d = TextData(string: "Hello", origin: CGPoint(x: 100, y: 500), width: 200,
            format: TextFormat(font: "Monaco", size: 20, weight: .regular, alignment: .left, pill: false))
        let a = Annotation(kind: .text(d), style: red4)
        // dragging the right grip 50 pt left narrows `width`, origin stays
        let start = CGPoint(x: a.kind.bounds.maxX, y: a.kind.bounds.midY)
        let dragged = a.dragging(.resize(x: 1, y: 0), from: start,
                                 to: CGPoint(x: start.x - 50, y: start.y))
        let data = try #require(dragged.kind.textData)
        #expect(data.origin == d.origin)
        #expect(abs((data.width ?? 0) - 150) < 0.1)
        // no grip resizes vertically; only .rotate carries y ≠ 0 semantics
        for h in a.handles(minExtent: 12, rotateOffset: 20) {
            if case let .resize(_, y) = h.handle { #expect(y == 0) }
        }
        d.width = nil
        let moved = Annotation(kind: .text(d), style: red4).moved(by: CGVector(dx: 30, dy: -40))
        let m = try #require(moved.kind.textData)
        #expect(m.width == nil)
        #expect(m.origin == CGPoint(x: 130, y: 460))
    }

    // Proves the menu's pinned / recent / all sections: rank order, installed-only
    // recents, no dot-prefixed families, no family in two sections
    @Test func fontSections() {
        let installed = ["American Typewriter", "Avenir", "Baskerville", "Chalkboard",
                         "Courier", "Futura", "Georgia", "Helvetica", "Menlo",
                         "Monaco", "Noteworthy", "Palatino", "Times", "Zapfino",
                         ".Hidden", "SF Compact"]
        var ranker = FrecencyRanker<String>()
        // uses at distinct dates: 12 installed non-pinned fonts, Monaco (pinned), Gone
        let used = ["Avenir", "Baskerville", "Chalkboard", "Courier", "Futura",
                    "Georgia", "Helvetica", "Menlo", "Palatino", "Times",
                    "Zapfino", "American Typewriter", "Monaco", "Gone"]
        for (i, name) in used.enumerated() {
            ranker.recordUse(of: name, at: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 60))
        }
        ranker.refresh(candidates: ranker.usedItems, pinned: TextFonts.pinned)
        let sections = TextFonts.sections(installed: installed, recent: ranker)
        #expect(sections.pinned == ["Noteworthy", "SF Pro", "Monaco"])
        // the 10 most recent installed non-pinned, newest first
        #expect(sections.recent == used.dropFirst(2).dropLast(2).reversed())
        #expect(!sections.all.contains(".Hidden"))
        #expect(!sections.recent.contains("Monaco") && !sections.recent.contains("Gone"))
        #expect(sections.all == sections.all.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending })
        let every = sections.pinned + sections.recent + sections.all
        #expect(Set(every).count == every.count)
    }

    // Proves the last picked font survives a save and reload (default: Noteworthy Bold)
    @MainActor
    @Test func lastFontPersists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        let a = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) {
            Issue.record("unexpected error: \($0)") }
        #expect(a.value.markup.textFormat == .default)
        #expect(a.value.markup.textFormat.font == "Noteworthy")
        #expect(a.value.markup.textFormat.weight == .bold)
        a.update { $0.markup.textFormat.font = "Monaco" }
        let b = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) {
            Issue.record("unexpected error: \($0)") }
        #expect(b.value.markup.textFormat.font == "Monaco")
    }

    // Proves flatten draws the glyphs: a bright pixel inside the box, black outside
    @Test func flattenDrawsText() throws {
        let display = CanvasDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 120, height: 80), scaleFactor: 1)
        let text = Annotation(kind: .text(TextData(string: "W", origin: CGPoint(x: 10, y: 70),
            format: TextFormat(font: "Monaco", size: 40, weight: .regular, alignment: .left, pill: false))),
            style: AnnotationStyle(colour: RGBAColour(red: 1, green: 1, blue: 1, alpha: 1), width: 4))
        let document = CanvasDocument(layout: [display], crop: display.frame,
            layerStack: LayerStack([text]),
            displayImages: [1: try solid([0, 0, 0, 1], width: 120, height: 80)])
        let image = try document.flatten(scale: 1)
        let px = try linear(image)
        func pix(_ x: Int, _ y: Int) -> Float { px[4 * (y * image.width + x)] }
        // CG pixels are y-down: the box's top (global y 70) is row 10
        let inside = (11..<40).flatMap { y in (11..<70).map { x in pix(x, y) } }
        #expect(inside.contains { $0 > 0.5 })
        #expect(pix(2, 2) == 0 && pix(110, 75) == 0)
    }

    // Proves committed text renders upright: the "MMM" line lights the top
    // half of the text rect far more than the "." line lights the bottom —
    // a flipped draw would light the bottom instead
    @Test func flattenDrawsTextUpright() throws {
        let display = CanvasDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 160, height: 160), scaleFactor: 1)
        let data = TextData(string: "MMM\n.", origin: CGPoint(x: 10, y: 150),
            format: TextFormat(font: "Monaco", size: 40, weight: .regular, alignment: .left, pill: false))
        let text = Annotation(kind: .text(data),
            style: AnnotationStyle(colour: RGBAColour(red: 1, green: 1, blue: 1, alpha: 1), width: 4))
        let document = CanvasDocument(layout: [display], crop: display.frame,
            layerStack: LayerStack([text]),
            displayImages: [1: try solid([0, 0, 0, 1], width: 160, height: 160)])
        let image = try document.flatten(scale: 1)
        let px = try linear(image)
        // CG pixels are y-down: the text rect (the box inset by padding) starts
        // at the image's top edge of the box + vertical padding
        let layout = TextLayout(data), box = layout.box
        let top = Int(box.maxY.rounded(.down)) - Int(image.height)
        let x0 = Int((box.minX + layout.padding.width).rounded(.down))
        let x1 = Int((box.maxX - layout.padding.width).rounded(.up))
        let y0 = Int((-top + Int(layout.padding.height.rounded(.down))))
        let textRows = Int(layout.textSize.height.rounded(.up))
        func brightness(_ rows: Range<Int>) -> Float {
            rows.flatMap { y in (x0..<x1).map { x in px[4 * (y * image.width + x)] } }.reduce(0, +)
        }
        let upper = brightness(y0..<(y0 + textRows / 2))
        let lower = brightness((y0 + textRows / 2)..<(y0 + textRows))
        #expect(upper > 2 * lower)
    }
}

private extension AnnotationKind {
    var textData: TextData? { if case let .text(d) = self { d } else { nil } }
}

private func solid(_ colour: [CGFloat], width: Int, height: Int) throws -> CGImage {
    let pixels = Array(repeating: colour.map { UInt8($0 * 255) }, count: width * height).flatMap { $0 }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func linear(_ image: CGImage) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 32,
        bytesPerRow: image.width * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setEDRTargetHeadroom(0)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
}
