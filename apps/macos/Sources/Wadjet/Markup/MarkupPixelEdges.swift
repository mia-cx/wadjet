import AppKit
import WadjetKit

/// Owns one gesture's still image and, on first use, its readable ARGB bitmap.
/// No screen capture or image conversion occurs on subsequent pointer events.
@MainActor final class MarkupPixelEdges {
    let image: CGImage
    let bounds: CGRect
    private lazy var bitmap: CGContext? = {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            AppLog.line("markup: could not allocate pixel snapping bitmap")
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }()

    init(image: CGImage, bounds: CGRect) {
        self.image = image
        self.bounds = bounds
    }

    func targets(rect: CGRect?, points: [CGPoint], range: CGFloat) -> [SnapTarget] {
        let nearby = bounds.insetBy(dx: -range, dy: -range)
        guard rect.map({ nearby.intersects($0) }) == true || points.contains(where: nearby.contains),
              let data = bitmap?.data else { return [] }
        let pixels = PixelBuffer(base: data.assumingMemoryBound(to: UInt8.self), width: image.width, height: image.height)
        return pixels.snapTargets(rect: rect, points: points, bounds: bounds, range: range)
    }
}
