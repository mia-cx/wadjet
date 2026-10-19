import CoreGraphics
import CoreVideo
import Foundation
import Testing
import WadjetKit

struct WindowFrameCompositorTests {
    /// a 32BGRA pixel buffer filled opaque white; `pixel(x, yFromTop)` returns B,G,R,A
    private static func buffer(width w: Int, height h: Int, fill: UInt8 = 255) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        memset(CVPixelBufferGetBaseAddress(b)!, Int32(fill), CVPixelBufferGetBytesPerRow(b) * h)
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
    // a 4-pt opaque red line across the window's middle: frame row 50 from the top
    private static let line = Annotation(
        kind: .line(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 50)),
        style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4))

    // Proves compositing draws the Annotations on a copy: the clean base stays white under
    // the stroke, and composing with none returns a buffer that's white there again.
    @Test func composeNeverTouchesTheBase() {
        let base = Self.buffer(width: 200, height: 100)
        let c = WindowFrameCompositor()
        c.capture(base, contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), scaleFactor: 1)
        let window = CGRect(x: 0, y: 0, width: 200, height: 100)
        let edited = c.compose(window: window, primaryHeight: 100, annotations: [Self.line])
        #expect(edited != nil)
        let hit = Self.pixel(edited!, x: 100, yFromTop: 50)
        #expect(hit.b < 30 && hit.g < 30 && hit.r > 220 && hit.a == 255)
        let clean = Self.pixel(base, x: 100, yFromTop: 50)
        #expect(clean == (255, 255, 255, 255))
        let cleared = c.compose(window: window, primaryHeight: 100, annotations: [])
        #expect(cleared != nil)
        #expect(Self.pixel(cleared!, x: 100, yFromTop: 50) == (255, 255, 255, 255))
    }

    // Proves there's nothing to write before a frame has been captured.
    @Test func composeBeforeCaptureIsNil() {
        let c = WindowFrameCompositor()
        #expect(c.compose(window: CGRect(x: 0, y: 0, width: 200, height: 100),
                          primaryHeight: 100, annotations: [Self.line]) == nil)
    }
}
