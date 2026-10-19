import CoreGraphics
import Foundation
import ImageIO

/// Image preparation shared by the Quick Look extensions, without loading app UI.
public enum CanvasQuickLook {
    /// Reads only the saved thumbnail, keeping Finder browsing independent of full Canvas decoding.
    public static func thumbnail(at url: URL, maximumSize: CGSize, scale: CGFloat) throws -> CGImage {
        guard maximumSize.width.isFinite, maximumSize.height.isFinite,
              maximumSize.width > 0, maximumSize.height > 0, scale.isFinite, scale > 0 else {
            throw CanvasDocumentError.invalidGeometry
        }
        let wrapper = try FileWrapper(url: url.appendingPathComponent("thumbnail.png"), options: .immediate)
        guard wrapper.isRegularFile, let data = wrapper.regularFileContents,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CanvasDocumentError.imageDecodingFailed
        }
        // ImageIO downsamples during decoding; never allocate an unbounded thumbnail bitmap.
        let limit = min(4096, ceil(max(maximumSize.width, maximumSize.height) * scale))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { throw CanvasDocumentError.imageDecodingFailed }
        return image
    }

    /// Fits a thumbnail into Quick Look's point-sized drawing context without changing its aspect ratio.
    public static func thumbnailSize(for image: CGImage, maximumSize: CGSize) -> CGSize {
        let factor = min(maximumSize.width / CGFloat(image.width), maximumSize.height / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
    }

    /// Renders the current crop and Annotations as Display P3 PNG, capped at 4096 pixels per edge.
    /// The cap applies before compositing, rather than allocating a full-resolution intermediate.
    public static func previewPNG(for canvas: CanvasDocument) throws -> Data {
        guard CanvasDocument.validRect(canvas.crop) else { throw CanvasDocumentError.invalidGeometry }
        let nativeScale = canvas.layout.filter { $0.frame.intersects(canvas.crop) }.map(\.scaleFactor).max() ?? 1
        let scale = min(nativeScale, 4096 / max(canvas.crop.width, canvas.crop.height))
        return try CanvasImageCodec.png(canvas.flatten(scale: scale))
    }
}
