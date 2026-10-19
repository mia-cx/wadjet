import AppKit
import SwiftUI
import WadjetKit

/// Shows each Magnify on one Markup panel: a content layer per magnifier —
/// the viewport magnified — added as a sublayer of the Annotation's shape
/// layer so it sits above the source outline, inherits the style's opacity,
/// and keeps its stack order, masked to the shape over a black fallback. The
/// optional border is a CAShapeLayer sibling; the optional Liquid Glass rim
/// is an NSHostingView in the panel's pass-through container — the rims are
/// views, so they sit above the panel's other layers, and the peer-through
/// mask doesn't cut them.
@MainActor final class MagnifierLayers {
    private let screen: NSScreen
    /// the pass-through view the glass rims live in; the MarkupView adds it
    /// above its canvas layers
    let container: NSView
    private var layers: [Annotation.ID: CALayer] = [:]
    private var borders: [Annotation.ID: CAShapeLayer] = [:]
    private var rims: [Annotation.ID: NSHostingView<MagnifierRim>] = [:]
    /// the shape each rim's root view was built for — reassign only on change
    private var rimShapes: [Annotation.ID: MagnifierShape] = [:]

    init(screen: NSScreen) {
        self.screen = screen
        container = MagnifierGlassHost()
    }

    /// the panel's annotations each render; `layers` is MarkupView's shape
    /// layer map so each magnifier lands on its own Magnify's layer
    func sync(_ annotations: [Annotation], layers: [Annotation.ID: CAShapeLayer], scale: CGFloat) {
        let magnifying = annotations.filter { a in
            guard case let .magnify(m) = a.kind else { return false }
            return m.frame.intersects(screen.frame)
        }
        var seen = Set<Annotation.ID>()
        for a in magnifying {
            seen.insert(a.id)
            guard case let .magnify(m) = a.kind, let shape = layers[a.id] else { continue }
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
                if host.superview !== container { container.addSubview(host) }
                host.sizingOptions = []
                host.frame = m.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                host.alphaValue = CGFloat(a.style.opacity)
            } else {
                rims[a.id]?.removeFromSuperview()
                rims[a.id] = nil
                rimShapes[a.id] = nil
            }
        }
        for id in self.layers.keys where !seen.contains(id) {
            self.layers[id]?.removeFromSuperlayer()
            self.layers[id] = nil
            borders[id]?.removeFromSuperlayer()
            borders[id] = nil
            rims[id]?.removeFromSuperview()
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
