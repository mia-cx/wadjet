import CoreGraphics
import CoreImage
import Foundation

/// What a Magnify sees on a live screen panel: the sampled screen pixels with
/// every visible Annotation stacked beneath it drawn over them, back to front.
/// The panels are excluded from screen sampling, so without this a Magnify
/// would show the bare screen. Flatten and the Editor get the same picture
/// from `CanvasDocument.beneathSource`.
public enum MagnifyUnderlay {
    /// `base` (global points, bottom-left origin) under the visible
    /// Annotations of `below` that paint on `rect`, rendered over `rect`
    /// snapped outward to the pixel grid — at least `scale` pixels per point,
    /// and the sources' own density where higher, so magnifying never starts
    /// from a downsampled source. A Blur or Pixelate in `below` samples
    /// `base`; an earlier Magnify sees its own shorter prefix of `below`.
    /// nil when nothing in `below` paints on `rect` — callers then sample
    /// `base` directly.
    public static func render(base: [MagnifyRenderer.Source], below: [Annotation], rect: CGRect,
                              scale: CGFloat, images: [UUID: CGImage] = [:],
                              canvasPixels: [NestedCanvas: CanvasPixels] = [:]) -> CensorSource? {
        guard rect.width > 0, rect.height > 0, scale.isFinite, scale > 0 else { return nil }
        let visible = below.filter { !$0.hidden }
        let boxes = visible.map { PathGeometry.coverage(for: $0).boundingBoxOfPath }
        guard boxes.contains(where: { $0.intersects(rect) }) else { return nil }
        let density = base.filter { $0.rect.intersects(rect) }
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
        let pixels = crops(of: base, over: snapped)
        for p in pixels { ctx.draw(p.image, in: p.frame) }
        for (i, a) in visible.enumerated() {
            guard boxes[i].intersects(snapped) else { continue }
            var sources = pixels
            if case let .magnify(m) = a.kind {
                // an earlier Magnify sees only what lies beneath it in turn
                sources = render(base: base, below: Array(visible[..<i]), rect: m.viewport,
                                 scale: scale, images: images, canvasPixels: canvasPixels)
                    .map { [$0] } ?? crops(of: base, over: m.viewport)
            }
            ctx.draw(a, sources: sources, images: images, canvasPixels: canvasPixels, scale: density)
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
