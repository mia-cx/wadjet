import AppKit
import CoreImage
import QuartzCore
import WadjetKit

/// Shows Blur and Pixelate on one Markup view: one image layer per sampling
/// Censor, masked to its path, above its black shape layer (which stays as the
/// Black out fallback until a sample lands). A screen panel's pixels come
/// from ScreenSamples — the Freeze Frame's cursor-free image or the shared
/// live stream; an Editor's come from the Canvas's own flat image.
@MainActor final class CensorLayers {
    /// nil on an Editor's view — it has no display to stream
    private let screen: NSScreen?
    /// the global rect sampling covers: the display's frame, or the Canvas's bounds
    private let coverage: CGRect
    private let contentScale: CGFloat
    /// an Editor's source renderer: the visible `.window` Annotations beneath a
    /// Censor in, the Canvas flattened with them — mirrors CanvasRenderer
    private let render: (([Annotation]) -> CGImage?)?
    /// an Editor's rendered sources by the windows beneath the Censor, reused
    /// across syncs until a sync uses them no more
    private var staticSources: [(windows: [Annotation], image: CIImage?)] = []
    private var imageLayers: [Annotation.ID: CALayer] = [:]

    /// a screen panel's Censors draw from the shared ScreenSamples
    init(screen: NSScreen) {
        self.screen = screen
        coverage = screen.frame
        contentScale = screen.backingScaleFactor
        render = nil
    }

    /// an Editor's Censors sample the Canvas's own flat image — no live
    /// stream; `render` re-flattens it from the windows beneath a Censor
    init(coverage: CGRect, scale: CGFloat, render: @escaping ([Annotation]) -> CGImage?) {
        screen = nil
        self.coverage = coverage
        contentScale = scale
        self.render = render
    }

    /// the view's annotations each render; `layers` is MarkupView's
    /// AnnotationLayer map so each sample lands on its own Censor's layer
    func sync(_ annotations: [Annotation], layers: [Annotation.ID: AnnotationLayer]) {
        let sampling = annotations.filter { a in
            guard case let .censor(_, m) = a.kind, m.samplesBeneath else { return false }
            return PathGeometry.path(for: a).boundingBox.intersects(coverage)
        }
        // the shared source for the screen: ScreenSamples' frozen frame or
        // live stream; an Editor resolves each Censor's own in the loop below
        let shared = screen.flatMap { ScreenSamples.shared.source(on: $0) }
        var usedWindowSets: [[Annotation]] = []
        // standalone layers outside the panel's own transaction need implicit
        // animations off, or every new sample would smear in
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<Annotation.ID>()
        for a in sampling {
            seen.insert(a.id)
            guard case let .censor(_, method) = a.kind, let shape = layers[a.id] else { continue }
            let box = PathGeometry.path(for: a).boundingBox.intersection(coverage)
            let layer = imageLayers[a.id] ?? CALayer()
            imageLayers[a.id] = layer
            if layer.superlayer !== shape { shape.addSublayer(layer) }
            layer.contentsScale = contentScale
            var source: CIImage?, sourceRect = CGRect.zero
            if let render {
                // what flatten samples: only the visible windows beneath this
                // Censor in stack order — cached per distinct set
                let i = annotations.firstIndex(where: { $0.id == a.id }) ?? annotations.endIndex
                let below = Array(annotations[..<i]).filter {
                    if case .window = $0.kind { return !$0.hidden }
                    return false
                }
                if let cached = staticSources.first(where: { $0.windows == below }) {
                    source = cached.image
                } else {
                    source = render(below).map(CIImage.init)
                    staticSources.append((below, source))
                }
                usedWindowSets.append(below)
                sourceRect = coverage
            } else if let shared {
                source = shared.image
                sourceRect = shared.rect
            }
            guard let source,
                  let (image, rect) = CensorFilter.render(method, region: box,
                                                          source: source, sourceRect: sourceRect) else {
                layer.isHidden = true // no source yet: the shape's black fill shows
                continue
            }
            layer.isHidden = false
            layer.frame = rect // canvas sublayers are in global points
            layer.contents = image
            var t = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
            mask.path = PathGeometry.path(for: a).copy(using: &t)
            mask.frame = CGRect(origin: .zero, size: rect.size)
            layer.mask = mask
        }
        for id in imageLayers.keys where !seen.contains(id) {
            imageLayers[id]?.removeFromSuperlayer()
            imageLayers[id] = nil
        }
        staticSources = staticSources.filter { usedWindowSets.contains($0.windows) }
        CATransaction.commit()
    }

    /// the view is closing: drop the sampled layers — ScreenSamples' stream
    /// stops through MarkupController.syncPanels
    func stop() {
        for l in imageLayers.values { l.removeFromSuperlayer() }
        imageLayers = [:]
    }
}
