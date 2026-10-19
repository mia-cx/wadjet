import AppKit
import WadjetKit

/// one Annotation on screen: `fill` at the bottom (a closed path's interior),
/// `stroke` above (the dash-patterned body), `ends` on top (arrowheads, dots,
/// bars — all filled with the stroke colour). Shapes and Censors draw on
/// `stroke` alone, like upstream's shape layer; a counter adds `label` — its
/// white glyph outlines on top.
final class AnnotationLayer: CALayer {
    let fill = CAShapeLayer()
    let stroke = CAShapeLayer()
    let ends = CAShapeLayer()
    let label = CAShapeLayer()

    override init() {
        super.init()
        allowsGroupOpacity = true
        stroke.fillColor = nil
        stroke.lineCap = .round
        stroke.lineJoin = .round
        addSublayer(fill)
        addSublayer(stroke)
        addSublayer(ends)
        addSublayer(label)
    }
    // Core Animation copies layers for presentation through this initialiser
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// repaints the paths from the Annotation's drawing and restyles them;
    /// a Censor ignores the style: opaque black fill over its rect
    func update(_ a: Annotation, scale: CGFloat) {
        switch a.kind {
        case .censor:
            fill.path = nil
            stroke.path = PathGeometry.path(for: a)
            stroke.lineDashPattern = nil
            stroke.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            stroke.strokeColor = nil
            ends.path = nil
            opacity = 1
        case .shape, .counter, .magnify:
            // upstream's look: one path, filled and stroked by the style's
            // colours; a counter's glyph outline sits on top in white, a
            // Magnify's source outline and leader are its path
            fill.path = nil
            ends.path = nil
            stroke.path = PathGeometry.path(for: a)
            stroke.lineDashPattern = nil
            stroke.fillColor = a.fillColour.map {
                CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
            stroke.strokeColor = a.strokeColour.map {
                CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
            stroke.lineWidth = a.style.width
            opacity = Float(a.style.opacity)
        default:
            updateStroke(a)
        }
        // a counter's label: white child layer, gone when there's no label
        label.path = PathGeometry.labelPath(for: a)
        label.fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        label.strokeColor = nil
        for l in [self, fill, stroke, ends, label] as [CALayer] { l.contentsScale = scale }
    }

    private func updateStroke(_ a: Annotation) {
        let d = PathGeometry.drawing(for: a)
        fill.path = d.fill
        fill.fillColor = a.style.fill.map {
            CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
        }
        // a closed path with `stroked` off leaves only its fill, like a shape
        let c = a.strokeColour
        stroke.path = c == nil ? nil : d.stroke
        stroke.fillColor = nil
        ends.path = c == nil ? nil : d.ends
        let colour = c.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
        stroke.strokeColor = colour
        ends.fillColor = colour
        stroke.lineWidth = a.style.width
        stroke.lineDashPattern = a.style.dash.pattern(width: a.style.width)?.map { $0 as NSNumber }
        opacity = Float(a.style.opacity)
    }
}
