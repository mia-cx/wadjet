import CoreGraphics
import CoreVideo
import Foundation

/// Record Window captures the window alone, so the Markup panels above it never reach the video;
/// this draws the Annotations onto each frame where the window shows them.
public struct WindowFrameAnnotator: Equatable, Sendable {
    /// global AppKit points (bottom-left origin) -> the frame's bitmap-context coordinates (bottom-left origin, pixels)
    public let transform: CGAffineTransform
    /// the window's content inside the frame, in bitmap-context coordinates; letterbox bars stay clean
    public let clip: CGRect
    /// - window: the window's bounds in CG global points (top-left origin of the primary display, y down), as kCGWindowBounds reports it
    /// - primaryHeight: the primary display's height in points (flips AppKit y into CG y)
    /// - contentRect: SCStreamFrameInfo.contentRect, top-left origin within the frame; ScreenCaptureKit doesn't document whether it is points or pixels, so its unit is inferred
    /// - scaleFactor: SCStreamFrameInfo.scaleFactor
    /// - frame: the pixel buffer's size in pixels
    public init?(window: CGRect, primaryHeight: CGFloat, contentRect: CGRect, scaleFactor: CGFloat, frame: CGSize) {
        guard window.width > 0, window.height > 0, contentRect.width > 0,
              scaleFactor > 0, frame.width > 0, frame.height > 0 else { return nil }
        // ScreenCaptureKit only scales down; the nearer of points or pixels to the expected size is contentRect's unit
        let e = window.width * scaleFactor
            * min(1, frame.width / (window.width * scaleFactor), frame.height / (window.height * scaleFactor))
        let u: CGFloat = abs(contentRect.width - e) <= abs(contentRect.width * scaleFactor - e) ? 1 : scaleFactor
        let c = CGRect(x: contentRect.minX * u, y: contentRect.minY * u,
                       width: contentRect.width * u, height: contentRect.height * u) // pixels, top-left origin
        let s = c.width / window.width // pixels per point
        transform = CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                      tx: c.minX - s * window.minX,
                                      ty: frame.height - c.minY - s * (primaryHeight - window.minY))
        clip = CGRect(x: c.minX, y: frame.height - c.maxY, width: c.width, height: c.height)
    }

    /// draws `annotations` into a 32BGRA pixel buffer in place; no-op for an empty list.
    /// `source` supplies the clean pixels Blur and Pixelate sample — never the buffer being drawn on.
    /// `images`/`canvasPixels` feed image-kind Annotations: pre-flattened link
    /// pixels, since a live flatten per frame would cost a render every time.
    public func draw(_ annotations: [Annotation], on pixelBuffer: CVPixelBuffer, source: CVPixelBuffer,
                     images: [UUID: CGImage] = [:], canvasPixels: [NestedCanvas: CanvasPixels] = [:]) {
        guard !annotations.isEmpty else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        // the frame's content under the clip as a CensorSource, only when an
        // Annotation samples it — a Blur/Pixelate Censor or a Magnify's viewport
        var sources: [CensorSource] = []
        if annotations.contains(where: { !$0.hidden && $0.sampledRect != nil }) {
            CVPixelBufferLockBaseAddress(source, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
            if let b = CVPixelBufferGetBaseAddress(source),
               let raw = CGContext(data: b, width: w, height: h, bitsPerComponent: 8,
                   bytesPerRow: CVPixelBufferGetBytesPerRow(source),
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
               let whole = raw.makeImage(),
               let cropped = whole.cropping(to: CGRect(x: clip.minX, y: CGFloat(h) - clip.maxY,
                                                       width: clip.width, height: clip.height)) {
                sources = [CensorSource(image: cropped, frame: clip.applying(transform.inverted()))]
            }
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.clip(to: clip)
        context.concatenate(transform)
        for annotation in annotations {
            context.draw(annotation, sources: sources, images: images, canvasPixels: canvasPixels)
        }
    }
}
