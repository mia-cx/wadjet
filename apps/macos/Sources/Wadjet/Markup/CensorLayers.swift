import AppKit
import CoreImage
import QuartzCore
import WadjetKit

/// Shows Blur and Pixelate on one Markup panel: one image layer per sampling
/// Censor, masked to its path, above its black shape layer (which stays as the
/// Black out fallback until a sample lands). On a Freeze Frame it samples the
/// frame's cursor-free image; on the live screen, its display's LiveSampler.
@MainActor final class CensorLayers {
    private let screen: NSScreen
    private let sampler: LiveSampler
    private var latest: LiveSample?
    private var annotations: [Annotation] = []
    private var shapes: [Annotation.ID: CAShapeLayer] = [:]
    private var imageLayers: [Annotation.ID: CALayer] = [:]

    init(screen: NSScreen) {
        self.screen = screen
        sampler = LiveSampler(screen: screen) { _ in }
        sampler.onSample = { [weak self] s in self?.sampled(s) }
        sampler.onLost = { [weak self] in self?.invalidate() }
    }

    /// the panel's annotations each render; `layers` is MarkupView's shape
    /// layer map so each sample lands on its own Censor's layer
    func sync(_ annotations: [Annotation], layers: [Annotation.ID: CAShapeLayer]) {
        self.annotations = annotations
        shapes = layers
        let sampling = annotations.filter { a in
            guard case let .censor(_, m) = a.kind, m.samplesBeneath else { return false }
            return PathGeometry.path(for: a).boundingBox.intersects(screen.frame)
        }
        var source: CIImage?
        var sourceRect = CGRect.zero
        // .frozen isn't proof the picture is up: with Settings' Freeze off the
        // panels hide it, so the desktop underneath is live — sample it then
        if AppState.shared.phase == .frozen,
           AppDelegate.shared?.overlayCtrl.showsFrozen == true,
           let fd = Freeze.shared.displays.first(where: { Self.sameDisplay($0.screen, screen) }) {
            source = CIImage(cgImage: fd.clean)
            sourceRect = screen.frame
            sampler.watch(nil)
            latest = nil // a pre-Freeze frame is stale the moment sampling resumes
        } else {
            let union = LiveSampling.union(
                of: sampling.map { PathGeometry.path(for: $0).boundingBox }, on: screen.frame)
            sampler.watch(union)
            if union == nil { latest = nil }
            if let latest {
                source = latest.image
                sourceRect = latest.rect
            }
        }
        // standalone layers outside the panel's own transaction need implicit
        // animations off, or every new sample would smear in
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<Annotation.ID>()
        for a in sampling {
            seen.insert(a.id)
            guard case let .censor(_, method) = a.kind, let shape = shapes[a.id] else { continue }
            let box = PathGeometry.path(for: a).boundingBox.intersection(screen.frame)
            let layer = imageLayers[a.id] ?? CALayer()
            imageLayers[a.id] = layer
            if layer.superlayer !== shape { shape.addSublayer(layer) }
            layer.contentsScale = screen.backingScaleFactor
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
        CATransaction.commit()
    }

    /// the stream died: drop the stale frame and fall back
    /// to the shape layers' black fill at once. No watch here — a stopped
    /// stream stays stopped until the next Markup render retries it
    private func invalidate() {
        latest = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in imageLayers.values { layer.isHidden = true }
        CATransaction.commit()
    }

    /// a new live frame: re-render the stored annotations on it, then log latency
    private func sampled(_ sample: LiveSample) {
        latest = sample
        sync(annotations, layers: shapes)
        sampler.presented(sample)
    }

    /// the panel is closing: stop the stream and forget the frame
    func stop() {
        sampler.watch(nil)
        latest = nil
    }

    private static func sameDisplay(_ a: NSScreen, _ b: NSScreen) -> Bool {
        func id(_ s: NSScreen) -> CGDirectDisplayID? {
            s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        return id(a) == id(b)
    }
}
