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
        for annotation in layerStack.annotations where !annotation.hidden {
            context.saveGState()
            if case let .censor(_, method) = annotation.kind, method.samplesBeneath {
                // black underneath first: the fallback for parts off every display
                let path = PathGeometry.path(for: annotation)
                context.addPath(path)
                context.clip()
                context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             components: [0, 0, 0, 1])!)
                context.fill(path.boundingBox)
                let box = path.boundingBox
                for display in layout where display.frame.intersects(box) {
                    guard let cg = displayImages[display.id],
                          let (image, rect) = CensorFilter.render(
                            method, region: box.intersection(display.frame),
                            source: CIImage(cgImage: cg), sourceRect: display.frame,
                            format: .RGBAh,
                            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else { continue }
                    context.draw(image, in: rect)
                }
                context.restoreGState()
                continue
            }
            // PathGeometry applies transforms. Composite fill and stroke together
            // at the panel's whole-Annotation opacity; Black out stays opaque.
            if case .censor = annotation.kind { context.setAlpha(1) }
            else { context.setAlpha(annotation.style.opacity) }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if case .line = annotation.kind {
                // a Line strokes its trimmed drawing and fills its ends,
                // dash pattern scaled to the stroke width
                let cg = annotation.style.colour.cgColor
                let drawing = PathGeometry.drawing(for: annotation)
                context.setStrokeColor(cg)
                context.setFillColor(cg)
                context.setLineWidth(annotation.style.width)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setLineDash(phase: 0, lengths: annotation.style.dash.pattern(width: annotation.style.width) ?? [])
                context.addPath(drawing.stroke)
                context.strokePath()
                context.addPath(drawing.ends)
                context.fillPath()
            } else {
                let path = PathGeometry.path(for: annotation)
                if let fill = annotation.fillColour {
                    context.setFillColor(fill.cgColor)
                    context.addPath(path)
                    context.fillPath()
                }
                if let stroke = annotation.strokeColour {
                    context.setStrokeColor(stroke.cgColor)
                    context.setLineWidth(annotation.style.width)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    context.addPath(path)
                    context.strokePath()
                }
            }
            if let label = PathGeometry.labelPath(for: annotation) {
                context.setFillColor(RGBAColour(red: 1, green: 1, blue: 1, alpha: 1).cgColor)
                context.addPath(label)
                context.fillPath()
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
        context.endTransparencyLayer()
        guard let image = context.makeImage() else { throw CanvasDocumentError.renderFailed }
        return image
    }
}

private extension RGBAColour {
    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [red, green, blue, alpha])!
    }
}
