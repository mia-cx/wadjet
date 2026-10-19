import CoreGraphics
import CoreImage

extension CanvasDocument {
    /// Composites displays, windows, then Annotations back to front. Crop and radius
    /// are global points; scale is output pixels per point. HDR pixels stay extended.
    /// Black out fills opaque black; Blur and Pixelate sample each display's
    /// image beneath the Censor; Magnify belongs to its own slice.
    public func flatten(crop override: CGRect? = nil, scale: CGFloat = 1) throws -> CGImage {
        let crop = override ?? self.crop
        guard Self.validRect(crop), scale.isFinite, scale > 0,
              cornerRadius.isFinite, cornerRadius >= 0 else { throw CanvasDocumentError.invalidGeometry }
        let width = ceil(crop.width * scale), height = ceil(crop.height * scale)
        guard width.isFinite, height.isFinite, width < CGFloat(Int.max), height < CGFloat(Int.max),
              width >= 1, height >= 1, width * height <= CGFloat(Int.max / 16) else {
            throw CanvasDocumentError.invalidGeometry
        }
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 16,
                bytesPerRow: 0, space: space, bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasDocumentError.renderFailed
        }
        // Bitmap contexts otherwise tone-map known-headroom images to their default SDR target.
        context.setEDRTargetHeadroom(0)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        let radius = min(cornerRadius, min(crop.width, crop.height) / 2)
        context.addPath(CGPath(roundedRect: crop, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        // Apply antialiased crop coverage once to the composite, rather than once per layer.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for display in layout where display.frame.intersects(crop) {
            guard let image = displayImages[display.id] else {
                throw CanvasDocumentError.invalidPackage(display.imageFileName)
            }
            context.draw(image, in: display.frame)
        }
        for window in windowLayers.sorted(by: { $0.zOrder < $1.zOrder }) where window.frame.intersects(crop) {
            context.saveGState()
            // Standalone window captures must not reveal the desktop through
            // their transparent pixels. Other window layers composite normally.
            if window.isolatesBackground { context.setBlendMode(.copy) }
            context.draw(window.image, in: window.frame)
            context.restoreGState()
        }
        // the pixels Blur and Pixelate sample: each display's image beneath the Censor
        let sources = layout.compactMap { d in
            displayImages[d.id].map { CensorSource(image: $0, frame: d.frame) }
        }
        for annotation in layerStack.annotations {
            context.draw(annotation, sources: sources, format: .RGBAh,
                         colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        context.endTransparencyLayer()
        guard let image = context.makeImage() else { throw CanvasDocumentError.renderFailed }
        return image
    }
}
