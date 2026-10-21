import CoreGraphics
import Foundation
import ImageIO
import Testing
import WadjetKit

private func solid(_ w: Int, _ h: Int) throws -> CGImage {
    let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return try #require(ctx.makeImage())
}

struct AnnotationClipTests {
    static let red = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    // Proves a copy survives the system pasteboard: the private package
    // brings back every Annotation with its image asset and window pixels,
    // so another launch or another Canvas can paste it.
    @Test func roundTrip() throws {
        let asset = UUID(), layer = UUID()
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 40, y: 20)), style: Self.red)
        let picture = Annotation(kind: .image(asset: asset, ImagePlacement(
            frame: CGRect(x: 50, y: 0, width: 4, height: 4), crop: CGRect(x: 0, y: 0, width: 4, height: 4),
            border: .hidden)), style: Self.red)
        let window = Annotation(kind: .window(layerID: layer, frame: CGRect(x: 0, y: 30, width: 6, height: 6)),
                                style: Self.red)
        let clip = AnnotationClip(annotations: [line, picture, window], images: [asset: try solid(4, 4)],
                                  windowImages: [layer: try solid(6, 6)])
        let back = try AnnotationClip(package: try clip.pasteboardData(scale: 1).package)
        #expect(back.annotations == [line, picture, window])
        #expect(back.images[asset]?.width == 4)
        #expect(back.windowImages[layer]?.width == 6)
        #expect(back.snapshots.isEmpty)
    }

    // Proves other apps get an image of the Annotations alone: a PNG of
    // their painted area at the requested scale, round caps included.
    @Test func flattenedImage() throws {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 40, y: 20)), style: Self.red)
        let clip = AnnotationClip(annotations: [line])
        let b = clip.paintedBounds
        #expect(b.contains(CGRect(x: -2, y: -2, width: 44, height: 24)) && b.width <= 48 && b.height <= 28)
        let image = try Self.png(clip)
        #expect(image.width == Int(b.width * 2) && image.height == Int(b.height * 2))
    }

    // Proves nothing painted is cut off at the image's edge: a short Line's
    // filled arrowhead, which reaches well behind its tip, and a Magnify's
    // source outline far from its lens leave the border pixels clear.
    @Test(arguments: [
        Annotation(kind: .line(start: .zero, end: CGPoint(x: 1, y: 0)),
                   style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4,
                                          head: .filledArrow, tail: .filledArrow)),
        Annotation(kind: .magnify(Magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                            frame: CGRect(x: 100, y: 0, width: 40, height: 40),
                                            options: MagnifierOptions())), style: red),
    ])
    func nothingClipped(_ a: Annotation) throws {
        let clip = AnnotationClip(annotations: [a])
        if case let .magnify(m) = a.kind { #expect(clip.paintedBounds.contains(m.source)) }
        let image = try Self.png(clip, scale: 1)
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let alpha = { (x: Int, y: Int) in px[(y * w + x) * 4 + 3] }
        let edge = (0..<w).flatMap { [alpha($0, 0), alpha($0, h - 1)] }
            + (0..<h).flatMap { [alpha(0, $0), alpha(w - 1, $0)] }
        #expect(edge.allSatisfy { $0 == 0 })
        #expect(px.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
    }

    static func png(_ clip: AnnotationClip, scale: CGFloat = 2) throws -> CGImage {
        let png = try clip.pasteboardData(scale: scale).png
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    // Proves a Window Annotation whose pixels didn't come along is left out
    // rather than breaking the package.
    @Test func windowWithoutPixels() throws {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 10)), style: Self.red)
        let window = Annotation(kind: .window(layerID: UUID(), frame: CGRect(x: 0, y: 0, width: 6, height: 6)),
                                style: Self.red)
        let back = try AnnotationClip(package: try AnnotationClip(annotations: [line, window])
            .pasteboardData(scale: 1).package)
        #expect(back.annotations == [line])
    }

    // Proves Annotations that sample the screen still copy: with nothing
    // beneath them in the clip, Blur and Magnify flatten without failing.
    @Test func samplersFlatten() throws {
        let blur = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 20, height: 20), method: .defaultBlur),
                              style: Self.red)
        let black = Annotation(kind: .censor(rect: CGRect(x: 30, y: 0, width: 20, height: 20), method: .blackOut),
                               style: Self.red)
        let lens = Annotation(kind: .magnify(Magnifier(source: CGRect(x: 0, y: 30, width: 10, height: 10),
                                                       frame: CGRect(x: 20, y: 30, width: 20, height: 20),
                                                       options: MagnifierOptions())), style: Self.red)
        let data = try AnnotationClip(annotations: [blur, black, lens]).pasteboardData(scale: 1)
        #expect(try AnnotationClip(package: data.package).annotations.count == 3)
    }
}
