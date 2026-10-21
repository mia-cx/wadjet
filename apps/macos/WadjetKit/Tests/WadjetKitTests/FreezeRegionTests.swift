import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct FreezeRegionTests {
    // Proves a frozen region keeps its exact spot and pixels: the placement
    // sits on the picked rect, the embedded layout's union is that rect at the
    // display's own scale, and a border-hidden copy flattens to the same
    // pixels the original displays would.
    @Test(arguments: [CGFloat(1), 2])
    func frozenRegionKeepsItsPixels(scale: CGFloat) throws {
        let frame = CGRect(x: 100, y: 50, width: 40, height: 30)
        let w = Int(frame.width * scale), h = Int(frame.height * scale)
        let display = CanvasDisplay(id: 7, frame: frame, scaleFactor: scale)
        let source = try patternImage(width: w, height: h)
        let rect = CGRect(x: 110, y: 60, width: 20, height: 15)
        let frozen = CanvasDocument(freezing: [CapturedCanvasDisplay(display: display, image: source)],
                                    rect: rect)
        #expect(frozen.layout.count == 1)
        #expect(frozen.layout[0].frame == rect)
        let embedded = try #require(frozen.displayImages[7])
        #expect(embedded.width == Int(rect.width * scale))
        #expect(embedded.height == Int(rect.height * scale))

        let name = "frozen.wadjet"
        var annotation = Annotation.frozenRegion(embedding: name, frozen,
            style: .init(colour: .init(red: 1, green: 1, blue: 1, alpha: 1), width: 1))
        let placement = try #require(annotation.placement)
        #expect(placement.frame == rect)
        #expect(placement.crop == rect)
        #expect(placement.crop == frozen.layout.map(\.frame).reduce(rect) { $0.union($1) })
        #expect(placement.border == .difference)

        // hide the border so only pixels compare
        annotation.placement = { var p = placement; p.border = .hidden; return p }()
        let black = try solidColour(0, width: w, height: h)
        var host = CanvasDocument(layout: [display], crop: rect,
            layerStack: LayerStack([annotation]), displayImages: [7: black])
        host.embeddedCanvases[name] = frozen
        let original = CanvasDocument(layout: [display], crop: rect, displayImages: [7: source])
        let a = try linearPixels(host.flatten(crop: rect, scale: scale))
        let b = try linearPixels(original.flatten(crop: rect, scale: scale))
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 0.02 })
    }

    // Proves a rect spanning two displays picks each display's part at its own
    // scale — and an HDR display's >1 values survive the crop.
    @Test func frozenRegionSpansDisplays() throws {
        let left = CanvasDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20), scaleFactor: 1)
        let right = CanvasDisplay(id: 2, frame: CGRect(x: 20, y: 0, width: 20, height: 20), scaleFactor: 2)
        let rect = CGRect(x: 10, y: 5, width: 20, height: 10)
        let frozen = CanvasDocument(freezing: [
            CapturedCanvasDisplay(display: left, image: try solidColour(0.5, width: 20, height: 20)),
            CapturedCanvasDisplay(display: right, image: try solidColour(4, width: 40, height: 40)),
        ], rect: rect)
        #expect(frozen.layout.map(\.frame) == [CGRect(x: 10, y: 5, width: 10, height: 10),
                                               CGRect(x: 20, y: 5, width: 10, height: 10)])
        #expect(frozen.displayImages[1]?.width == 10 && frozen.displayImages[1]?.height == 10)
        #expect(frozen.displayImages[2]?.width == 20 && frozen.displayImages[2]?.height == 20)
        let px = try linearPixels(frozen.flatten(crop: rect, scale: 1))
        func pixel(_ x: Int, _ y: Int) -> [Float] { Array(px[4 * (y * 20 + x)..<4 * (y * 20 + x) + 4]) }
        #expect(abs(pixel(5, 5)[0] - 0.5) < 0.02)  // the 1x display's interior
        #expect(pixel(15, 5)[0] > 3.5)             // HDR headroom survived the 2x crop
    }

    // Proves an embedded frozen region round-trips through the package: the
    // kind decodes as .embedded, the nested Canvas comes back, and the
    // reopened host still renders the frozen pixels.
    @Test func packageRoundTripsAFrozenRegion() throws {
        let frame = CGRect(x: 100, y: 50, width: 40, height: 30)
        let rect = CGRect(x: 110, y: 60, width: 20, height: 15)
        let frozen = CanvasDocument(freezing: [CapturedCanvasDisplay(
            display: .init(id: 7, frame: frame, scaleFactor: 1),
            image: try solidColour(1, width: 40, height: 30))], rect: rect)
        let name = "\(UUID().uuidString).wadjet"
        var annotation = Annotation.frozenRegion(embedding: name, frozen,
            style: .init(colour: .init(red: 1, green: 1, blue: 1, alpha: 1), width: 1))
        annotation.placement?.border = .hidden
        var host = CanvasDocument(layout: [.init(id: 7, frame: frame, scaleFactor: 1)],
            crop: frame, layerStack: LayerStack([annotation]),
            displayImages: [7: try solidColour(0, width: 40, height: 30)])
        host.embeddedCanvases[name] = frozen
        let reopened = try CanvasDocument(fileWrapper: host.fileWrapper())
        #expect(reopened.layerStack == host.layerStack)
        guard case let .canvas(.embedded(reopenedName), _) = reopened.layerStack.annotations[0].kind else {
            Issue.record("expected a .canvas(.embedded) kind"); return
        }
        #expect(reopenedName == name)
        #expect(reopened.embeddedCanvases[name]?.layout == frozen.layout)
        #expect(reopened.embeddedCanvases[name]?.crop == frozen.crop)
        // HEIC is lossy; compare the frozen spot to the original's own re-encode tolerance
        let px = try linearPixels(reopened.flatten(crop: frame, scale: 1))
        // pixel rows run top-down: point (x, y) sits at (x-100, 80-y)
        func pixel(_ x: Int, _ y: Int) -> [Float] {
            Array(px[4 * ((80 - y) * 40 + (x - 100))..<4 * ((80 - y) * 40 + (x - 100)) + 4]) }
        #expect(zip(pixel(115, 67), [1, 1, 1, 1] as [Float]).allSatisfy { abs($0 - $1) < 0.1 })
        #expect(zip(pixel(105, 55), [0, 0, 0, 1] as [Float]).allSatisfy { abs($0 - $1) < 0.1 })
    }

    // Proves addAtBottom keeps a frozen region beneath what's drawn: a Black
    // out already over the spot still blacks it out.
    @Test func frozenRegionSitsBeneathACensor() throws {
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        let frozen = CanvasDocument(freezing: [CapturedCanvasDisplay(
            display: .init(id: 1, frame: rect, scaleFactor: 1),
            image: try solidColour(1, width: 8, height: 8))], rect: rect)
        let style = AnnotationStyle(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1)
        var stack = LayerStack([Annotation(kind: .censor(rect: rect, method: .blackOut), style: style)])
        stack.addAtBottom(Annotation.frozenRegion(embedding: "f.wadjet", frozen, style: style))
        #expect(stack.annotations.count == 2)
        guard case .canvas = stack.annotations[0].kind,
              case .censor = stack.annotations[1].kind else {
            Issue.record("expected the frozen region beneath the censor"); return
        }
        var host = CanvasDocument(layout: [.init(id: 1, frame: rect, scaleFactor: 1)],
            crop: rect, layerStack: stack, displayImages: [1: try solidColour(0, width: 8, height: 8)])
        host.embeddedCanvases["f.wadjet"] = frozen
        #expect(try linearPixels(host.flatten()).allSatisfy { [0, 0, 0, 1].contains($0) })
    }
}

/// a deterministic per-pixel pattern — crops can be told apart from shifts
private func patternImage(width: Int, height: Int) throws -> CGImage {
    let pixels: [UInt8] = (0..<width * height).flatMap { (i: Int) -> [UInt8] in
        [UInt8(i % 251), UInt8(i * 7 % 251), UInt8(i * 13 % 251), 255]
    }
    return try image(width: width, height: height, pixels: pixels)
}

/// an extended-sRGB grey at `value` — >1 keeps HDR headroom
private func solidColour(_ value: Float, width: Int, height: Int) throws -> CGImage {
    let values: [Float] = Array(repeating: [value, value, value, 1], count: width * height).flatMap { $0 }
    let data = values.withUnsafeBytes { Data($0) }
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
        bytesPerRow: width * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: [.floatComponents, .byteOrder32Little,
                     CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: CGDataProvider(data: data as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent))
}

private func image(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func linearPixels(_ image: CGImage) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 32, bytesPerRow: image.width * 16,
        space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setEDRTargetHeadroom(0)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
}
