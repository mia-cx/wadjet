import CoreGraphics
import Foundation
import ImageIO
import Testing
import WadjetKit

struct WindowScreenshotTests {
    // Proves transparent and translucent standalone window pixels never acquire desktop colours, including after reopening.
    @Test func isolatedWindowPreservesAlphaAndRecroppableDisplays() throws {
        let frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        let displayFrame = CGRect(x: -2, y: -2, width: 16, height: 16)
        let display = try fixtureImage(space: CGColorSpace.sRGB) { _, _ in [0, 0, 1, 1] }
        let window = try fixtureImage(space: CGColorSpace.sRGB) { x, _ in
            x < 4 ? [0, 0, 0, 0] : x < 8 ? [0.5, 0, 0, 0.5] : [1, 0, 0, 1]
        }
        var canvas = CanvasDocument(layout: [.init(id: 1, frame: displayFrame, scaleFactor: 1)], crop: frame,
            displayImages: [1: display])
        canvas.setCapturedWindow(window)
        let fixture = [[Float(0), 0, 0, 0], [Float(0.5), 0, 0, 0.5], [Float(1), 0, 0, 1]]
        for document in [canvas, try CanvasDocument(fileWrapper: canvas.fileWrapper())] {
            let values = try rgba(document.flatten(), space: CGColorSpace.sRGB)
            for (x, expected) in zip([2, 6, 10], fixture) {
                let offset = 4 * (6 * 12 + x)
                for channel in 0..<4 { #expect(abs(values[offset + channel] - expected[channel]) < 0.03) }
            }
            let expanded = try rgba(document.flatten(crop: displayFrame), space: CGColorSpace.sRGB)
            #expect(abs(expanded[0]) < 0.03 && abs(expanded[1]) < 0.03)
            #expect(expanded[2] > 0.97 && expanded[3] == 1)
        }
        #expect(canvas.displayImages[1] === display)
    }

    // Proves an unmeasured square window can retain corner pixels without any inferred crop rounding.
    @Test func unmeasuredWindowKeepsSquareCorners() throws {
        let frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        let image = try fixtureImage(space: CGColorSpace.sRGB) { _, _ in [1, 1, 1, 1] }
        var canvas = CanvasDocument(layout: [], crop: frame, cornerRadius: 16, displayImages: [:])
        canvas.setCapturedWindow(image) // the immediate path supplies no measured radius
        #expect(try rgba(canvas.flatten(), space: CGColorSpace.sRGB)[3] == 1)
    }

    // Proves PNG exports preserve a saturated SDR Display P3 colour's colourimetric value rather than clipping it to sRGB.
    @Test func pngPreservesWideGamutSDR() throws {
        let image = try fixtureImage(space: CGColorSpace.displayP3) { _, _ in [1, 0, 0, 1] }
        let frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        let canvas = CanvasDocument(layout: [.init(id: 1, frame: frame, scaleFactor: 1)], crop: frame, displayImages: [1: image])
        let png = try CanvasImageCodec.png(canvas.flatten())
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let restored = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let before = try rgba(image, space: CGColorSpace.extendedLinearSRGB)
        let after = try rgba(restored, space: CGColorSpace.extendedLinearSRGB)
        #expect(before[0] > 1.2 && before[1] < 0) // this fixture is outside sRGB
        for channel in 0..<4 { #expect(abs(before[channel] - after[channel]) < 0.01) }
    }
}

private func fixtureImage(space: CFString, pixel: (Int, Int) -> [Float]) throws -> CGImage {
    let values: [Float] = (0..<12).flatMap { y in (0..<12).flatMap { x in pixel(x, y) } }
    let data = values.withUnsafeBytes { Data($0) }
    return try #require(CGImage(width: 12, height: 12, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: 12 * 16,
        space: CGColorSpace(name: space)!,
        bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func rgba(_ image: CGImage, space: CFString) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 32,
        bytesPerRow: image.width * 16, space: CGColorSpace(name: space)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setEDRTargetHeadroom(0)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: Float.self),
        count: image.width * image.height * 4))
}
