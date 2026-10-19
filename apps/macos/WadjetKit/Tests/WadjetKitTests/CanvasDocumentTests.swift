import CoreGraphics
import Foundation
import ImageIO
import Testing
import WadjetKit

struct CanvasDocumentTests {
    // Proves that a saved Canvas keeps editable contents and HDR across open/save cycles.
    @Test func packageRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.wadjet")
        let hdr = try hdrFixture()
        let child = CanvasDocument(layout: [.init(id: 2, frame: CGRect(x: 0, y: 0, width: 8, height: 8), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 8, height: 8), displayImages: [2: try solidImage([0, 1, 0, 1])])
        let annotation = Annotation(kind: .line(start: CGPoint(x: -30, y: 10), end: CGPoint(x: 40, y: 10)),
            style: AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 0.5), width: 3))
        let display = CanvasDisplay(id: 17, frame: CGRect(x: -32, y: 0, width: 32, height: 32), scaleFactor: 2)
        let window = CanvasWindowLayer(frame: CGRect(x: -22, y: 4, width: 8, height: 8), zOrder: 4,
            imageFileName: "window-0.heic", image: try solidImage([0, 0, 1, 1]))
        let link = CanvasLink(url: directory.appendingPathComponent("unavailable.wadjet"), bookmarkData: Data([0, 1, 2, 255]))
        let document = CanvasDocument(layout: [display], crop: CGRect(x: -20, y: 6, width: 12, height: 10),
            cornerRadius: 2.5, layerStack: LayerStack([annotation]), displayImages: [17: hdr],
            windowLayers: [window], embeddedCanvases: ["detail.wadjet": child], linkedCanvases: [link])
        try document.write(to: url)
        let reopened = try CanvasDocument.read(from: url)
        #expect(reopened.layout == [display])
        #expect(reopened.crop == document.crop)
        #expect(reopened.cornerRadius == 2.5)
        #expect(reopened.layerStack == document.layerStack)
        #expect(reopened.windowLayers.count == 1)
        #expect(reopened.windowLayers.first?.frame == window.frame)
        #expect(reopened.windowLayers.first?.zOrder == 4)
        #expect(reopened.windowLayers.first?.imageFileName == "window-0.heic")
        #expect(reopened.embeddedCanvases["detail.wadjet"]?.layout == child.layout)
        #expect(reopened.linkedCanvases == [link])
        let restoredHDR = try #require(reopened.displayImages[17])
        #expect(restoredHDR.width == 64 && restoredHDR.height == 64)
        let before = try linearPixels(hdr), after = try linearPixels(restoredHDR)
        // ImageIO's quality-1 ISO gain-map HEIC is still lossy; allow 20% highlight error.
        #expect(abs(before[4 * (32 * 64 + 32)] - after[4 * (32 * 64 + 32)]) < 0.8)
        #expect(after[4 * (32 * 64 + 32)] > 3.2)
        let flattened = try reopened.flatten(crop: display.frame)
        #expect(try linearPixels(flattened)[4 * (16 * 32 + 16)] > 3.2)
        let heicURL = url.appendingPathComponent(display.imageFileName)
        let heic = try Data(contentsOf: heicURL)
        let source = try #require(CGImageSourceCreateWithData(heic as CFData, nil))
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil)
        let wrapper = try reopened.fileWrapper()
        #expect(wrapper.fileWrappers?[display.imageFileName]?.regularFileContents == heic)
        let thumb = try #require(wrapper.fileWrappers?["thumbnail.png"]?.regularFileContents)
        let thumbSource = try #require(CGImageSourceCreateWithData(thumb as CFData, nil))
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))
        #expect(thumbnail.width == 12 && thumbnail.height == 10)
        // Atomic replacement must retain edits without recompressing untouched display pixels.
        var edited = reopened
        edited.cornerRadius = 1
        try edited.write(to: url)
        #expect(try CanvasDocument.read(from: url).cornerRadius == 1)
        #expect(try Data(contentsOf: heicURL) == heic)
    }

    // Proves crop/scale, mixed display scales, image orientation, window order and Annotation order.
    @Test func flattenedCompositionMatchesFixture() throws {
        let left = CanvasDisplay(id: 1, frame: CGRect(x: -4, y: -2, width: 4, height: 6), scaleFactor: 1)
        let right = CanvasDisplay(id: 2, frame: CGRect(x: 0, y: -2, width: 4, height: 6), scaleFactor: 2)
        let rightImage = try image(width: 8, height: 12, pixels: (0..<12).flatMap { row in
            Array(repeating: row < 6 ? [UInt8(0), 0, 255, 255] : [UInt8(0), 255, 0, 255], count: 8).flatMap { $0 }
        })
        let white = Annotation(kind: .line(start: CGPoint(x: -10, y: 0), end: CGPoint(x: 10, y: 0)),
            style: .init(colour: .init(red: 1, green: 1, blue: 1, alpha: 1), width: 1))
        let cyan = Annotation(kind: .line(start: CGPoint(x: -1, y: -10), end: CGPoint(x: -1, y: 10)),
            style: .init(colour: .init(red: 0, green: 1, blue: 1, alpha: 1), width: 1))
        let frame = CGRect(x: 1, y: 1, width: 1, height: 1)
        let document = CanvasDocument(layout: [left, right], crop: CGRect(x: -3, y: -1, width: 6, height: 4),
            layerStack: LayerStack([white, cyan]), displayImages: [1: try solidImage([1, 0, 0, 1], width: 4, height: 6), 2: rightImage],
            windowLayers: [
                .init(frame: frame, zOrder: 2, imageFileName: "front.heic", image: try solidImage([1, 1, 0, 1])),
                .init(frame: frame, zOrder: 1, imageFileName: "back.heic", image: try solidImage([0, 1, 1, 1])),
            ])
        try expectFixture(document.flatten(scale: 2), name: "composition", tolerance: 0.01)
        // Recropping out to another display brings its off-crop pixels back.
        let recropped = try document.flatten(crop: CGRect(x: -4, y: 2, width: 1, height: 1), scale: 1)
        #expect(try linearPixels(recropped) == [1, 0, 0, 1])
    }

    // Proves rounded corners clip both underlying pixels and Annotations; uncovered space stays clear.
    @Test func roundedCropMatchesFixture() throws {
        let document = CanvasDocument(layout: [.init(id: 1, frame: CGRect(x: 5, y: -7, width: 8, height: 8), scaleFactor: 1)],
            crop: CGRect(x: 5, y: -7, width: 8, height: 8), cornerRadius: 2,
            layerStack: LayerStack([Annotation(kind: .line(start: CGPoint(x: 5, y: -7), end: CGPoint(x: 13, y: 1)),
                style: .init(colour: .init(red: 1, green: 1, blue: 1, alpha: 1), width: 20))]),
            displayImages: [1: try solidImage([1, 1, 1, 1])])
        try expectFixture(document.flatten(scale: 2), name: "rounded", tolerance: 0.04)
        let empty = CanvasDocument(layout: [], crop: CGRect(x: 0, y: 0, width: 2, height: 2), displayImages: [:])
        #expect(try linearPixels(empty.flatten()).allSatisfy { $0 == 0 })
    }

    // Proves a damaged/newer package fails explicitly rather than opening with lost data.
    @Test func rejectsInvalidPackage() throws {
        let valid = CanvasDocument(layout: [], crop: CGRect(x: 0, y: 0, width: 2, height: 2), displayImages: [:])
        let wrapper = try valid.fileWrapper()
        let json = try #require(wrapper.fileWrappers?["canvas.json"]?.regularFileContents)
        var metadata = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        metadata["version"] = 999
        var children = try #require(wrapper.fileWrappers)
        children["canvas.json"] = FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: metadata))
        #expect(throws: CanvasDocumentError.unsupportedVersion(999)) {
            try CanvasDocument(fileWrapper: FileWrapper(directoryWithFileWrappers: children))
        }
        metadata["version"] = 1
        metadata["embeddedCanvases"] = ["embedded/../outside.wadjet"]
        children["canvas.json"] = FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: metadata))
        #expect(throws: (any Error).self) {
            try CanvasDocument(fileWrapper: FileWrapper(directoryWithFileWrappers: children))
        }
        let corrupt = CanvasDocument(layout: [.init(id: 1, frame: valid.crop, scaleFactor: 1)], crop: valid.crop,
            displayImages: [1: try solidImage([1, 0, 0, 1])])
        var corruptFiles = try #require(corrupt.fileWrapper().fileWrappers)
        corruptFiles["display-1.heic"] = FileWrapper(regularFileWithContents: Data("not an image".utf8))
        #expect(throws: CanvasDocumentError.imageDecodingFailed) {
            try CanvasDocument(fileWrapper: FileWrapper(directoryWithFileWrappers: corruptFiles))
        }
        #expect(throws: CanvasDocumentError.invalidGeometry) { try valid.flatten(scale: .infinity) }
    }
}

private func image(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func solidImage(_ colour: [CGFloat], width: Int = 8, height: Int = 8) throws -> CGImage {
    try image(width: width, height: height,
        pixels: Array(repeating: colour.map { UInt8($0 * 255) }, count: width * height).flatMap { $0 })
}

private func hdrFixture() throws -> CGImage {
    let pixels: [Float] = (0..<64).flatMap { y in
        (0..<64).flatMap { x -> [Float] in
            let white: Float = (16..<48).contains(x) && (16..<48).contains(y) ? 4 : 0.25
            return [white, white, white, 1]
        }
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    let provider = try #require(CGDataProvider(data: data as CFData))
    let image = try #require(CGImage(width: 64, height: 64, bitsPerComponent: 32, bitsPerPixel: 128,
        bytesPerRow: 64 * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    // A raw capture may provide extended pixels without an explicit content-headroom tag.
    return image
}

private func linearPixels(_ image: CGImage) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 32,
        bytesPerRow: image.width * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setEDRTargetHeadroom(0)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
}

private func expectFixture(_ actual: CGImage, name: String, tolerance: Float) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let expected = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(actual.width == expected.width && actual.height == expected.height)
    let rendered = try linearPixels(actual), fixture = try linearPixels(expected)
    let difference = zip(rendered, fixture).map { abs($0 - $1) }.max() ?? 0
    #expect(difference <= tolerance, "\(name): max component difference \(difference)")
}
