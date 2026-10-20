import CoreGraphics
import CoreImage

extension CanvasDocument {
    /// Composites displays, backdrop windows, then Annotations back to front.
    /// Crop and radius are global points; scale is output pixels per point. HDR
    /// pixels stay extended. Black out fills opaque black; Blur and Pixelate
    /// sample each display's image beneath them plus the visible window layers
    /// stacked beneath them, a Magnify every visible layer stacked beneath it
    /// (`sampledBeneath`). A `.window` Annotation draws the
    /// window layer it names — layers without an id form the backdrop beneath
    /// every Annotation.
    /// Black out fills opaque black; Blur and Pixelate sample each display's
    /// image beneath the Censor; a Magnify strokes its source outline and
    /// composites its magnified viewport through MagnifyRenderer. `.image` draws
    /// its asset through its crop, `.canvas` its `linkedDocuments` or
    /// `embeddedCanvases` entry, else its persisted snapshot.
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
        for window in windowLayers.filter({ $0.id == nil }).sorted(by: { $0.zOrder < $1.zOrder })
            where window.frame.intersects(crop) {
            context.saveGState()
            // Standalone window captures must not reveal the desktop through
            // their transparent pixels. Other window layers composite normally.
            if window.isolatesBackground { context.setBlendMode(.copy) }
            context.draw(window.image, in: window.frame)
            context.restoreGState()
        }
        // the pixels Blur, Pixelate and Magnify sample: each display's image
        // beneath them
        let displaySources = layout.compactMap { d in
            displayImages[d.id].map { CensorSource(image: $0, frame: d.frame) }
        }
        let windows = Dictionary(windowLayers.compactMap { w in w.id.map { ($0, w) } },
                                 uniquingKeysWith: { a, _ in a })
        for (index, annotation) in layerStack.annotations.enumerated() {
            if case let .window(layerID, frame) = annotation.kind {
                guard !annotation.hidden else { continue }
                guard let layer = windows[layerID] else {
                    throw CanvasDocumentError.invalidPackage("window Annotation \(layerID) has no layer")
                }
                context.saveGState()
                context.setAlpha(annotation.style.opacity)
                if annotation.style.blend == .multiply { context.setBlendMode(.multiply) }
                context.concatenate(annotation.affineTransform)
                context.draw(layer.image, in: frame)
                context.restoreGState()
                continue
            }
            guard !annotation.hidden else { continue }
            // a missing asset corrupts the package's own data, so it fails loudly
            if case let .image(asset, _) = annotation.kind, images[asset] == nil {
                throw CanvasDocumentError.invalidPackage("images/\(asset.uuidString)")
            }
            if case let .canvas(.embedded(name), _) = annotation.kind, embeddedCanvases[name] == nil {
                throw CanvasDocumentError.invalidPackage("embedded/\(name)")
            }
            var sources = displaySources
            if let box = annotation.sampledRect {
                let below = Self.sampledBeneath(annotation, in: layerStack.annotations[..<index])
                if !below.isEmpty, let b = try beneathSource(layers: below, rect: box, scale: scale) {
                    sources = [b]
                }
            }
            context.draw(annotation, sources: sources, images: images,
                         linkedDocuments: linkedDocuments, embeddedCanvases: embeddedCanvases,
                         scale: scale, format: .RGBAh,
                         colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        context.endTransparencyLayer()
        guard let image = context.makeImage() else { throw CanvasDocumentError.renderFailed }
        return image
    }

    /// What a sampling Annotation sees above the displays, from the layers
    /// `below` it, back to front: a Magnify sees every visible Annotation —
    /// never itself or anything above it — a Blur or Pixelate Censor only the
    /// visible window layers
    public static func sampledBeneath(_ annotation: Annotation,
                                      in below: ArraySlice<Annotation>) -> [Annotation] {
        below.filter {
            guard !$0.hidden else { return false }
            if case .magnify = annotation.kind { return true }
            if case .window = $0.kind { return true }
            return false
        }
    }

    /// The pixels a sampling Annotation reads when layers sit beneath it: the
    /// displays plus `layers` (visible Annotations from `sampledBeneath`, back
    /// to front; backdrop layers stay out) rendered over `rect` snapped outward to the
    /// pixel grid at `scale` — at least `scale` pixels per point, and the
    /// captured displays' own density where higher, so magnifying never starts
    /// from a downsampled source. The frame's size comes from the rendered
    /// image. Moved windows are sampled where they sit, not where the flat
    /// displays froze them — the filters only read inside their sampled rect.
    /// Returns nil when no layer paints on `rect` or the snapped rect isn't
    /// valid — callers then keep the display sources unchanged.
    public func beneathSource(layers: [Annotation], rect: CGRect,
                            scale: CGFloat) throws -> CensorSource? {
        let paints = layers.map { PathGeometry.coverage(for: $0).boundingBoxOfPath.intersects(rect) }
        guard paints.contains(true) else { return nil }
        // a sampling layer that paints here reads the layers beneath it
        // wherever they sit, so everything under the topmost one stays
        let sampler = layers.indices.last { paints[$0] && layers[$0].sampledRect != nil } ?? -1
        let touching = layers.indices.filter { $0 < sampler || paints[$0] }.map { layers[$0] }
        let density = max(scale, layout.filter { $0.frame.intersects(rect) }
            .map(\.scaleFactor).max() ?? 0)
        // snap outward to the output pixel grid: flatten allocates
        // ceil-sized pixels, and the filters infer one scale from
        // width — an unsnapped box would leave a strip unsampled. The
        // frame's size comes from the rendered image: at fractional
        // scales snapped.width*scale can round up a pixel, so the
        // image is the exact record of what was rendered (pixel i
        // covers snapped.min + i/scale; a roundoff pixel sits past
        // the edge).
        let snapped = CGRect(x: floor(rect.minX * density) / density,
                             y: floor(rect.minY * density) / density,
                             width: ceil(rect.maxX * density) / density - floor(rect.minX * density) / density,
                             height: ceil(rect.maxY * density) / density - floor(rect.minY * density) / density)
        guard Self.validRect(snapped) else { return nil }
        var beneath = self
        beneath.layerStack = LayerStack(touching)
        beneath.cornerRadius = 0
        beneath.windowLayers = windowLayers.filter { $0.id != nil }
        let image = try beneath.flatten(crop: snapped, scale: density)
        return CensorSource(image: image, frame: CGRect(
            origin: snapped.origin,
            size: CGSize(width: CGFloat(image.width) / density,
                         height: CGFloat(image.height) / density)))
    }
}
