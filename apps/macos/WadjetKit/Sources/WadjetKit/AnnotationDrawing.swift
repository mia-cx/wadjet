import CoreGraphics
import CoreImage

/// an image beneath the Annotations, with its frame in Annotation coordinates; Blur and Pixelate sample it
public struct CensorSource: Sendable {
    public let image: CGImage
    public let frame: CGRect
    public init(image: CGImage, frame: CGRect) {
        self.image = image
        self.frame = frame
    }
}

/// a pre-flattened nested Canvas (or an image's pixels) with the rect it
/// covers in its own source space — the frame a crop maps onto via
/// `ImagePlacement.sourceFrame`
public struct CanvasPixels: Sendable {
    public var image: CGImage
    public var bounds: CGRect
    public init(image: CGImage, bounds: CGRect) {
        self.image = image
        self.bounds = bounds
    }
}

extension CGContext {
    /// draws one Annotation as the Markup panels do; hidden ones not at all. Blur and Pixelate render
    /// from `sources` in `format` and `colorSpace`, over black where no source covers them. A Magnify
    /// composites its viewport through MagnifyRenderer at `scale` pixels per point.
    /// `blending: false` draws with the caller's blend mode — for mask passes.
    /// Image kinds draw `images[asset]` through their crop; `.canvas` draws its document —
    /// `linkedDocuments[link.url]` or `embeddedCanvases[name]` — flattened at `scale` (output pixels
    /// per point — export quality), else `canvasPixels[nested]` (a cached flatten — cheap, for
    /// per-frame compositing), else the package's persisted `images[annotation.id]` snapshot,
    /// else nothing.
    public func draw(_ annotation: Annotation, sources: [CensorSource] = [],
                     images: [UUID: CGImage] = [:], linkedDocuments: [URL: CanvasDocument] = [:],
                     embeddedCanvases: [String: CanvasDocument] = [:],
                     canvasPixels: [NestedCanvas: CanvasPixels] = [:],
                     scale: CGFloat = 1, format: CIFormat = .RGBA8,
                     colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                     blending: Bool = true) {
        guard !annotation.hidden else { return }
        saveGState()
        // Text draws its own box — layout, pill and glyphs — in geometry space
        if case .text = annotation.kind {
            TextLayout.draw(annotation, in: self)
            restoreGState()
            return
        }
        if case let .censor(_, method) = annotation.kind, method.samplesBeneath {
            // black underneath first: the fallback for parts off every source
            let path = PathGeometry.path(for: annotation)
            addPath(path)
            clip()
            setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [0, 0, 0, 1])!)
            fill(path.boundingBox)
            let box = path.boundingBox
            for source in sources where source.frame.intersects(box) {
                guard let (image, rect) = CensorFilter.render(
                    method, region: box.intersection(source.frame),
                    source: CIImage(cgImage: source.image), sourceRect: source.frame,
                    format: format,
                    colorSpace: colorSpace) else { continue }
                draw(image, in: rect)
            }
            restoreGState()
            return
        }
        // PathGeometry applies transforms. Composite fill and stroke together
        // at the panel's whole-Annotation opacity; Black out stays opaque.
        if case .censor = annotation.kind { setAlpha(1) }
        else { setAlpha(annotation.style.opacity) }
        // a multiply Annotation darkens what's beneath it in the composite
        if blending, annotation.style.blend == .multiply { setBlendMode(.multiply) }
        beginTransparencyLayer(auxiliaryInfo: nil)
        switch annotation.kind {
        case .line, .path:
            // Lines and paths stroke their trimmed drawing and fill their
            // ends, a closed path's fill under both — dash scaled to the
            // stroke width; `stroked` off drops stroke and ends
            let drawing = PathGeometry.drawing(for: annotation)
            if let fill = drawing.fill, let f = annotation.fillColour {
                setFillColor(f.cgColor)
                addPath(fill)
                fillPath()
            }
            if let c = annotation.strokeColour {
                setStrokeColor(c.cgColor)
                setFillColor(c.cgColor)
                setLineWidth(annotation.style.width)
                setLineCap(.round)
                setLineJoin(.round)
                setLineDash(phase: 0, lengths: annotation.style.dash.pattern(width: annotation.style.width) ?? [])
                addPath(drawing.stroke)
                strokePath()
                addPath(drawing.ends)
                fillPath()
            }
        case .image, .canvas:
            guard let placement = annotation.placement,
                  placement.frame.applying(annotation.affineTransform)
                    .intersects(boundingBoxOfClipPath) else { break }
            concatenate(annotation.affineTransform)
            let frame = placement.frame
            let radius = min(placement.cornerRadius, min(frame.width, frame.height) / 2)
            addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            clip()
            switch annotation.kind {
            case let .image(asset, _):
                if let image = images[asset] {
                    draw(image, in: placement.sourceFrame(
                        for: CGRect(x: 0, y: 0, width: image.width, height: image.height)))
                }
            case let .canvas(nested, _):
                let child = switch nested {
                case let .linked(link): linkedDocuments[link.url]
                case let .embedded(name): embeddedCanvases[name]
                }
                if var child {
                    // the Annotation's own radius rounds it, never the child's
                    child.cornerRadius = 0
                    let k = max(frame.width / placement.crop.width,
                                frame.height / placement.crop.height)
                    if let image = try? child.flatten(crop: placement.crop, scale: scale * k) {
                        draw(image, in: frame)
                    }
                } else if let pixels = canvasPixels[nested] {
                    draw(pixels.image, in: placement.sourceFrame(for: pixels.bounds))
                } else if let snapshot = images[annotation.id] {
                    // the snapshot the host package persisted under the
                    // Annotation's own id — a reopened link still renders
                    draw(snapshot, in: frame)
                }
            default: break
            }
            // the border blends against the image's own pixels inside the clip
            if placement.border != .hidden {
                let inset = ImagePlacement.borderWidth / 2
                setLineWidth(ImagePlacement.borderWidth)
                addPath(CGPath(roundedRect: frame.insetBy(dx: inset, dy: inset),
                    cornerWidth: max(0, radius - inset), cornerHeight: max(0, radius - inset), transform: nil))
                switch placement.border {
                case .difference:
                    setBlendMode(.difference)
                    setStrokeColor(RGBAColour(red: 1, green: 1, blue: 1, alpha: 1).cgColor)
                case .colour:
                    setStrokeColor(annotation.style.colour.cgColor)
                case .hidden: break
                }
                strokePath()
            }
        default:
            let path = PathGeometry.path(for: annotation)
            if let fill = annotation.fillColour {
                setFillColor(fill.cgColor)
                addPath(path)
                fillPath()
            }
            if let stroke = annotation.strokeColour {
                setStrokeColor(stroke.cgColor)
                setLineWidth(annotation.style.width)
                setLineCap(.round)
                setLineJoin(.round)
                addPath(path)
                strokePath()
            }
        }
        if let label = PathGeometry.labelPath(for: annotation) {
            setFillColor(RGBAColour(red: 1, green: 1, blue: 1, alpha: 1).cgColor)
            addPath(label)
            fillPath()
        }
        if case let .magnify(m) = annotation.kind {
            // the magnified viewport, masked to the shape — every source it
            // overlaps feeds MagnifyRenderer, like the Censor branch
            let covering = sources.filter { $0.frame.intersects(m.viewport) }
                .map { (CIImage(cgImage: $0.image), $0.frame) }
            if let content = MagnifyRenderer.content(
                m, sources: covering, scale: scale, format: format,
                colorSpace: colorSpace) {
                let image = m.options.glass
                    ? MagnifyRenderer.glass(content, shape: m.options.shape, scale: scale) ?? content
                    : content
                saveGState()
                addPath(m.options.shape.path(in: m.frame))
                clip()
                draw(image, in: m.frame)
                restoreGState()
            }
            if let border = m.options.border {
                setStrokeColor(border.cgColor)
                setLineWidth(annotation.style.width)
                addPath(m.options.shape.path(in: m.frame))
                strokePath()
            }
        }
        endTransparencyLayer()
        restoreGState()
    }
}

extension RGBAColour {
    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [red, green, blue, alpha])!
    }
}
