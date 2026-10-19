import CoreGraphics
import Testing
import WadjetKit

struct PixelEdgeSnappingTests {
    // Proves a resized magnifier follows edges beside its frame, never a pixel
    // edge near the separate source that happens to share its grip's x position.
    @Test(arguments: [CGFloat(1), CGFloat(2)], [false, true])
    func magnifierFrame(scale: CGFloat, edgeBySource: Bool) {
        let side = Int(240 * scale)
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        let band = edgeBySource ? CGRect(x: 197, y: 22, width: 23, height: 16)
            : CGRect(x: 196, y: 130, width: 24, height: 40)
        for y in Int((240 - band.maxY) * scale)..<Int((240 - band.minY) * scale) {
            for x in Int(band.minX * scale)..<Int(band.maxX * scale) {
                for channel in 1...3 { bytes[(y * side + x) * 4 + channel] = 0 }
            }
        }
        let proposed = Annotation(kind: .magnify(Magnifier(
            source: CGRect(x: 179, y: 20, width: 20, height: 20),
            frame: CGRect(x: 100, y: 100, width: 98, height: 100),
            options: .init(leader: false))),
            style: .init(colour: .init(red: 0, green: 0, blue: 0, alpha: 1), width: 2))
        bytes.withUnsafeBufferPointer { buffer in
            let pixels = PixelBuffer(base: buffer.baseAddress!, width: side, height: side)
            let grip = CGPoint(x: 198, y: 200)
            let targets = pixels.snapTargets(rect: proposed.pixelSnapBounds, points: [grip],
                                             bounds: CGRect(x: 0, y: 0, width: 240, height: 240), range: 3)
            let result = SnappingEngine.snap(points: [grip], targets: targets, range: 3)
            #expect(result.offset == CGPoint(x: edgeBySource ? 0 : -2, y: 0))
        }
    }

    // Proves visible window UI supplies targets instead of occluded display UI,
    // retaining native pixels even when the Canvas crop covers a smaller area.
    @Test func editorWindowBackdrop() throws {
        let frame = CGRect(x: -20, y: 10, width: 20, height: 20)
        let display = CanvasDisplay(id: 1, frame: frame, scaleFactor: 2)
        let screen = try bandImage(edge: 12)
        let window = try bandImage(edge: 20)
        let canvas = CanvasDocument(layout: [display], crop: CGRect(x: -15, y: 15, width: 5, height: 5),
                                    cornerRadius: 2, displayImages: [1: screen], windowLayers: [
            CanvasWindowLayer(frame: frame, zOrder: 0, imageFileName: "window.heic", image: window,
                              isolatesBackground: true)
        ])
        let image = try canvas.snappingImage(for: display)
        #expect(image.width == 40 && image.height == 40)
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                                            bytesPerRow: 160, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let data = try #require(context.data)
        let pixels = PixelBuffer(base: data.assumingMemoryBound(to: UInt8.self), width: 40, height: 40)
        let hidden = CGPoint(x: -14.5, y: 20) // old display edge at -14
        #expect(pixels.snapTargets(points: [hidden], bounds: frame, range: 1.5).isEmpty)
        let visible = CGPoint(x: -11, y: 20) // visible window edge at -10
        let targets = pixels.snapTargets(points: [visible], bounds: frame, range: 1.5)
        #expect(SnappingEngine.snap(points: [visible], targets: targets, range: 1.5).offset == CGPoint(x: 1, y: 0))
    }

    // Proves a window moved onto a display it didn't cover at capture paints
    // its pixels there — the flat-display fast path keys on the window
    // Annotations' current frames, not the layers' capture-time frames.
    @Test func movedWindowSnapsWhereItSits() throws {
        let a = CanvasDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scaleFactor: 1)
        let b = CanvasDisplay(id: 2, frame: CGRect(x: 100, y: 0, width: 100, height: 100), scaleFactor: 1)
        var canvas = CanvasDocument(layout: [a, b],
            crop: CGRect(x: 0, y: 0, width: 200, height: 100),
            displayImages: [1: try solid([0, 0, 1]), 2: try solid([0, 1, 0])])
        canvas.addWindowLayers([
            CapturedWindow(frame: CGRect(x: 10, y: 10, width: 40, height: 40),
                           image: try solid([1, 0, 0])),
        ])
        let window = try #require(canvas.layerStack.annotations.last)
        canvas.layerStack.replace(window.moved(by: CGVector(dx: 100, dy: 0))) // now over B
        let image = try canvas.snappingImage(for: b)
        // the window's left edge sits at canvas x 110 → B-local x 10
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                            bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let pixels = PixelBuffer(base: try #require(context.data)
            .assumingMemoryBound(to: UInt8.self), width: 100, height: 100)
        let probe = CGPoint(x: 115, y: 30)
        let targets = pixels.snapTargets(points: [probe], bounds: b.frame, range: 6)
        #expect(SnappingEngine.snap(points: [probe], targets: targets, range: 6).offset == CGPoint(x: -5, y: 0),
                "window edge pulls the point to x 110")
    }

    private func solid(_ colour: [CGFloat], side: Int = 100) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: colour[0], green: colour[1], blue: colour[2], alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    private func bandImage(edge: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                                            bytesPerRow: 160, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: edge, y: 0, width: 40 - edge, height: 40))
        return try #require(context.makeImage())
    }

    // Proves boxes and Line ends use real image edges in global points at both
    // display scales, while edges beyond the user's range leave them alone.
    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func imageEdges(scale: CGFloat) {
        var bytes = [UInt8](repeating: 255, count: 40 * 40 * 4)
        for y in 8..<30 {
            for x in 12..<28 {
                for channel in 1...3 { bytes[(y * 40 + x) * 4 + channel] = 0 }
            }
        }
        bytes.withUnsafeBufferPointer { buffer in
            let pixels = PixelBuffer(base: buffer.baseAddress!, width: 40, height: 40)
            let bounds = CGRect(x: -100, y: 50, width: 40 / scale, height: 40 / scale)
            let rect = CGRect(x: -100 + 9 / scale, y: 50 + 13 / scale,
                              width: 14 / scale, height: 10 / scale)
            let range = 3 / scale
            let targets = pixels.snapTargets(rect: rect, bounds: bounds, range: range)
            let box = SnappingEngine.snap(rect: rect, targets: targets, range: range)
            #expect(box.offset == CGPoint(x: 3 / scale, y: -3 / scale))
            #expect(box.guides.count == 2)
            #expect(targets.contains { if case .x(-100 + 12 / scale, span: .some) = $0 { true } else { false } })

            let end = CGPoint(x: rect.minX, y: rect.minY)
            let endTargets = pixels.snapTargets(points: [end], bounds: bounds, range: range)
            let line = SnappingEngine.snap(points: [end], targets: endTargets, range: range)
            #expect(line.offset == CGPoint(x: 3 / scale, y: 0))
            #expect(line.guides.count == 1)
            let bottomEnd = CGPoint(x: -100 + 16 / scale, y: rect.minY)
            let bottomTargets = pixels.snapTargets(points: [bottomEnd], bounds: bounds, range: range)
            #expect(SnappingEngine.snap(points: [bottomEnd], targets: bottomTargets, range: range).offset
                == CGPoint(x: 0, y: -3 / scale))
            #expect(SnappingEngine.snap(points: [end], targets: endTargets, range: range, skip: true).guides.isEmpty)

            let outside = CGPoint(x: -100 + 8 / scale, y: 50 + 20 / scale)
            let distant = pixels.snapTargets(points: [outside], bounds: bounds, range: range)
            #expect(SnappingEngine.snap(points: [outside], targets: distant, range: range).offset == .zero)
            #expect(distant.isEmpty)

            // A bounded scan through a flat area must not invent an edge at its limit.
            let flat = CGPoint(x: -100 + 5 / scale, y: 50 + 35 / scale)
            #expect(pixels.snapTargets(points: [flat], bounds: bounds, range: range).isEmpty)
        }
    }
}
