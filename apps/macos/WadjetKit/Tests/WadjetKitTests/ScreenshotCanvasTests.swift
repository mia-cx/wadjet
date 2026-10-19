import CoreGraphics
import Foundation
import Testing
import WadjetKit

@MainActor
struct ScreenshotCanvasTests {
    // Proves recropping retains every display, HDR pixels, and off-crop layers in their original order.
    @Test func capturesFullDisplaysAndOffCropAnnotations() throws {
        let displays = try capturedDisplays()
        let inside = line(2, 2, 8, 2)
        let outsideCrop = line(-18, 12, -12, 12)
        let outsideDisplays = line(40, 40, 50, 40)
        let crop = CGRect(x: 1, y: 1, width: 8, height: 6)
        let canvas = CanvasDocument(capturedDisplays: displays, crop: crop, cornerRadius: 2,
            annotations: LayerStack([inside, outsideCrop, outsideDisplays]))
        #expect(canvas.layout == displays.map(\.display))
        #expect(canvas.crop == crop && canvas.cornerRadius == 2)
        #expect(canvas.layerStack.annotations == [inside, outsideCrop])
        #expect(canvas.displayImages[1] === displays[0].image)
        #expect(canvas.displayImages[2] === displays[1].image)
        #expect(try pixels(canvas.flatten(crop: displays[1].display.frame))[4 * (10 * 20 + 10)] > 3.9)
    }

    // Proves window captures keep stroke overlap, including transformed strokes, and omit other layers.
    @Test func windowCaptureFiltersByRenderedOverlap() throws {
        let crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        let crossing = line(-5, 5, 15, 5)
        let edge = line(-0.5, 1, -0.5, 8)
        var rotated = line(4, 12, 16, 12)
        rotated.transform.rotation = .pi / 2
        let misses = line(8, 15, 15, 8) // bounding box overlaps, the stroke does not
        let elsewhere = line(-18, 12, -12, 12)
        let coveringCensor = Annotation(kind: .censor(rect: CGRect(x: -5, y: -5, width: 20, height: 20), method: .blackOut),
            style: crossing.style)
        let canvas = CanvasDocument(capturedDisplays: try capturedDisplays(), crop: crop,
            annotations: LayerStack([crossing, edge, rotated, misses, elsewhere, coveringCensor]), windowCapture: true)
        #expect(canvas.layerStack.annotations == [crossing, edge, rotated, coveringCensor])
        #expect(canvas.layout.count == 2)
    }

    // Proves exported pixels use panel geometry (rotation and flips) and multiply style opacity by colour alpha.
    @Test func transformedOpacityMatchesFixture() throws {
        struct Fixture: Decodable { var rotation: Double; var flip: Bool; var samples: [[Float]] }
        let url = try #require(Bundle.module.url(forResource: "transformed-opacity", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            var annotation = fixture.flip ? line(2, 2, 10, 10) : line(2, 6, 10, 6)
            annotation.style = .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 0.5), width: 2, opacity: 0.25)
            annotation.transform = .init(rotation: fixture.rotation, flipHorizontal: fixture.flip)
            let canvas = CanvasDocument(layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 12, height: 12), scaleFactor: 1)],
                crop: CGRect(x: 0, y: 0, width: 12, height: 12), layerStack: LayerStack([annotation]),
                displayImages: [1: try solidImage(value: 0)])
            let rendered = try pixels(canvas.flatten())
            for sample in fixture.samples {
                let offset = 4 * (Int(sample[1]) * 12 + Int(sample[0]))
                #expect(abs(rendered[offset] - sample[2]) < 0.01)
                #expect(rendered[offset + 1] == 0 && rendered[offset + 2] == 0)
                #expect(abs(rendered[offset + 3] - 1) < 0.001)
            }
        }
    }

    // Proves the clipboard carries a self-contained, editable package even without its original History URL.
    @Test func serializedPackageRoundTrip() throws {
        let canvas = CanvasDocument(capturedDisplays: try capturedDisplays(), crop: CGRect(x: 1, y: 1, width: 8, height: 6),
            annotations: LayerStack([line(-18, 12, -12, 12)]))
        let restored = try CanvasDocument.read(serializedPackage: canvas.serializedPackage())
        #expect(restored.layout == canvas.layout)
        #expect(restored.crop == canvas.crop)
        #expect(restored.layerStack == canvas.layerStack)
        #expect(restored.displayImages.count == 2)
    }

    // Proves Save Canvas writes a readable, independently named package while later image effects receive the flattened image.
    @Test func saveCanvasKeepsImageEffectsAndHandlesCollisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Screenshot.png")
        try Data("flattened image".utf8).write(to: file)
        let canvas = CanvasDocument(capturedDisplays: try capturedDisplays(), crop: CGRect(x: 1, y: 1, width: 8, height: 6),
            annotations: LayerStack([line(2, 2, 8, 2)]))
        let package = CanvasStore(directory: directory.appendingPathComponent("History Canvases"))
        let history = try HistoryStore.inMemory()
        let id = UUID(), createdAt = Date()
        let packageURL = try package.add(canvas, for: id, createdAt: createdAt)
        let entry = try history.record(id: id, kind: .screenshot, createdAt: createdAt, file: file)
        #expect(try package.canvas(for: entry.id)?.layerStack == canvas.layerStack)
        let effects = FakeEffects()
        let save = Step.saveFile(folder: nil, format: .canvas)
        let workflow = Workflow(name: "Canvas", takes: .screenshot, steps: [save, .copyImage, save, .pin, .showToast, .copyFile])
        var events: [RunEvent] = []
        for await event in WorkflowRunner(effects: effects).run(file, through: workflow, defaultFolder: directory, canvas: packageURL) {
            events.append(event)
        }
        let first = directory.appendingPathComponent("Screenshot.wadjet")
        let second = directory.appendingPathComponent("Screenshot 2.wadjet")
        guard case .done(let saved, let errors) = events.last else { Issue.record("no completion"); return }
        #expect(saved.map(\.path) == [first.path, second.path] && errors.isEmpty)
        #expect(try CanvasDocument.read(from: first).layerStack == canvas.layerStack)
        #expect(try CanvasDocument.read(from: second).crop == canvas.crop)
        #expect(effects.files.map(\.path) == [file, file, file, second].map(\.path))
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(save)) == save)
    }

    // Proves unavailable Canvas data reports a failed Step and still copies the image; Recordings reject Canvas format at config load.
    @Test func missingCanvasFailsOnlySaveStep() async throws {
        let effects = FakeEffects()
        let save = Step.saveFile(folder: nil, format: .canvas)
        let file = URL(fileURLWithPath: "/unused.png")
        let workflow = Workflow(name: "Canvas", takes: .screenshot, steps: [save, .copyImage])
        var events: [RunEvent] = []
        for await event in WorkflowRunner(effects: effects).run(file, through: workflow, defaultFolder: .temporaryDirectory) {
            events.append(event)
        }
        guard case .failed(0, save, _) = events[1] else { Issue.record("Save Canvas should fail"); return }
        #expect(effects.files == [file])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Workflow.self, from: Data(#"{"name":"Bad","takes":"mp4","steps":[{"type":"saveFile","format":"canvas"}]}"#.utf8))
        }
    }
}

private func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> Annotation {
    Annotation(kind: .line(start: CGPoint(x: x1, y: y1), end: CGPoint(x: x2, y: y2)),
        style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))
}

private func capturedDisplays() throws -> [CapturedCanvasDisplay] {
    [CapturedCanvasDisplay(display: .init(id: 1, frame: CGRect(x: -20, y: 0, width: 20, height: 20), scaleFactor: 1),
        image: try solidImage(value: 0)),
     CapturedCanvasDisplay(display: .init(id: 2, frame: CGRect(x: 0, y: 0, width: 20, height: 20), scaleFactor: 2),
        image: try solidImage(value: 4))]
}

private func solidImage(value: Float) throws -> CGImage {
    let values: [Float] = Array(repeating: [value, value, value, 1], count: 12 * 12).flatMap { $0 }
    let data = values.withUnsafeBytes { Data($0) }
    return try #require(CGImage(width: 12, height: 12, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: 12 * 16,
        space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func pixels(_ image: CGImage) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 32,
        bytesPerRow: image.width * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setEDRTargetHeadroom(0)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: Float.self),
        count: image.width * image.height * 4))
}
