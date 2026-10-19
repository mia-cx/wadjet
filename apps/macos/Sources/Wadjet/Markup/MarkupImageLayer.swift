import AppKit
import WadjetKit

/// draws one image-kind Annotation: the source clipped to the placement's
/// rounded frame, its border hairline inside the clip, and — only while
/// recropping — a translucent ghost of the whole source for context
final class MarkupImageLayer: CALayer {
    /// the whole source unclipped and faded — the recrop affordance
    let ghost = CALayer()
    /// rounds the content; the border strokes inside it, blending with the pixels
    let clip = CALayer()
    let content = CALayer()
    let border = CAShapeLayer()

    override init() {
        super.init()
        ghost.opacity = 0.35
        clip.masksToBounds = true
        clip.cornerCurve = .circular
        content.contentsGravity = .resize
        clip.addSublayer(content)
        clip.addSublayer(border)
        addSublayer(ghost)
        addSublayer(clip)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// the Annotation's look in global screen points — position at the frame's
    /// centre, then flips and rotation like `Annotation.affineTransform`
    func update(_ a: Annotation, source: CanvasPixels?,
                cropping: Bool, scale: CGFloat) {
        guard let p = a.placement else { return }
        bounds = CGRect(x: 0, y: 0, width: p.frame.width, height: p.frame.height)
        position = CGPoint(x: p.frame.midX, y: p.frame.midY)
        setAffineTransform(CGAffineTransform(scaleX: a.transform.flipHorizontal ? -1 : 1,
                                             y: a.transform.flipVertical ? -1 : 1)
            .concatenating(CGAffineTransform(rotationAngle: a.transform.rotation)))
        opacity = Float(a.style.opacity)
        for l in [self, ghost, content, border] { l.contentsScale = scale }
        // the source's extent, frame-local: sourceFrame is geometry space
        let sf = source.map { p.sourceFrame(for: $0.bounds)
            .offsetBy(dx: -p.frame.minX, dy: -p.frame.minY) } ?? .zero
        ghost.contents = source?.image
        ghost.frame = sf
        ghost.isHidden = !cropping
        content.contents = source?.image
        content.frame = sf
        clip.frame = bounds
        clip.cornerRadius = min(p.cornerRadius, min(p.frame.width, p.frame.height) / 2)
        border.frame = clip.bounds
        let inset = ImagePlacement.borderWidth / 2
        border.path = CGPath(roundedRect: clip.bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: max(0, clip.cornerRadius - inset), cornerHeight: max(0, clip.cornerRadius - inset),
            transform: nil)
        border.fillColor = nil
        border.lineWidth = ImagePlacement.borderWidth
        border.isHidden = p.border == .hidden
        switch p.border {
        case .difference: // inverts the image's own edge pixels
            border.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            border.compositingFilter = CIFilter(name: "CIDifferenceBlendMode")
        case .colour:
            let c = a.style.colour
            border.strokeColor = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
            border.compositingFilter = nil
        case .hidden:
            border.compositingFilter = nil
        }
    }
}
