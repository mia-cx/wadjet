import CoreImage
import CoreImage.CIFilterBuiltins

/// Renders a sampling Censor (Blur, Pixelate) from the pixels beneath its rect.
public enum CensorFilter {
    /// one shared context; CIContext is thread-safe
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Filters the part of `source` under `region` with `method`. `source` covers `sourceRect`
    /// (global points, bottom-left origin, same as CIImage's), its pixels at `source.extent`.
    /// Returns the image and the global rect it covers (region ∩ sourceRect, snapped outward to
    /// whole source pixels), or nil for Black out or when they don't overlap.
    public static func render(_ method: CensorMethod, region: CGRect, source: CIImage, sourceRect: CGRect,
                              format: CIFormat = .RGBA8,
                              colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!)
        -> (image: CGImage, rect: CGRect)? {
        guard method.samplesBeneath else { return nil }
        let area = region.intersection(sourceRect)
        guard !area.isNull, !area.isEmpty else { return nil }
        let scale = source.extent.width / sourceRect.width
        guard scale.isFinite, scale > 0 else { return nil }
        // global points -> source pixels, snapped outward so the whole rect is covered
        let px = CGRect(x: (area.minX - sourceRect.minX) * scale,
                        y: (area.minY - sourceRect.minY) * scale,
                        width: area.width * scale,
                        height: area.height * scale)
        let cropExtent = px.integral.intersection(source.extent)
        guard !cropExtent.isNull, !cropExtent.isEmpty else { return nil }
        let covered = CGRect(x: cropExtent.minX / scale + sourceRect.minX,
                             y: cropExtent.minY / scale + sourceRect.minY,
                             width: cropExtent.width / scale,
                             height: cropExtent.height / scale)
        // crop first, then clamp: the clamp extends the crop's edge pixels so
        // the filter samples them instead of transparent black
        let crop = source.cropped(to: cropExtent).clampedToExtent()
        let filtered: CIImage
        switch method {
        case .blackOut:
            return nil
        case let .blur(radius):
            filtered = crop.applyingGaussianBlur(sigma: radius * scale)
                .cropped(to: cropExtent)
        case let .pixelate(blockSize):
            // centre on the crop's origin so blocks align to the region's corner
            filtered = crop
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: blockSize * scale,
                    kCIInputCenterKey: CIVector(cgPoint: cropExtent.origin),
                ])
                .cropped(to: cropExtent)
        }
        guard let image = context.createCGImage(filtered, from: cropExtent,
                                                format: format, colorSpace: colorSpace) else { return nil }
        return (image, covered)
    }
}
