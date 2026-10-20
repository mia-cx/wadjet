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

    // Proves the live underlay draws the visible Annotations below over the
    // screen pixels, and declines when none paints on the viewport.
    @Test func underlayDrawsAnnotationsOverBase() throws {
        let base: [MagnifyRenderer.Source] = [(CIImage(cgImage: try solid(0, 0, 255, width: 32, height: 16)),
                                              CGRect(x: 0, y: 0, width: 32, height: 16))]
        let rect = CGRect(x: 0, y: 0, width: 8, height: 4)
        let u = try #require(MagnifyUnderlay.render(base: base, below: [Self.under], rect: rect, scale: 1))
        #expect(u.frame == rect)
        let px = try rgba(u.image)
        #expect(px.at(1, 2) == [255, 0, 0, 255], "the shape: got \(px.at(1, 2))")
        #expect(px.at(6, 2) == [0, 0, 255, 255], "the screen: got \(px.at(6, 2))")
        #expect(MagnifyUnderlay.render(base: base, below: [], rect: rect, scale: 1) == nil)
        #expect(MagnifyUnderlay.render(base: base, below: [Self.block(rect, hidden: true)],
                                       rect: rect, scale: 1) == nil)
        #expect(MagnifyUnderlay.render(base: base, below: [Self.block(CGRect(x: 20, y: 8, width: 2, height: 2))],
                                       rect: rect, scale: 1) == nil)
    }

    // Proves the live underlay resolves an earlier Magnify against its own
    // shorter prefix: its magnifier shows the shape beneath it.
    @Test func underlayMagnifiesAnEarlierMagnify() throws {
        let base: [MagnifyRenderer.Source] = [(CIImage(cgImage: try solid(0, 0, 255, width: 32, height: 16)),
                                              CGRect(x: 0, y: 0, width: 32, height: 16))]
        let tiny = Self.block(CGRect(x: 0, y: 0, width: 2, height: 2))
        let first = Self.magnify(source: CGRect(x: 0, y: 0, width: 2, height: 2),
                                 frame: CGRect(x: 4, y: 0, width: 4, height: 4), zoom: 2)
        let u = try #require(MagnifyUnderlay.render(base: base, below: [tiny, first],
                                                    rect: CGRect(x: 4, y: 0, width: 4, height: 4), scale: 1))
        let px = try rgba(u.image)
        #expect(px.at(2, 2) == [255, 0, 0, 255], "got \(px.at(2, 2))")
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

