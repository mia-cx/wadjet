import CoreGraphics
import CoreVideo
import Foundation

/// Keeps the last clean Record Window frame so Annotations can be recomposited over it when they
/// change: a still window sends no new frames. Not thread-safe; use it from one queue.
public final class WindowFrameCompositor {
    private var base: CVPixelBuffer?
    private var contentRect: CGRect = .zero
    private var scaleFactor: CGFloat = 0
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    public init() {}

    /// remembers `frame` as the clean base, with the SCStreamFrameInfo values that place the window in it
    public func capture(_ frame: CVPixelBuffer, contentRect: CGRect, scaleFactor: CGFloat) {
        base = frame
        self.contentRect = contentRect
        self.scaleFactor = scaleFactor
    }

    /// the frame to write: the clean base itself when `annotations` is empty or the window can't be
    /// placed, else a copy of it from a reused pool with the Annotations drawn on; nil before any capture
    public func compose(window: CGRect, primaryHeight: CGFloat, annotations: [Annotation]) -> CVPixelBuffer? {
        guard let base else { return nil }
        let frame = CGSize(width: CVPixelBufferGetWidth(base), height: CVPixelBufferGetHeight(base))
        let annotator = WindowFrameAnnotator(window: window, primaryHeight: primaryHeight,
                                             contentRect: contentRect, scaleFactor: scaleFactor,
                                             frame: frame)
        guard !annotations.isEmpty, let annotator, let out = outputBuffer(size: frame) else { return base }
        copy(base: base, to: out)
        annotator.draw(annotations, on: out, source: base)
        return out
    }

    /// a fresh 32BGRA buffer from the reused pool; the pool is rebuilt when the base size changes
    private func outputBuffer(size: CGSize) -> CVPixelBuffer? {
        if size != poolSize {
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
                [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                 kCVPixelBufferWidthKey: Int(size.width),
                 kCVPixelBufferHeightKey: Int(size.height),
                 kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary,
                &pool)
            poolSize = size
        }
        var out: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess
        else { return nil }
        return out
    }

    /// the base's pixels into `out`, row by row — their bytesPerRow may differ
    private func copy(base: CVPixelBuffer, to out: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(base, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(base, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(base),
              let dst = CVPixelBufferGetBaseAddress(out) else { return }
        let n = min(CVPixelBufferGetBytesPerRow(base), CVPixelBufferGetBytesPerRow(out))
        for row in 0..<CVPixelBufferGetHeight(base) {
            memcpy(dst.advanced(by: row * CVPixelBufferGetBytesPerRow(out)),
                   src.advanced(by: row * CVPixelBufferGetBytesPerRow(base)), n)
        }
    }
}
