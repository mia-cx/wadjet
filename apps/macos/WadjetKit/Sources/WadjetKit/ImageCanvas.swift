import CoreGraphics
import Foundation
import ImageIO

extension CanvasDocument {
    /// A plain image as a Canvas: one display (id 1, origin 0,0) holding the
    /// image at its natural point size — pixel size divided by its DPI scale —
    /// cropped to the whole image. Non-default EXIF orientations are baked in
    /// so the Canvas is upright; DPI of 72 (or none) means scale 1.
    public init(image data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw CanvasDocumentError.imageDecodingFailed }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double
        let scale = dpi.flatMap { $0.isFinite && $0 > 0 ? $0 / 72 : nil } ?? 1
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let image: CGImage
        if orientation == 1 {
            image = try CanvasImageCodec.decode(data)
        } else {
            // thumbnail creation is the only ImageIO decode that applies the orientation
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceShouldAllowFloat: true,
            ] as CFDictionary) else { throw CanvasDocumentError.imageDecodingFailed }
            image = upright
        }
        let frame = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale)
        self.init(layout: [CanvasDisplay(id: 1, frame: frame, scaleFactor: scale)],
            crop: frame, displayImages: [1: image])
    }
}
