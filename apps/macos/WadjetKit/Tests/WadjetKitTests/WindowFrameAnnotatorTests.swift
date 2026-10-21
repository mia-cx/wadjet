import CoreGraphics
import CoreVideo
import Foundation
import Testing
import WadjetKit

struct WindowFrameAnnotatorTests {
    /// a zero-filled 32BGRA pixel buffer; `pixel(x, yFromTop)` returns B,G,R,A
    private static func buffer(width w: Int, height h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        memset(CVPixelBufferGetBaseAddress(b)!, 0, CVPixelBufferGetBytesPerRow(b) * h)
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }
    private static func pixel(_ pb: CVPixelBuffer, x: Int, yFromTop: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(pb)!
            .advanced(by: yFromTop * CVPixelBufferGetBytesPerRow(pb) + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (p[0], p[1], p[2], p[3])
    }
    private static func line(_ start: CGPoint, _ end: CGPoint) -> Annotation {
        Annotation(kind: .line(start: start, end: end),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4))
    }

    struct Row {
        var name: String
        var window: CGRect // kCGWindowBounds: CG points, top-left origin
        var primaryHeight: CGFloat
        var contentRect: CGRect
        var scaleFactor: CGFloat
        var frame: CGSize
        var line: Annotation
        var red: (x: Int, y: Int)
        var clear: (x: Int, y: Int)
    }
    static let rows: [Row] = [
        // native fill, contentRect in points
        Row(name: "points", window: CGRect(x: 100, y: 100, width: 200, height: 100), primaryHeight: 1000,
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), scaleFactor: 2,
            frame: CGSize(width: 400, height: 200),
            line: line(CGPoint(x: 150, y: 850), CGPoint(x: 250, y: 850)),
            red: (200, 100), clear: (200, 20)),
        // same, contentRect in pixels
        Row(name: "pixels", window: CGRect(x: 100, y: 100, width: 200, height: 100), primaryHeight: 1000,
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), scaleFactor: 2,
            frame: CGSize(width: 400, height: 200),
            line: line(CGPoint(x: 150, y: 850), CGPoint(x: 250, y: 850)),
            red: (200, 100), clear: (200, 20)),
        // window wider than the frame: scaled down, letterbox bars top and bottom keep clean
        Row(name: "letterbox", window: CGRect(x: 100, y: 100, width: 400, height: 100), primaryHeight: 1000,
            contentRect: CGRect(x: 0, y: 50, width: 400, height: 100), scaleFactor: 2,
            frame: CGSize(width: 400, height: 200),
            line: line(CGPoint(x: 300, y: 750), CGPoint(x: 300, y: 950)),
            red: (200, 100), clear: (200, 10)),
        // window smaller than the frame: native size in the top-left corner
        Row(name: "corner", window: CGRect(x: 100, y: 100, width: 100, height: 50), primaryHeight: 1000,
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 50), scaleFactor: 2,
            frame: CGSize(width: 400, height: 200),
            line: line(CGPoint(x: 150, y: 875), CGPoint(x: 200, y: 875)),
            red: (150, 50), clear: (300, 150)),
        // a display left of and below the primary: negative CG x, y past primaryHeight
        Row(name: "off-primary", window: CGRect(x: -500, y: 1200, width: 200, height: 100), primaryHeight: 1000,
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), scaleFactor: 1,
            frame: CGSize(width: 200, height: 100),
            line: line(CGPoint(x: -450, y: -250), CGPoint(x: -350, y: -250)),
            red: (100, 50), clear: (100, 10)),
    ]

    // Proves Annotations land on the frame where the recorded window shows them, in points or
    // pixels, scaled-down or letterboxed, on or off the primary display — and the bars stay clean.
    @Test(arguments: rows)
    func drawsOnWindowFrame(row: Row) {
        let pb = Self.buffer(width: Int(row.frame.width), height: Int(row.frame.height))
        let annotator = WindowFrameAnnotator(window: row.window, primaryHeight: row.primaryHeight,
                                             contentRect: row.contentRect, scaleFactor: row.scaleFactor,
                                             frame: row.frame)
        #expect(annotator != nil)
        annotator?.draw([row.line], on: pb, source: pb)
        let hit = Self.pixel(pb, x: row.red.x, yFromTop: row.red.y)
        #expect(hit.b < 30 && hit.g < 30 && hit.r > 220 && hit.a == 255,
                "\(row.name): expected red at (\(row.red.x), \(row.red.y)), got \(hit)")
        let miss = Self.pixel(pb, x: row.clear.x, yFromTop: row.clear.y)
        #expect(miss.a == 0, "\(row.name): expected clear at (\(row.clear.x), \(row.clear.y)), got \(miss)")
    }

    /// a 400×200 frame, left half red and right half blue (B,G,R,A order)
    static func splitFrame() -> CVPixelBuffer {
        let pb = buffer(width: 400, height: 200)
        CVPixelBufferLockBaseAddress(pb, [])
        for y in 0..<200 { for x in 0..<400 {
            let p = CVPixelBufferGetBaseAddress(pb)!
                .advanced(by: y * CVPixelBufferGetBytesPerRow(pb) + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            p[0] = x < 200 ? 0 : 255; p[1] = 0; p[2] = x < 200 ? 255 : 0; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// the split frame's window at 2×, a Magnify of global (110,815)-(120,825)
    /// into (150,830)-(190,850) — pixel (140, 120) is the magnifier's centre
    static let splitAnnotator = WindowFrameAnnotator(
        window: CGRect(x: 100, y: 100, width: 200, height: 100), primaryHeight: 1000,
        contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
        scaleFactor: 2, frame: CGSize(width: 400, height: 200))
    static let splitMagnify = Annotation(
        kind: .magnify(Magnifier(source: CGRect(x: 110, y: 815, width: 10, height: 10),
                                 frame: CGRect(x: 150, y: 830, width: 40, height: 20), zoom: 2,
                                 options: .init(shape: .rectangle, leader: false, glass: false))),
        style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))

    // Proves a Magnify samples the frame, not only a Blur/Pixelate Censor:
    // the magnifier over the frame's blue half picks up the red detail.
    @Test func magnifySamplesTheFrame() throws {
        let source = Self.splitFrame(), pb = Self.splitFrame()
        let annotator = try #require(Self.splitAnnotator)
        annotator.draw([Self.splitMagnify], on: pb, source: source)
        let px = Self.pixel(pb, x: 140, yFromTop: 120)
        #expect(px.r > 200 && px.b < 30, "expected the sampled red, got \(px)")
    }

    // Proves a recorded Magnify shows the Annotations beneath it and not the
    // ones above: a green block below its viewport turns the magnifier green,
    // the same block above it leaves the frame's red.
    @Test func magnifySamplesAnnotationsBeneath() throws {
        let green = RGBAColour(red: 0, green: 1, blue: 0, alpha: 1)
        let block = Annotation(kind: .shape(.rectangle(cornerRadius: 0),
                                            rect: CGRect(x: 105, y: 810, width: 20, height: 20)),
                               style: .init(colour: green, width: 1, fill: green, stroked: false))
        let annotator = try #require(Self.splitAnnotator)
        for (layers, expectGreen) in [([block, Self.splitMagnify], true), ([Self.splitMagnify, block], false)] {
            let source = Self.splitFrame(), pb = Self.splitFrame()
            annotator.draw(layers, on: pb, source: source)
            let px = Self.pixel(pb, x: 140, yFromTop: 120)
            if expectGreen {
                #expect(px.g > 200 && px.r < 30, "expected the green beneath, got \(px)")
            } else {
                #expect(px.r > 200 && px.g < 30, "expected the frame's red, got \(px)")
            }
        }
    }

    // Proves a Text Annotation lands in a recorded frame: the white pill over
    // black gives a bright pixel inside its box.
    @Test func drawsTextOnWindowFrame() {
        let row = Self.rows[0]
        let pb = Self.buffer(width: Int(row.frame.width), height: Int(row.frame.height))
        let annotator = WindowFrameAnnotator(window: row.window, primaryHeight: row.primaryHeight,
                                             contentRect: row.contentRect, scaleFactor: row.scaleFactor,
                                             frame: row.frame)
        let d = TextData(string: "Hi", origin: CGPoint(x: 160, y: 885),
                         format: TextFormat(font: "Menlo", size: 20, weight: .bold,
                                            alignment: .left, pill: true))
        let style = AnnotationStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 1), width: 4)
        annotator?.draw([Annotation(kind: .text(d), style: style), row.line], on: pb, source: pb)
        let hit = Self.pixel(pb, x: 160, yFromTop: 40)
        #expect(hit.a > 200 && Int(hit.r) + Int(hit.g) + Int(hit.b) > 300,
                "expected bright pill at (160, 40), got \(hit)")
    }

    // Proves degenerate inputs produce no annotator rather than a bad transform.
    @Test func rejectsDegenerateInput() {
        #expect(WindowFrameAnnotator(window: .zero, primaryHeight: 1000,
                                     contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                                     scaleFactor: 2, frame: CGSize(width: 400, height: 200)) == nil)
        #expect(WindowFrameAnnotator(window: CGRect(x: 100, y: 100, width: 200, height: 100), primaryHeight: 1000,
                                     contentRect: .zero,
                                     scaleFactor: 2, frame: CGSize(width: 400, height: 200)) == nil)
    }
}
