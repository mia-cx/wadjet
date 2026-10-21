import CoreGraphics
import CoreImage

/// Renders a Magnify's magnified content — the one renderer the on-screen
/// layers and the Canvas flatten share. Coordinates follow CensorFilter's
/// convention: global points, bottom-left origin.
public enum MagnifyRenderer {
    /// an image covering a global rect, its pixels at `image.extent`
    public typealias Source = (image: CIImage, rect: CGRect)

    /// extra source pixels Lanczos reads past the mapped area — its lobes
    /// reach a few pixels, and cropping back keeps them from bleeding through
    static let lanczosPad: CGFloat = 4

    /// `m.viewport` scaled into `m.frame` at `scale` output pixels per point,
    /// composited from every source it overlaps; uncovered parts stay
    /// transparent. Not masked to the shape; no glass. The result covers
    /// `m.frame` — draw it there so 1 image pixel is 1/scale pt.
    public static func content(_ m: Magnifier, sources: [Source], scale: CGFloat,
                               format: CIFormat = .RGBA8,
                               colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage? {
        let zoom = m.effectiveZoom
        guard zoom.isFinite, zoom > 0, scale.isFinite, scale > 0,
              m.frame.width > 0, m.frame.height > 0 else { return nil }
        let out = CGRect(x: 0, y: 0, width: ceil(m.frame.width * scale),
                         height: ceil(m.frame.height * scale))
        guard out.width >= 1, out.height >= 1 else { return nil }
        let v = m.viewport
        var composite = CIImage.empty()
        for (image, rect) in sources {
            let area = v.intersection(rect)
            guard !area.isNull, !area.isEmpty else { continue }
            let s = image.extent.width / rect.width // source pixels per point
            guard s.isFinite, s > 0 else { continue }
            // the source pixels under this source's share of the viewport,
            // snapped outward like CensorFilter, then mapped into output px:
            // source px q -> q·k + (rect.origin − viewport.origin)·zoom·scale
            let px = CGRect(x: (area.minX - rect.minX) * s, y: (area.minY - rect.minY) * s,
                            width: area.width * s, height: area.height * s)
            let crop = px.integral.intersection(image.extent)
            guard !crop.isNull, !crop.isEmpty else { continue }
            let k = zoom * scale / s
            let o = CGPoint(x: (rect.minX - v.minX) * zoom * scale,
                            y: (rect.minY - v.minY) * zoom * scale)
            let piece: CIImage
            switch m.options.scaling {
            case .nearestNeighbour:
                piece = image.cropped(to: crop).samplingNearest()
                    .transformed(by: CGAffineTransform(translationX: o.x, y: o.y).scaledBy(x: k, y: k))
            case .lanczos:
                let pad = crop.insetBy(dx: -lanczosPad, dy: -lanczosPad).intersection(image.extent)
                piece = image.cropped(to: pad).clampedToExtent()
                    .applyingFilter("CILanczosScaleTransform", parameters: [
                        kCIInputScaleKey: k,
                        "inputAspectRatio": 1,
                    ])
                    .transformed(by: CGAffineTransform(translationX: o.x, y: o.y))
                    // back to this source's mapped area, so the clamped edge
                    // never bleeds past it
                    .cropped(to: CGRect(x: crop.minX * k + o.x, y: crop.minY * k + o.y,
                                        width: crop.width * k, height: crop.height * k))
            }
            composite = piece.composited(over: composite)
        }
        return CensorFilter.context.createCGImage(composite.cropped(to: out), from: out,
                                                  format: format, colorSpace: colorSpace)
    }

    /// The flattened stand-in for Liquid Glass over `content` (m.frame's
    /// pixels at `scale`): a CPU pass that refracts an edge band inward like
    /// barGlass in Lens.metal, with a little dispersion, an inner glow, and a
    /// top-lit rim hairline. Everything but the band is copied unchanged.
    public static func glass(_ content: CGImage, shape: MagnifierShape, scale: CGFloat) -> CGImage? {
        let bandMax: CGFloat = 14   // edge band, capped at…
        let bandRatio: CGFloat = 0.15 // …this share of the shorter side
        let pullMax: CGFloat = 6    // deepest refraction at the edge, in points
        let dispersion: CGFloat = 0.14 // r/b pull split at the edge
        let innerGlow: CGFloat = 0.07
        let rimBase: CGFloat = 0.07, rimLit: CGFloat = 0.14 // hairline dark → top-lit
        let rimWidth: CGFloat = 1.3
        let w = content.width, h = content.height
        guard w > 0, h > 0, scale > 0,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32,
                bytesPerRow: w * 16, space: space,
                bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(content, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.assumingMemoryBound(to: Float.self)
        // refraction reads the pre-pass pixels: sample from a frozen copy so a
        // brightened neighbour never feeds the next pixel
        let src = Array(UnsafeBufferPointer(start: px, count: w * h * 4))
        let a = CGFloat(w) / (2 * scale), b = CGFloat(h) / (2 * scale) // half-sizes, points
        let band = min(bandMax, bandRatio * min(a, b) * 2)
        let n = shape.exponent
        func bilinear(_ fx: CGFloat, _ fy: CGFloat) -> (Float, Float, Float, Float) {
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            let tx = Float(fx - CGFloat(x0)), ty = Float(fy - CGFloat(y0))
            func p(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
                let i = 4 * (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1))
                return (src[i], src[i + 1], src[i + 2], src[i + 3])
            }
            let p00 = p(x0, y0), p10 = p(x0 + 1, y0), p01 = p(x0, y0 + 1), p11 = p(x0 + 1, y0 + 1)
            func l(_ key: KeyPath<(Float, Float, Float, Float), Float>) -> Float {
                (p00[keyPath: key] * (1 - tx) + p10[keyPath: key] * tx) * (1 - ty)
                    + (p01[keyPath: key] * (1 - tx) + p11[keyPath: key] * tx) * ty
            }
            return (l(\.0), l(\.1), l(\.2), l(\.3))
        }
        func smoothstep(_ lo: CGFloat, _ hi: CGFloat, _ x: CGFloat) -> CGFloat {
            let t = min(max((x - lo) / (hi - lo), 0), 1)
            return t * t * (3 - 2 * t)
        }
        for y in 0..<h { for x in 0..<w {
            // p = offset from the frame centre in points, y up (row 0 is top)
            let ptx = (CGFloat(x) + 0.5) / scale - a
            let pty = b - (CGFloat(y) + 0.5) / scale
            let r = hypot(ptx, pty)
            guard r > 1e-4 else { continue }
            let f: CGFloat = n.isInfinite
                ? max(abs(ptx) / a, abs(pty) / b)
                : pow(pow(abs(ptx) / a, n) + pow(abs(pty) / b, n), 1 / n)
            let depth = r * (1 / f - 1) // ≈ distance inward to the edge, in points
            guard f <= 1, depth < band else { continue }
            let u = min(max(1 - depth / band, 0), 1) // 0 at the band's deep edge, 1 at the edge
            let dirX = ptx / r, dirY = pty / r
            let pull = u * u * pullMax
            // refraction pulls in from further inside, like barGlass — sample
            // position q back in pixel coordinates
            func sample(_ pull: CGFloat) -> (Float, Float, Float, Float) {
                bilinear((ptx - dirX * pull + a) * scale - 0.5,
                         (b - (pty - dirY * pull)) * scale - 0.5)
            }
            let g = sample(pull)
            let rc = sample(pull * (1 - dispersion * u)).0
            let bc = sample(pull * (1 + dispersion * u)).2
            let i = 4 * (y * w + x)
            let facing = min(max(dirY * 0.5 + 0.5, 0), 1) // lit from above
            // additions are premultiplied — scaled by the sampled alpha
            let add = Float(innerGlow * u * u
                + (1 - smoothstep(0, rimWidth, depth)) * (rimBase + rimLit * facing)) * g.3
            px[i] = rc + add
            px[i + 1] = g.1 + add
            px[i + 2] = bc + add
            px[i + 3] = g.3
        } }
        return ctx.makeImage()
    }
}
