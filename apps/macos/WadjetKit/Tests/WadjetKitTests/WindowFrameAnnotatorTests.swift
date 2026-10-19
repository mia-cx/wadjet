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
        annotator?.draw([row.line], on: pb)
        let hit = Self.pixel(pb, x: row.red.x, yFromTop: row.red.y)
        #expect(hit.b < 30 && hit.g < 30 && hit.r > 220 && hit.a == 255,
                "\(row.name): expected red at (\(row.red.x), \(row.red.y)), got \(hit)")
        let miss = Self.pixel(pb, x: row.clear.x, yFromTop: row.clear.y)
        #expect(miss.a == 0, "\(row.name): expected clear at (\(row.clear.x), \(row.clear.y)), got \(miss)")
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
