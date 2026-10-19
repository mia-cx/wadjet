import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WadjetKit

struct ImageCanvasTests {
    // Proves an opened image sits at its natural point size, upright, cropped to
    // the whole image.
    @Test(arguments: [
        (dpi: 72.0, orientation: 1,
         frame: CGRect(x: 0, y: 0, width: 200, height: 100),
         scale: 1.0, pixels: CGSize(width: 200, height: 100)),
        (dpi: 144.0, orientation: 1,
         frame: CGRect(x: 0, y: 0, width: 100, height: 50),
         scale: 2.0, pixels: CGSize(width: 200, height: 100)),
        (dpi: nil, orientation: 1,
         frame: CGRect(x: 0, y: 0, width: 200, height: 100),
         scale: 1.0, pixels: CGSize(width: 200, height: 100)),
        (dpi: 144.0, orientation: 6,
         frame: CGRect(x: 0, y: 0, width: 50, height: 100),
         scale: 2.0, pixels: CGSize(width: 100, height: 200)),
    ] as [(dpi: Double?, orientation: UInt32, frame: CGRect, scale: CGFloat, pixels: CGSize)])
    func openedImageSitsAtNaturalPointSize(dpi: Double?, orientation: UInt32, frame: CGRect,
                                           scale: CGFloat, pixels: CGSize) throws {
        let canvas = try CanvasDocument(image: tiff(dpi: dpi, orientation: orientation))
        #expect(canvas.layout.count == 1)
        #expect(canvas.layout[0].frame == frame)
        #expect(canvas.layout[0].scaleFactor == scale)
        #expect(canvas.crop == frame)
        let image = try #require(canvas.displayImages[1])
        #expect(CGSize(width: image.width, height: image.height) == pixels)
    }

    @Test func unreadableDataFails() {
        #expect(throws: CanvasDocumentError.imageDecodingFailed) {
            try CanvasDocument(image: Data("not an image".utf8))
        }
    }
}

/// a 200×100 TIFF with the given metadata
private func tiff(dpi: Double?, orientation: UInt32) throws -> Data {
    let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, UTType.tiff.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
    if let dpi {
        properties[kCGImagePropertyDPIWidth] = dpi
        properties[kCGImagePropertyDPIHeight] = dpi
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}
