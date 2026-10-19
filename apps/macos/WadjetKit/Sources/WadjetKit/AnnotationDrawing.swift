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
    /// from `sources` in `format` and `colorSpace`, over black where no source covers them.
    public func draw(_ annotation: Annotation, sources: [CensorSource] = [],
                     format: CIFormat = .RGBA8,
                     colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) {
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
        beginTransparencyLayer(auxiliaryInfo: nil)
        if case .line = annotation.kind {
            // a Line strokes its trimmed drawing and fills its ends,
            // dash pattern scaled to the stroke width
            let cg = annotation.style.colour.cgColor
            let drawing = PathGeometry.drawing(for: annotation)
            setStrokeColor(cg)
            setFillColor(cg)
            setLineWidth(annotation.style.width)
            setLineCap(.round)
            setLineJoin(.round)
            setLineDash(phase: 0, lengths: annotation.style.dash.pattern(width: annotation.style.width) ?? [])
            addPath(drawing.stroke)
            strokePath()
            addPath(drawing.ends)
            fillPath()
        } else {
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
