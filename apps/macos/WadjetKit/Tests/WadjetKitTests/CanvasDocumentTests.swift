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

    // Proves a Black out censor flattens to exactly opaque black over whatever's beneath.
    @Test func censorBlacksOutFlattenedRect() throws {
        let line = Annotation(kind: .line(start: CGPoint(x: 0, y: 2), end: CGPoint(x: 4, y: 2)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1))
        let censor = Annotation(kind: .censor(rect: CGRect(x: 1, y: 1, width: 2, height: 2), method: .blackOut),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 0.5), width: 3))
        let document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 4, height: 4), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 4, height: 4),
            layerStack: LayerStack([line, censor]),
            displayImages: [1: try solidImage([1, 1, 1, 1], width: 4, height: 4)])
        let pixels = try linearPixels(document.flatten(scale: 1))
        func px(_ x: Int, _ y: Int) -> [Float] { Array(pixels[4 * (y * 4 + x)..<4 * (y * 4 + x) + 4]) }
        // the rect is symmetric in y, so either pixel row order puts rows 1…2 inside
        for x in 1...2 { for y in 1...2 {
            #expect(px(x, y) == [0, 0, 0, 1], "pixel (\(x), \(y))")
        } }
        for (x, y) in [(0, 0), (3, 0), (0, 3), (3, 3)] {
            #expect(px(x, y) == [1, 1, 1, 1], "corner (\(x), \(y))")
        }
    }

    // Proves a flattened canvas paints a shape's fill inside and its stroke on
    // the edge — pure colours so linear values equal sRGB.
    @Test func flattenedPaintsShapeFillAndStroke() throws {
        let shape = Annotation(
            kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 1, y: 1, width: 8, height: 8)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2,
                         fill: .init(red: 0, green: 0, blue: 1, alpha: 1)))
        let document = CanvasDocument(layout: [], crop: CGRect(x: 0, y: 0, width: 10, height: 10),
            layerStack: LayerStack([shape]), displayImages: [:])
        let px = try linearPixels(document.flatten())
        func pixel(_ x: Int, _ y: Int) -> [Float] { Array(px[(4 * (y * 10 + x))..<(4 * (y * 10 + x) + 4)]) }
        #expect(pixel(5, 5) == [0, 0, 1, 1]) // the fill
        #expect(pixel(5, 1) == [1, 0, 0, 1]) // the stroke on the shape's edge
    }

    // Proves a flattened open path draws like a Line — ends, dashes, trim —
    // not just a bare stroke: the filled arrowhead colours a point off the
    // stroke body.
    @Test func flattenedPathDrawsEndsAndFill() throws {
        let open = Annotation(
            kind: .path(PathData(nodes: [PathNode(anchor: CGPoint(x: 2, y: 6)),
                                         PathNode(anchor: CGPoint(x: 10, y: 6))])),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2,
                         head: .filledArrow))
        let closed = Annotation(
            kind: .path(PathData(nodes: [PathNode(anchor: CGPoint(x: 12, y: 2)),
                                         PathNode(anchor: CGPoint(x: 18, y: 2)),
                                         PathNode(anchor: CGPoint(x: 18, y: 8)),
                                         PathNode(anchor: CGPoint(x: 12, y: 8))],
                                 closed: true)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 4,
                         fill: .init(red: 0, green: 0, blue: 1, alpha: 1), stroked: false))
        let document = CanvasDocument(layout: [], crop: CGRect(x: 0, y: 0, width: 20, height: 12),
            layerStack: LayerStack([open, closed]), displayImages: [:])
        let px = try linearPixels(document.flatten())
        func pixel(_ x: Int, _ y: Int) -> [Float] { Array(px[(4 * (y * 20 + x))..<(4 * (y * 20 + x) + 4)]) }
        // the arrowhead (12 long, ~6.9 half-height at its base) covers (4,4),
        // which the 2-wide stroke body alone would leave clear
        #expect(pixel(4, 4) == [1, 0, 0, 1])
        #expect(pixel(15, 5) == [0, 0, 1, 1]) // the closed path's fill
        #expect(pixel(11, 5) == [0, 0, 0, 0]) // stroked off: nothing outside it
    }

    // Mask passes (Magnify's rim) set their own blend mode — the Annotation's
    // multiply must not override it. Fails when `draw` ignored `blending`.
    @Test func drawHonoursTheCallersBlendMode() throws {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 8 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.setBlendMode(.destinationOut)
        let highlighter = Annotation(
            kind: .path(PathData(nodes: [PathNode(anchor: CGPoint(x: 0, y: 4)),
                                         PathNode(anchor: CGPoint(x: 8, y: 4))])),
            style: .init(colour: .init(red: 0, green: 0, blue: 0, alpha: 1), width: 4,
                         blend: .multiply),
            transform: AnnotationTransform())
        ctx.draw(highlighter, blending: false)
        let px = try linearPixels(try #require(ctx.makeImage()))
        #expect(px[4 * (4 * 8 + 4) + 3] == 0) // the stroke erased the mask's alpha
    }

    // Proves a Pixelate censor flattens to uniform blocks of the content beneath.
    @Test func censorPixelatesFlattenedRect() throws {
        // every pixel a distinct grey dominated by its quadrant, so blocks only
        // read uniform once sampled
        let ramp: [UInt8] = (0..<8).flatMap { y -> [UInt8] in
            (0..<8).flatMap { x -> [UInt8] in
                let v = UInt8((x / 4) * 80 + (y / 4) * 140 + (x % 4) * 2 + (y % 4) * 8)
                return [v, v, v, 255]
            }
        }
        let source = try image(width: 8, height: 8, pixels: ramp)
        let censor = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 8, height: 8),
                                              method: .pixelate(blockSize: 4)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 3))
        let document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 8, height: 8), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 8, height: 8),
            layerStack: LayerStack([censor]),
            displayImages: [1: source])
        let pixels = try linearPixels(document.flatten(scale: 1))
        func r(_ x: Int, _ y: Int) -> Float { pixels[4 * (y * 8 + x)] }
        for by in [0, 4] { for bx in [0, 4] {
            let v = r(bx, by)
            for y in by..<by + 4 { for x in bx..<bx + 4 {
                #expect(abs(r(x, y) - v) < 0.001, "pixel (\(x), \(y)) differs inside block (\(bx), \(by))")
            } }
        } }
        // each of the four blocks averages a different quarter of the ramp
        #expect(abs(r(0, 0) - r(4, 0)) > 0.05)
        #expect(abs(r(0, 0) - r(0, 4)) > 0.05)
        #expect(abs(r(0, 0) - r(4, 4)) > 0.05)
    }

    // Proves a Blur censor softens the content beneath's hard edges.
    @Test func censorBlursFlattenedRect() throws {
        // left half black, right half white: a hard vertical edge through the middle
        let edge: [UInt8] = (0..<8).flatMap { _ -> [UInt8] in
            (0..<8).flatMap { x -> [UInt8] in
                let v = UInt8(x < 4 ? 0 : 255)
                return [v, v, v, 255]
            }
        }
        let source = try image(width: 8, height: 8, pixels: edge)
        let censor = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 8, height: 8),
                                              method: .blur(radius: 2)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 3))
        let document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 8, height: 8), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 8, height: 8),
            layerStack: LayerStack([censor]),
            displayImages: [1: source])
        let pixels = try linearPixels(document.flatten(scale: 1))
        func r(_ x: Int, _ y: Int) -> Float { pixels[4 * (y * 8 + x)] }
        // the pixels beside the source's hard edge now sit clearly between 0 and 1
        for y in 0..<8 { for x in [3, 4] {
            #expect(r(x, y) > 0.15 && r(x, y) < 0.85, "pixel (\(x), \(y)) kept the hard edge")
        } }
    }

    // Proves a manifest written before window layers had ids (entries carry only
    // frame/zOrder/imageFileName) opens with a backdrop layer that still draws.
    @Test func oldManifestReadsWindowLayerAsBackdrop() throws {
        let document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 4, height: 4), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 4, height: 4),
            displayImages: [1: try solidImage([0, 0, 1, 1], width: 4, height: 4)],
            windowLayers: [.init(frame: CGRect(x: 1, y: 1, width: 2, height: 2), zOrder: 0,
                imageFileName: "window-0.heic", image: try solidImage([1, 0, 0, 1], width: 2, height: 2))])
        var files = try #require(document.fileWrapper().fileWrappers)
        let oldManifest = """
            {"version":1,"layout":[{"id":1,"frame":[[0,0],[4,4]],"scaleFactor":1,"imageFileName":"display-1.heic"}],"crop":[[0,0],[4,4]],"cornerRadius":0,"windowLayers":[{"frame":[[1,1],[2,2]],"zOrder":0,"imageFileName":"window-0.heic"}],"embeddedCanvases":[],"linkedCanvases":[]}
            """
        files["canvas.json"] = FileWrapper(regularFileWithContents: Data(oldManifest.utf8))
        let old = try CanvasDocument(fileWrapper: FileWrapper(directoryWithFileWrappers: files))
        #expect(old.windowLayers.count == 1)
        #expect(old.windowLayers[0].id == nil)
        let pixels = try linearPixels(old.flatten(scale: 1))
        func px(_ x: Int, _ y: Int) -> [Float] { Array(pixels[4 * (y * 4 + x)..<4 * (y * 4 + x) + 4]) }
        // HEIC is lossy; allow a couple of percent on each component
        #expect(zip(px(1, 1), [1, 0, 0, 1] as [Float]).allSatisfy { abs($0 - $1) < 0.02 }) // the backdrop window drew
        #expect(zip(px(0, 0), [0, 0, 1, 1] as [Float]).allSatisfy { abs($0 - $1) < 0.02 }) // the display beside it
    }

    // Proves window layers keep id/app/title and their Annotations through a
    // save, and deleting a window's Annotation drops its image from the package.
    @Test func windowLayersRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.wadjet")
        var document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 8, height: 8), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 8, height: 8),
            displayImages: [1: try solidImage([1, 1, 1, 1], width: 8, height: 8)])
        document.addWindowLayers([
            CapturedWindow(frame: CGRect(x: 0, y: 0, width: 2, height: 2),
                           image: try solidImage([1, 0, 0, 1]), app: "Front", title: "One"),
            CapturedWindow(frame: CGRect(x: 4, y: 4, width: 2, height: 2),
                           image: try solidImage([0, 1, 0, 1]), app: "Back", title: "Two"),
        ])
        #expect(document.windowLayers.count == 2)
        #expect(document.windowLayers[0].zOrder == 1 && document.windowLayers[1].zOrder == 0)
        // front-first input stacks back to front beneath existing Annotations
        guard case let .window(backID, _) = document.layerStack.annotations[0].kind,
              case let .window(frontID, _) = document.layerStack.annotations[1].kind else {
            Issue.record("expected two .window Annotations"); return
        }
        #expect(frontID == document.windowLayers[0].id && backID == document.windowLayers[1].id)
        try document.write(to: url)
        let reopened = try CanvasDocument.read(from: url)
        #expect(reopened.layerStack == document.layerStack)
        #expect(reopened.windowLayers.map(\.id) == document.windowLayers.map(\.id))
        #expect(reopened.windowLayers.map(\.app) == ["Front", "Back"])
        #expect(reopened.windowLayers.map(\.title) == ["One", "Two"])

        var edited = reopened
        edited.layerStack.remove(id: edited.layerStack.annotations[0].id)
        try edited.write(to: url)
        let trimmed = try CanvasDocument.read(from: url)
        #expect(trimmed.windowLayers.count == 1)
        #expect(trimmed.windowLayers[0].id == frontID)
    }

    // Proves a .window Annotation draws its layer's image, and moving or hiding
    // the Annotation moves or hides the window in the flattened output.
    @Test func windowAnnotationsMoveAndHide() throws {
        var document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 6, height: 2), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 6, height: 2),
            displayImages: [1: try solidImage([0, 0, 1, 1], width: 6, height: 2)])
        document.addWindowLayers([
            CapturedWindow(frame: CGRect(x: 0, y: 0, width: 2, height: 2),
                           image: try solidImage([1, 0, 0, 1], width: 2, height: 2)),
            CapturedWindow(frame: CGRect(x: 2, y: 0, width: 2, height: 2),
                           image: try solidImage([0, 1, 0, 1], width: 2, height: 2)),
        ])
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Float] {
            let px = try linearPixels(image)
            return Array(px[4 * (y * 6 + x)..<4 * (y * 6 + x) + 4])
        }
        var flat = try document.flatten(scale: 1)
        #expect(try pixel(flat, 0, 0) == [1, 0, 0, 1])
        #expect(try pixel(flat, 2, 0) == [0, 1, 0, 1])
        #expect(try pixel(flat, 4, 0) == [0, 0, 1, 1])
        // annotations stack back to front: [green (back), red (front)]
        let red = try #require(document.layerStack.annotations.last)
        var green = try #require(document.layerStack.annotations.first)
        document.layerStack.replace(red.moved(by: CGVector(dx: 4, dy: 0)))
        green.hidden = true
        document.layerStack.replace(green)
        flat = try document.flatten(scale: 1)
        #expect(try pixel(flat, 0, 0) == [0, 0, 1, 1])
        #expect(try pixel(flat, 2, 0) == [0, 0, 1, 1])
        #expect(try pixel(flat, 4, 0) == [1, 0, 0, 1])
    }

    // Proves Annotations stack beneath, between, and above window layers: the
    // blue shape added before capture sits on top, and restacking drops a
    // window below it.
    @Test func annotationsRestackBetweenWindows() throws {
        let shape = Annotation(
            kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 0, y: 0, width: 6, height: 2)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 0,
                         fill: .init(red: 0, green: 0, blue: 1, alpha: 1), stroked: false))
        var document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 6, height: 2), scaleFactor: 1)],
            crop: CGRect(x: 0, y: 0, width: 6, height: 2),
            layerStack: LayerStack([shape]),
            displayImages: [1: try solidImage([1, 1, 1, 1], width: 6, height: 2)])
        document.addWindowLayers([
            CapturedWindow(frame: CGRect(x: 2, y: 0, width: 4, height: 2),
                           image: try solidImage([0, 1, 0, 1], width: 4, height: 2)),
            CapturedWindow(frame: CGRect(x: 0, y: 0, width: 4, height: 2),
                           image: try solidImage([1, 0, 0, 1], width: 4, height: 2)),
        ])
        let kinds = document.layerStack.annotations.map(\.kind)
        guard case .window = kinds[0], case .window = kinds[1], case .shape = kinds[2] else {
            Issue.record("expected [red window, green window, blue shape], got \(kinds)"); return
        }
        // red is the back window: [red, green, shape]
        guard case let .window(redID, _) = kinds[0],
              case let .window(greenID, _) = kinds[1] else { return }
        #expect(redID == document.windowLayers[1].id && greenID == document.windowLayers[0].id)
        func pixel(_ image: CGImage, _ x: Int) throws -> [Float] {
            let px = try linearPixels(image)
            return Array(px[4 * (0 * 6 + x)..<4 * (0 * 6 + x) + 4])
        }
        var flat = try document.flatten(scale: 1)
        #expect(try (0..<6).allSatisfy { try pixel(flat, $0) == [0, 0, 1, 1] })
        document.layerStack.move(shape.id, to: 1) // between the two windows
        flat = try document.flatten(scale: 1)
        #expect(try pixel(flat, 0) == [0, 0, 1, 1])
        #expect(try pixel(flat, 1) == [0, 0, 1, 1])
        #expect(try pixel(flat, 2) == [0, 1, 0, 1])
        #expect(try pixel(flat, 5) == [0, 1, 0, 1])
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
