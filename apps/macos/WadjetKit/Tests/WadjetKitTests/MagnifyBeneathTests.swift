import CoreGraphics
import CoreImage
import Foundation
import Testing
import WadjetKit

/// A Magnify shows what lies beneath it in layer order: the pixels plus every
/// visible Annotation below it, never itself or anything above it.
struct MagnifyBeneathTests {
    static let red = RGBAColour(red: 1, green: 0, blue: 0, alpha: 1)
    static let magenta = RGBAColour(red: 1, green: 0, blue: 1, alpha: 1)

    /// a filled, unstroked rect
    static func block(_ rect: CGRect, hidden: Bool = false) -> Annotation {
        var a = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: rect),
                           style: .init(colour: red, width: 1, fill: red, stroked: false))
        a.hidden = hidden
        return a
    }
    /// a flat rectangle Magnify: no glass, leader, or border
    static func magnify(source: CGRect, frame: CGRect, zoom: CGFloat) -> Annotation {
        Annotation(kind: .magnify(Magnifier(source: source, frame: frame, zoom: zoom,
                                            options: .init(shape: .rectangle, leader: false, glass: false))),
                   style: .init(colour: magenta, width: 1))
    }
    /// a blue 32×16 pt display at 1×, with `layers` stacked back to front
    static func document(_ layers: [Annotation]) throws -> CanvasDocument {
        CanvasDocument(layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 32, height: 16), scaleFactor: 1)],
                       crop: CGRect(x: 0, y: 0, width: 32, height: 16),
                       layerStack: LayerStack(layers),
                       displayImages: [1: try solid(0, 0, 255, width: 32, height: 16)])
    }

    // the magnifier sits at (16,0)-(32,16), magnifying (0,0)-(4,4) by 4
    static let lens = magnify(source: CGRect(x: 0, y: 0, width: 4, height: 4),
                              frame: CGRect(x: 16, y: 0, width: 16, height: 16), zoom: 4)
    static let under = block(CGRect(x: 0, y: 0, width: 4, height: 4))

    // Proves flatten's Magnify magnifies a shape stacked beneath it.
    @Test func flattenMagnifiesAnnotationsBelow() throws {
        let px = try rgba(try Self.document([Self.under, Self.lens]).flatten())
        #expect(px.at(24, 8) == [255, 0, 0, 255], "got \(px.at(24, 8))")
    }

    // Proves flatten's Magnify never shows a layer above it, nor a hidden one
    // below it: the magnifier keeps the display's blue.
    @Test func flattenSkipsAnnotationsAboveAndHidden() throws {
        for layers in [[Self.lens, Self.under],
                       [Self.block(CGRect(x: 0, y: 0, width: 4, height: 4), hidden: true), Self.lens]] {
            let px = try rgba(try Self.document(layers).flatten())
            #expect(px.at(24, 8) == [0, 0, 255, 255], "got \(px.at(24, 8))")
        }
    }

    // Proves a Magnify over an earlier Magnify's magnifier shows that
    // magnifier's content, which in turn shows the shape beneath it.
    @Test func flattenMagnifiesAnEarlierMagnify() throws {
        let tiny = Self.block(CGRect(x: 0, y: 0, width: 2, height: 2))
        let first = Self.magnify(source: CGRect(x: 0, y: 0, width: 2, height: 2),
                                 frame: CGRect(x: 4, y: 0, width: 4, height: 4), zoom: 2)
        let second = Self.magnify(source: CGRect(x: 5, y: 1, width: 2, height: 2),
                                  frame: CGRect(x: 16, y: 0, width: 16, height: 16), zoom: 8)
        let px = try rgba(try Self.document([tiny, first, second]).flatten())
        #expect(px.at(24, 8) == [255, 0, 0, 255], "got \(px.at(24, 8))")
    }

    static func blueBase() throws -> [MagnifyRenderer.Source] {
        [(CIImage(cgImage: try solid(0, 0, 255, width: 32, height: 16)), CGRect(x: 0, y: 0, width: 32, height: 16))]
    }

    // Proves a flatten with many Magnifies stacked over one source still
    // shows the shape beneath them all — each lower lens resolves once per
    // flatten (twelve would take 2^11 nested flattens without the cache).
    @Test func flattenManyStackedMagnifies() throws {
        let lenses = (0..<12).map { _ in Self.lens }.map { l -> Annotation in
            var c = l; c.id = UUID(); return c
        }
        let start = Date()
        let px = try rgba(try Self.document([Self.under] + lenses).flatten())
        #expect(px.at(24, 8) == [255, 0, 0, 255], "got \(px.at(24, 8))")
        #expect(Date().timeIntervalSince(start) < 10)
    }

    // Proves the live underlay draws the visible Annotations below over the
    // screen pixels, and declines when none paints on the viewport.
    @Test func underlayDrawsAnnotationsOverBase() throws {
        let base = try Self.blueBase()
        // the lens's viewport is (0,0)-(4,4) at 4× of a 4×4 source
        func underlay(_ below: [Annotation]) -> CensorSource? {
            MagnifyUnderlay(annotations: below + [Self.lens], base: { _ in base }, scale: 1)
                .source(forMagnifyAt: below.count)
        }
        let half = Self.block(CGRect(x: 0, y: 0, width: 2, height: 4))
        let u = try #require(underlay([half]))
        #expect(u.frame == CGRect(x: 0, y: 0, width: 4, height: 4))
        let px = try rgba(u.image)
        #expect(px.at(1, 2) == [255, 0, 0, 255], "the shape: got \(px.at(1, 2))")
        #expect(px.at(3, 2) == [0, 0, 255, 255], "the screen: got \(px.at(3, 2))")
        #expect(underlay([]) == nil)
        #expect(underlay([Self.block(CGRect(x: 0, y: 0, width: 4, height: 4), hidden: true)]) == nil)
        #expect(underlay([Self.block(CGRect(x: 20, y: 8, width: 2, height: 2))]) == nil)
        // a layer above the lens never reaches it
        #expect(MagnifyUnderlay(annotations: [Self.lens, half], base: { _ in base }, scale: 1)
            .source(forMagnifyAt: 0) == nil)
    }

    // Proves the live underlay resolves an earlier Magnify against its own
    // shorter prefix — its magnifier shows the shape beneath it — and asks the
    // base for that Magnify's own viewport, so a lens sampling another display
    // still finds its pixels.
    @Test func underlayMagnifiesAnEarlierMagnify() throws {
        // the screen is blue except where the base is asked for the first
        // lens's own viewport — standing in for a second display
        let green: [MagnifyRenderer.Source] = [(CIImage(cgImage: try solid(0, 255, 0, width: 2, height: 2)),
                                                CGRect(x: 20, y: 10, width: 2, height: 2))]
        let blue = try Self.blueBase()
        let first = Self.magnify(source: CGRect(x: 20, y: 10, width: 2, height: 2),
                                 frame: CGRect(x: 4, y: 0, width: 4, height: 4), zoom: 2)
        let second = Self.magnify(source: CGRect(x: 5, y: 1, width: 2, height: 2),
                                  frame: CGRect(x: 16, y: 0, width: 16, height: 16), zoom: 8)
        var asked: [CGRect] = []
        let underlay = MagnifyUnderlay(annotations: [first, second], base: { r in
            asked.append(r)
            return r.intersects(CGRect(x: 20, y: 10, width: 2, height: 2)) ? green : blue
        }, scale: 1)
        let u = try #require(underlay.source(forMagnifyAt: 1))
        let px = try rgba(u.image)
        #expect(px.at(1, 1) == [0, 255, 0, 255], "got \(px.at(1, 1))")
        #expect(asked.contains(CGRect(x: 20, y: 10, width: 2, height: 2)))
    }

    // Proves stacked Magnifies over one source render each lower prefix once:
    // twelve lenses ask the base a linear number of times, not 2^n.
    @Test func underlayRendersEachMagnifyOnce() throws {
        let base = try Self.blueBase()
        let lenses = (0..<12).map { _ in
            Self.magnify(source: CGRect(x: 0, y: 0, width: 4, height: 4),
                         frame: CGRect(x: 16, y: 0, width: 16, height: 16), zoom: 4)
        }
        var calls = 0
        let underlay = MagnifyUnderlay(annotations: [Self.under] + lenses,
                                       base: { _ in calls += 1; return base }, scale: 1)
        for i in 1...12 { _ = underlay.source(forMagnifyAt: i) }
        #expect(calls <= 12 * 2, "the base was asked \(calls) times")
    }

    // Proves the live underlay filters a Pixelate beneath the lens over the
    // Censor's whole box, so the magnified blocks match the Censor itself.
    @Test func underlayKeepsACensorsPixelGrid() throws {
        // a horizontal ramp, so Pixelate's blocks differ
        var ramp: [UInt8] = []
        for _ in 0..<16 { for x in 0..<32 { ramp += [UInt8(x * 8), 0, 0, 255] } }
        let provider = try #require(CGDataProvider(data: Data(ramp) as CFData))
        let image = try #require(CGImage(width: 32, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let base: [MagnifyRenderer.Source] = [(CIImage(cgImage: image), CGRect(x: 0, y: 0, width: 32, height: 16))]
        let censor = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 32, height: 16), method: .pixelate(blockSize: 4)),
                                style: .init(colour: Self.red, width: 1))
        // a lens over an off-grid interior slice of the Censor
        let lens = Self.magnify(source: CGRect(x: 5, y: 5, width: 6, height: 6),
                                frame: CGRect(x: 0, y: 0, width: 24, height: 24), zoom: 4)
        let u = try #require(MagnifyUnderlay(annotations: [censor, lens], base: { _ in base }, scale: 1)
            .source(forMagnifyAt: 1))
        // the Censor drawn whole, then read at the same points
        let ctx = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(censor, sources: [CensorSource(image: image, frame: CGRect(x: 0, y: 0, width: 32, height: 16))])
        let whole = try rgba(try #require(ctx.makeImage()))
        let part = try rgba(u.image)
        for x in 0..<6 { for y in 0..<6 {
            #expect(part.at(x, y) == whole.at(x + 5, y + 5), "at (\(x + 5), \(y + 5))")
        } }
    }
}

/// opaque 8-bit sRGB pixels
private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, width: Int, height: Int) throws -> CGImage {
    let pixel: [UInt8] = [r, g, b, 255]
    let pixels = Array(repeating: pixel, count: width * height).flatMap { $0 }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

/// an image's pixels as 8-bit sRGB RGBA, rows top to bottom
private struct RGBA {
    let bytes: [UInt8], width: Int, height: Int
    /// the pixel at (x, y) in points-from-bottom-left, as flatten lays it out
    func at(_ x: Int, _ y: Int) -> [UInt8] {
        let i = 4 * ((height - 1 - y) * width + x)
        return Array(bytes[i..<i + 4])
    }
}

private func rgba(_ image: CGImage) throws -> RGBA {
    let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
    return RGBA(bytes: Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4)),
                width: image.width, height: image.height)
}

