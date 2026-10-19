import CoreGraphics
import ImageIO

/// Decodes an imported image — a paste or a drop — into upright pixels and
/// its natural point size: pixels × 72 / the image's own DPI (default 72).
public enum ImportedImage {
    /// the CGImage and its point size; nil when the source doesn't decode
    public static func decode(_ source: CGImageSource) -> (image: CGImage, size: CGSize)? {
        guard var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation != 1 {
            // a thumbnail with transform bakes the orientation into the pixels
            guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height),
            ] as CFDictionary) else { return nil }
            image = upright
        }
        func dpi(_ key: CFString) -> CGFloat { (props?[key] as? CGFloat) ?? 72 }
        var w = dpi(kCGImagePropertyDPIWidth), h = dpi(kCGImagePropertyDPIHeight)
        // orientations 5–8 swap the axes: the stored DPI axes swap with them
        if orientation >= 5 { swap(&w, &h) }
        return (image, CGSize(width: CGFloat(image.width) * 72 / w,
                              height: CGFloat(image.height) * 72 / h))
    }
}
