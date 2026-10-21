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

    // Proves other apps get an image of the Annotations alone: a PNG the
    // size of their painted area, room left for the stroke.
    @Test func flattenedImage() throws {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 40, y: 20)), style: Self.red)
        let clip = AnnotationClip(annotations: [line])
        #expect(clip.paintedBounds == CGRect(x: -14, y: -14, width: 68, height: 48))
        let png = try clip.pasteboardData(scale: 2).png
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(image.width == 136 && image.height == 96)
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
}
