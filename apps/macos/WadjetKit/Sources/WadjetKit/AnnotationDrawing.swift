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

extension CGContext {
    /// draws one Annotation as the Markup panels do; hidden ones not at all. Blur and Pixelate render
    /// from `sources` in `format` and `colorSpace`, over black where no source covers them. A Magnify
    /// composites its viewport through MagnifyRenderer at `scale` pixels per point.
    /// `blending: false` draws with the caller's blend mode — for mask passes.
    public func draw(_ annotation: Annotation, sources: [CensorSource] = [], scale: CGFloat = 1,
                     format: CIFormat = .RGBA8,
                     colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                     blending: Bool = true) {
        guard !annotation.hidden else { return }
        saveGState()
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
