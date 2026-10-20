import CoreGraphics
import CoreImage
import Foundation

/// What each Magnify sees on a live screen panel: the sampled screen pixels
/// with every visible Annotation stacked beneath it drawn over them, back to
/// front. The panels are excluded from screen sampling, so without this a
/// Magnify would show the bare screen. Flatten and the Editor get the same
/// picture from `CanvasDocument.beneathSource`.
///
/// One instance per sync: it remembers each Magnify's render, so a Magnify
/// beneath several others renders once, not once per path through the stack.
public final class MagnifyUnderlay {
    private let annotations: [Annotation]
    private let base: (CGRect) -> [MagnifyRenderer.Source]
    private let scale: CGFloat
    private let images: [UUID: CGImage]
    private let canvasPixels: [NestedCanvas: CanvasPixels]
    private var boxes: [Int: CGRect] = [:]
    private var rendered: [Int: CensorSource?] = [:]

    /// - annotations: the panel's stack, back to front
    /// - base: the clean screen pixels covering a global rect (global points,
    ///   bottom-left origin) — asked per rect, so a lower Magnify sampling
    ///   another display still finds its pixels
    /// - scale: the least output pixels per point; denser sources win
    public init(annotations: [Annotation], base: @escaping (CGRect) -> [MagnifyRenderer.Source],
                scale: CGFloat, images: [UUID: CGImage] = [:],
                canvasPixels: [NestedCanvas: CanvasPixels] = [:]) {
        self.annotations = annotations
        self.base = base
        self.scale = scale
        self.images = images
        self.canvasPixels = canvasPixels
    }

    /// what the Magnify at `index` samples: its viewport with the visible
    /// Annotations below it drawn over the base, snapped outward to the pixel
    /// grid — at least `scale` pixels per point, and the base's own density
    /// where higher, so magnifying never starts from a downsampled source. A
    /// Blur or Pixelate below samples the base over its whole box, as it does
    /// on screen; an earlier Magnify shows its own render. nil when nothing
    /// below paints on the viewport, or `index` isn't a Magnify — callers then
    /// sample the base directly.
    public func source(forMagnifyAt index: Int) -> CensorSource? {
        if let done = rendered[index] { return done }
        let result = render(index)
        rendered[index] = .some(result)
        return result
    }

    private func box(_ i: Int) -> CGRect {
        if let b = boxes[i] { return b }
        let b = PathGeometry.coverage(for: annotations[i]).boundingBoxOfPath
        boxes[i] = b
        return b
    }

    private func render(_ index: Int) -> CensorSource? {
        guard annotations.indices.contains(index),
              case let .magnify(m) = annotations[index].kind else { return nil }
        let rect = m.viewport
        guard rect.width > 0, rect.height > 0, scale.isFinite, scale > 0 else { return nil }
        let below = (0..<index).filter { !annotations[$0].hidden }
        guard below.contains(where: { box($0).intersects(rect) }) else { return nil }
        let sources = base(rect)
        let density = sources.filter { $0.rect.intersects(rect) }
            .map { $0.image.extent.width / $0.rect.width }
            .reduce(scale) { $1.isFinite ? max($0, $1) : $0 }
        let snapped = CGRect(x: floor(rect.minX * density) / density,
                             y: floor(rect.minY * density) / density,
                             width: ceil(rect.maxX * density) / density - floor(rect.minX * density) / density,
                             height: ceil(rect.maxY * density) / density - floor(rect.minY * density) / density)
        let w = Int(ceil(snapped.width * density)), h = Int(ceil(snapped.height * density))
        guard w >= 1, h >= 1, w * h <= 64_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.scaleBy(x: density, y: density)
        ctx.translateBy(x: -snapped.minX, y: -snapped.minY)
        for p in Self.crops(of: sources, over: snapped) { ctx.draw(p.image, in: p.frame) }
        for i in below where box(i).intersects(snapped) {
            let a = annotations[i]
            var sampled: [CensorSource] = []
            if let r = a.sampledRect {
                if case .magnify = a.kind, let own = source(forMagnifyAt: i) {
                    sampled = [own]
                } else {
                    // a Censor filters its whole box, so its blur edges and
                    // pixel grid match the Censor drawn on screen
                    sampled = Self.crops(of: base(r), over: r)
                }
            }
            ctx.draw(a, sources: sampled, images: images, canvasPixels: canvasPixels, scale: density)
        }
        guard let image = ctx.makeImage() else { return nil }
        return CensorSource(image: image, frame: CGRect(
            origin: snapped.origin,
            size: CGSize(width: CGFloat(w) / density, height: CGFloat(h) / density)))
    }

    /// each base source's pixels under `rect`, snapped outward to its own
    /// pixel grid, as CensorSources the CGContext drawing reads
    static func crops(of base: [MagnifyRenderer.Source], over rect: CGRect) -> [CensorSource] {
        base.compactMap { image, frame in
            let area = rect.intersection(frame)
            guard !area.isNull, !area.isEmpty else { return nil }
            let s = image.extent.width / frame.width
            guard s.isFinite, s > 0 else { return nil }
            let px = CGRect(x: image.extent.minX + (area.minX - frame.minX) * s,
                            y: image.extent.minY + (area.minY - frame.minY) * s,
                            width: area.width * s, height: area.height * s)
                .integral.intersection(image.extent)
            guard !px.isNull, !px.isEmpty,
                  let cg = CensorFilter.context.createCGImage(image, from: px) else { return nil }
            return CensorSource(image: cg, frame: CGRect(
                x: frame.minX + (px.minX - image.extent.minX) / s,
                y: frame.minY + (px.minY - image.extent.minY) / s,
                width: px.width / s, height: px.height / s))
        }
    }
}
