import AppKit
import SwiftUI
import WadjetKit

/// Shows each Magnify on one Markup panel: a content layer per magnifier —
/// the viewport magnified — added as a sublayer of the Annotation's shape
/// layer so it sits above the source outline, inherits the style's opacity,
/// and keeps its stack order, masked to the shape over a black fallback. The
/// optional border is a CAShapeLayer sibling; the optional Liquid Glass rim
/// is an NSHostingView inside a pass-through wrapper in the panel's
/// container — the wrappers are views, so they sit above the panel's other
/// layers (each masked out where a higher Annotation paints over the
/// magnifier), and the peer-through mask doesn't cut them.
@MainActor final class MagnifierLayers {
    private let screen: NSScreen
    /// the pass-through view the glass rims live in; the MarkupView adds it
    /// above its canvas layers
    let container: NSView
    private var layers: [Annotation.ID: CALayer] = [:]
    private var borders: [Annotation.ID: CAShapeLayer] = [:]
    private var rims: [Annotation.ID: NSHostingView<MagnifierRim>] = [:]
    /// each rim's pass-through wrapper — it carries the mask that keeps a
    /// higher Annotation painting over a lower magnifier's glass
    private var wrappers: [Annotation.ID: NSView] = [:]
    /// the shape each rim's root view was built for — reassign only on change
    private var rimShapes: [Annotation.ID: MagnifierShape] = [:]

    init(screen: NSScreen) {
        self.screen = screen
        container = MagnifierGlassHost()
    }

    /// the panel's annotations each render, in stack order; `layers` is
    /// MarkupView's AnnotationLayer map so each magnifier lands on its own
    /// Magnify's layer
    func sync(_ annotations: [Annotation], layers: [Annotation.ID: AnnotationLayer], scale: CGFloat) {
        var seen = Set<Annotation.ID>()
        var ordered: [NSView] = []
        for (i, a) in annotations.enumerated() {
            guard case let .magnify(m) = a.kind, m.frame.intersects(screen.frame),
                  let shape = layers[a.id] else { continue }
            seen.insert(a.id)
            let layer = self.layers[a.id] ?? CALayer()
            self.layers[a.id] = layer
            if layer.superlayer !== shape { shape.addSublayer(layer) }
            layer.frame = m.frame // canvas sublayers are in global points
            layer.contentsScale = scale
            layer.backgroundColor = CGColor(gray: 0, alpha: 1) // fallback until a sample lands
            layer.contents = MagnifyRenderer.content(
                m, sources: ScreenSamples.shared.sources(covering: m.viewport), scale: scale)
            var t = CGAffineTransform(translationX: -m.frame.minX, y: -m.frame.minY)
            let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
            mask.path = m.options.shape.path(in: m.frame).copy(using: &t)
            mask.frame = CGRect(origin: .zero, size: m.frame.size)
            layer.mask = mask
            if let border = m.options.border {
                let b = borders[a.id] ?? CAShapeLayer()
                borders[a.id] = b
                if b.superlayer !== shape { shape.addSublayer(b) } // after the content layer
                b.path = m.options.shape.path(in: m.frame)
                b.strokeColor = CGColor(srgbRed: border.red, green: border.green,
                                      blue: border.blue, alpha: border.alpha)
                b.fillColor = nil
                b.lineWidth = a.style.width
                b.contentsScale = scale
            } else {
                borders[a.id]?.removeFromSuperlayer()
                borders[a.id] = nil
            }
            if m.options.glass {
                let host = rims[a.id] ?? NSHostingView(rootView: MagnifierRim(shape: m.options.shape))
                rims[a.id] = host
                if rimShapes[a.id] != m.options.shape {
                    host.rootView = MagnifierRim(shape: m.options.shape)
                    rimShapes[a.id] = m.options.shape
                }
                // the wrapper carries the mask — the rim view above the canvas
                // must still lose to every Annotation stacked over its magnifier
                let wrapper = wrappers[a.id] ?? MagnifierGlassHost()
                wrappers[a.id] = wrapper
                wrapper.wantsLayer = true
                wrapper.frame = m.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                wrapper.alphaValue = CGFloat(a.style.opacity)
                if host.superview !== wrapper {
                    wrapper.addSubview(host)
                    host.frame = wrapper.bounds
                    host.autoresizingMask = [.width, .height]
                }
                host.sizingOptions = []
                ordered.append(wrapper)
                // cut the rim wherever a later Annotation paints over the
                // magnifier, at real paint and real opacity — the wrappers are
                // views above every canvas layer. coverage bbox stays the
                // cheap pre-filter; the mask itself renders the annotations
                let occluders = annotations.suffix(from: i + 1).filter {
                    PathGeometry.coverage(for: $0).boundingBoxOfPath.intersects(m.frame)
                }
                if occluders.isEmpty {
                    wrapper.layer?.mask = nil
                } else {
                    let w = max(1, Int(ceil(m.frame.width * scale))),
                        h = max(1, Int(ceil(m.frame.height * scale)))
                    if let ctx = CGContext(data: nil, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue) {
                        ctx.scaleBy(x: scale, y: scale)
                        ctx.translateBy(x: -m.frame.minX, y: -m.frame.minY)
                        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                        ctx.addPath(m.options.shape.path(in: m.frame))
                        ctx.fillPath()
                        ctx.setBlendMode(.destinationOut)
                        for later in occluders {
                            ctx.draw(later, sources: [], scale: scale)
                            // a later Magnify's content can't draw without
                            // sources — its silhouette still occludes this rim
                            if case let .magnify(lm) = later.kind {
                                ctx.addPath(lm.options.shape.path(in: lm.frame))
                                ctx.fillPath()
                            }
                        }
                        let mask = wrapper.layer?.mask ?? CALayer()
                        mask.contents = ctx.makeImage()
                        mask.frame = wrapper.bounds
                        wrapper.layer?.mask = mask
                    }
                }
            } else {
                wrappers[a.id]?.removeFromSuperview()
                wrappers[a.id] = nil
                rims[a.id] = nil
                rimShapes[a.id] = nil
            }
        }
        // rim wrappers stack in annotation order
        if container.subviews != ordered { container.subviews = ordered }
        for id in self.layers.keys where !seen.contains(id) {
            self.layers[id]?.removeFromSuperlayer()
            self.layers[id] = nil
            borders[id]?.removeFromSuperlayer()
            borders[id] = nil
            wrappers[id]?.removeFromSuperview()
            wrappers[id] = nil
            rims[id] = nil
            rimShapes[id] = nil
        }
    }
}

/// the magnifier's Liquid Glass rim — `.clear` is deliberate: ClearGlassPatch
/// turns it into blur-free lensing over the magnified pixels
struct MagnifierRim: View {
    let shape: MagnifierShape
    var body: some View {
        Color.clear.glassEffect(.clear, in: MagnifierOutline(shape: shape))
    }
}

/// adapts a MagnifierShape's CGPath into a SwiftUI Shape for the rim's silhouette
struct MagnifierOutline: Shape {
    let shape: MagnifierShape
    func path(in rect: CGRect) -> Path { Path(shape.path(in: rect)) }
}

/// holds the glass rims without taking clicks — the panels' mouse handling
/// stays on MarkupView
final class MagnifierGlassHost: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}
