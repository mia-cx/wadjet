import AppKit
import SwiftUI
import WadjetKit

/// Shows each Magnify on one Markup view, in one of two modes. A screen
/// panel's magnifiers sample live through ScreenSamples and wear Liquid Glass
/// rims — NSHostingViews inside pass-through wrappers in `container`, views
/// above the panel's other layers (each masked out where a higher Annotation
/// paints over the magnifier). An Editor's magnifiers draw the Canvas's own
/// display images plus the windows stacked beneath each Magnify, and flatten
/// the glass in — `MagnifyRenderer.glass` stands
/// in for the live rims so the view shows what a Screenshot will flatten to.
/// Either way: a content layer per magnifier — the viewport magnified — added
/// as a sublayer of the Annotation's shape layer so it sits above the source
/// outline, inherits the style's opacity, and keeps its stack order, masked
/// to the shape over a black fallback; the optional border is a CAShapeLayer
/// sibling.
@MainActor final class MagnifierLayers {
    /// nil in static mode — a screen panel streams its display through ScreenSamples
    private let screen: NSScreen?
    /// nil in live mode — an Editor's fixed sources: the Canvas's display images
    private let staticSources: [MagnifyRenderer.Source]?
    /// static mode's windows-beneath render: `CanvasDocument.beneathSource`,
    /// so a Magnify samples moved windows where they sit, like flatten
    private let beneath: (([Annotation], CGRect, CGFloat) -> CensorSource?)?
    /// static mode renders at the Canvas's own scale; nil means the sync scale
    private let staticScale: CGFloat?
    /// the global rect magnifiers draw within — the display's frame or the Canvas's bounds
    private let coverage: CGRect
    /// the pass-through view the glass rims live in; nil in static mode
    let container: NSView?
    private var layers: [Annotation.ID: CALayer] = [:]
    private var borders: [Annotation.ID: CAShapeLayer] = [:]
    private var rims: [Annotation.ID: NSHostingView<MagnifierRim>] = [:]
    /// each rim's pass-through wrapper — it carries the mask that keeps a
    /// higher Annotation painting over a lower magnifier's glass
    private var wrappers: [Annotation.ID: NSView] = [:]
    /// the shape each rim's root view was built for — reassign only on change
    private var rimShapes: [Annotation.ID: MagnifierShape] = [:]

    /// a screen panel's magnifiers: the live stream and Liquid Glass rims
    init(screen: NSScreen) {
        self.screen = screen
        coverage = screen.frame
        staticSources = nil
        beneath = nil
        staticScale = nil
        container = MagnifierGlassHost()
    }

    /// an Editor's magnifiers: the Canvas's displays, plus the windows beneath
    /// each Magnify through `beneath`, at `scale`; the flattened glass pass
    /// stands in for the live rims — no container
    init(staticSources: [MagnifyRenderer.Source], scale: CGFloat,
         beneath: @escaping ([Annotation], CGRect, CGFloat) -> CensorSource?) {
        screen = nil
        self.staticSources = staticSources
        self.beneath = beneath
        staticScale = scale
        coverage = staticSources.reduce(.null) { $0.union($1.rect) }
        container = nil
    }

    /// the panel's annotations each render, in stack order; `layers` is
    /// MarkupView's AnnotationLayer map so each magnifier lands on its own
    /// Magnify's layer
    func sync(_ annotations: [Annotation], layers: [Annotation.ID: AnnotationLayer], scale: CGFloat) {
        var seen = Set<Annotation.ID>()
        var ordered: [NSView] = []
        let renderScale = staticScale ?? scale
        for (i, a) in annotations.enumerated() {
            guard case let .magnify(m) = a.kind, m.frame.intersects(coverage),
                  let shape = layers[a.id] else { continue }
            seen.insert(a.id)
            let layer = self.layers[a.id] ?? CALayer()
            self.layers[a.id] = layer
            if layer.superlayer !== shape { shape.addSublayer(layer) }
            layer.frame = m.frame // canvas sublayers are in global points
            layer.contentsScale = renderScale
            layer.backgroundColor = CGColor(gray: 0, alpha: 1) // fallback until a sample lands
            var sources: [MagnifyRenderer.Source]
            if let staticSources {
                // what flatten samples: only the visible windows beneath this
                // Magnify in stack order; none falls back to the displays
                let below = annotations[..<i].filter {
                    if case .window = $0.kind { return !$0.hidden }
                    return false
                }
                // `beneath` answers nil when no window paints the viewport —
                // fall back to the display sources, like flatten does
                if let b = beneath?(below, m.viewport, renderScale) {
                    sources = [(CIImage(cgImage: b.image), b.frame)]
                } else {
                    sources = staticSources.filter { $0.rect.intersects(m.viewport) }
                }
            } else {
                sources = ScreenSamples.shared.sources(covering: m.viewport)
            }
            var content = MagnifyRenderer.content(m, sources: sources, scale: renderScale)
            // static mode is what the Screenshot flattens to: bake the glass in
            if staticSources != nil, m.options.glass, let c = content {
                content = MagnifyRenderer.glass(c, shape: m.options.shape,
                                                scale: renderScale) ?? c
            }
            layer.contents = content
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
            if let screen, container != nil, m.options.glass {
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
                            // the rim's mask keeps the caller's blend mode —
                            // a multiply Highlighter would keep it visible
                            ctx.draw(later, sources: [], scale: scale, blending: false)
                            // a later Magnify's content can't draw without
                            // sources — its silhouette occludes this rim at
                            // its own opacity (ctx.draw left state restored)
                            if case let .magnify(lm) = later.kind {
                                ctx.setAlpha(later.style.opacity)
                                ctx.addPath(lm.options.shape.path(in: lm.frame))
                                ctx.fillPath()
                                ctx.setAlpha(1)
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
        if let container, container.subviews != ordered { container.subviews = ordered }
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
