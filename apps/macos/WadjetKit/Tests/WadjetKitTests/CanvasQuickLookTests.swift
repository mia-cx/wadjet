import CoreGraphics
import Foundation
import ImageIO
import Testing
import WadjetKit

struct CanvasQuickLookTests {
    // Proves Finder uses the cached thumbnail without decoding the Canvas and fits both request axes at Retina scale.
    @Test func thumbnailUsesSavedImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wadjet")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try #require(Bundle.module.url(forResource: "composition", withExtension: "png", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: url.appendingPathComponent("thumbnail.png"))
        // No canvas.json or HEICs: thumbnail generation must not open the full package.
        for (maximum, expected) in [(CGSize(width: 3, height: 20), CGSize(width: 3, height: 2)),
                                    (CGSize(width: 20, height: 2), CGSize(width: 3, height: 2))] {
            let image = try CanvasQuickLook.thumbnail(at: url, maximumSize: maximum, scale: 2)
            #expect(CanvasQuickLook.thumbnailSize(for: image, maximumSize: maximum) == expected)
        }
        let small = try CanvasQuickLook.thumbnail(at: url, maximumSize: CGSize(width: 3, height: 2), scale: 2)
        #expect(small.width == 6 && small.height == 4)
    }

    // Proves a missing/corrupt thumbnail fails explicitly rather than returning an unrelated image.
    @Test func thumbnailErrors() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wadjet")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) {
            try CanvasQuickLook.thumbnail(at: url, maximumSize: CGSize(width: 64, height: 64), scale: 1)
        }
        try Data("broken PNG".utf8).write(to: url.appendingPathComponent("thumbnail.png"))
        #expect(throws: CanvasDocumentError.imageDecodingFailed) {
            try CanvasQuickLook.thumbnail(at: url, maximumSize: CGSize(width: 64, height: 64), scale: 1)
        }
    }

    // Proves previews retain the fixture's crop, aspect ratio, Annotation pixels and P3 colour profile,
    // preserving Retina resolution for small Canvases while bounding large crops before rendering.
    @Test func previewRendersBoundedCrop() throws {
        for (crop, expected) in [(CGRect(x: 10, y: 20, width: 6, height: 4), CGSize(width: 12, height: 8)),
                                 (CGRect(x: 10, y: 20, width: 8192, height: 4), CGSize(width: 4096, height: 2)),
                                 (CGRect(x: 10, y: 20, width: 4, height: 8192), CGSize(width: 2, height: 4096))] {
            let canvas = CanvasDocument(layout: [.init(id: 1, frame: crop, scaleFactor: 2)], crop: crop,
                layerStack: LayerStack([Annotation(kind: .censor(rect: crop, method: .blackOut),
                    style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1))]),
                displayImages: [1: try fixtureImage()])
            let data = try CanvasQuickLook.previewPNG(for: canvas)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(CGSize(width: image.width, height: image.height) == expected)
            #expect(image.colorSpace?.name == CGColorSpace.displayP3)
            let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            #expect(Array(UnsafeBufferPointer(start: pixels, count: 4)) == [0, 0, 0, 255])
        }
    }

    // Proves invalid crops are rejected before the preview allocates a bitmap.
    @Test func previewRejectsInvalidCrop() {
        let canvas = CanvasDocument(layout: [], crop: .zero, displayImages: [:])
        #expect(throws: CanvasDocumentError.invalidGeometry) { try CanvasQuickLook.previewPNG(for: canvas) }
    }

    private func fixtureImage() throws -> CGImage {
        let url = try #require(Bundle.module.url(forResource: "composition", withExtension: "png", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
