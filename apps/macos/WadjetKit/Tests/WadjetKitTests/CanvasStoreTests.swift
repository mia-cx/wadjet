import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import WadjetKit

struct CanvasStoreTests {
    // Proves persisted, configurable deadlines change real pixels/files exactly once,
    // retain displays touched by a stroked Annotation, and leave History intact.
    @Test @MainActor func retentionStages() throws {
        let directory = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_000_000)
        let clock = Mutex(created)
        let store = CanvasStore(directory: directory, now: { clock.withLock { $0 } })
        let history = try HistoryStore.inMemory()
        let entry = try history.record(kind: .screenshot, createdAt: created, file: nil)
        var canvas = try fixtureCanvas()
        let stroke = Annotation(kind: .line(start: CGPoint(x: 96, y: 10), end: CGPoint(x: 96, y: 40)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 10))
        canvas.layout += [
            .init(id: 2, frame: CGRect(x: 100, y: 0, width: 64, height: 64), scaleFactor: 1),
            .init(id: 3, frame: CGRect(x: 200, y: 0, width: 64, height: 64), scaleFactor: 1),
        ]
        canvas.displayImages[2] = canvas.displayImages[1]
        canvas.displayImages[3] = canvas.displayImages[1]
        canvas.layerStack = LayerStack([stroke])
        canvas.windowLayers = [.init(frame: canvas.crop, zOrder: 0, imageFileName: "window.heic",
            image: try rasterFixture(hdr: false))]
        canvas.embeddedCanvases = ["child.wadjet": try fixtureCanvas()]
        let package = try store.add(canvas, for: entry.id, createdAt: entry.createdAt)
        #expect(try store.url(for: entry.id) == package)
        #expect(try store.canvas(for: entry.id)?.layerStack == canvas.layerStack)
        #expect(throws: (any Error).self) { try store.add(canvas, for: entry.id, createdAt: created) }
        let displayURL = package.appendingPathComponent("display-1.heic")
        let windowURL = package.appendingPathComponent("window.heic")
        let originalWindow = try Data(contentsOf: windowURL)
        #expect(try hasGainMap(at: displayURL))
        let settings = CanvasRetentionSettings(daysUntilSDRAndLossyHEIC: 2,
            daysUntilDroppingUnusedDisplays: 4, daysUntilDeletion: 6)

        clock.withLock { $0 = created.addingTimeInterval(2 * 86_400 - 1) }
        #expect(try store.sweep(settings: settings).isEmpty)
        clock.withLock { $0 = created.addingTimeInterval(2 * 86_400) }
        #expect(try store.sweep(settings: settings).flatMap(\.actions) == [.convertToSDR, .reencodeLossyHEIC])
        let degraded = try #require(try store.canvas(for: entry.id))
        let image = try #require(degraded.displayImages[1])
        #expect(max(image.contentHeadroom, image.calculatedContentHeadroom) <= 1)
        #expect(try !hasGainMap(at: displayURL))
        #expect(try !hasGainMap(at: package.appendingPathComponent("embedded/child.wadjet/display-1.heic")))
        #expect(try Data(contentsOf: windowURL).count < originalWindow.count)
        let once = try Data(contentsOf: displayURL)
        #expect(try store.sweep(settings: settings).isEmpty)
        #expect(try Data(contentsOf: displayURL) == once)

        // Editor open/save preserves retention metadata, including the original capture date.
        var edited = degraded
        edited.cornerRadius = 2
        try edited.write(to: package)
        let reopenedStore = CanvasStore(directory: directory, now: { clock.withLock { $0 } })
        #expect(try reopenedStore.sweep(settings: settings).isEmpty)
        clock.withLock { $0 = created.addingTimeInterval(4 * 86_400 - 1) }
        #expect(try reopenedStore.sweep(settings: settings).isEmpty)
        clock.withLock { $0 = created.addingTimeInterval(4 * 86_400) }
        #expect(try reopenedStore.sweep(settings: settings).flatMap(\.actions) == [.dropUnusedDisplays])
        #expect(try reopenedStore.canvas(for: entry.id)?.layout.map(\.id) == [1, 2])
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("display-3.heic").path))
        #expect(try Data(contentsOf: displayURL) == once)
        #expect(try reopenedStore.sweep(settings: settings).isEmpty)
        clock.withLock { $0 = created.addingTimeInterval(6 * 86_400 - 1) }
        #expect(try reopenedStore.sweep(settings: settings).isEmpty)
        clock.withLock { $0 = created.addingTimeInterval(6 * 86_400) }
        #expect(try reopenedStore.sweep(settings: settings).flatMap(\.actions) == [.delete])
        #expect(!FileManager.default.fileExists(atPath: package.path))
        #expect(try reopenedStore.url(for: entry.id) == nil)
        #expect(try reopenedStore.canvas(for: entry.id) == nil)
        #expect(try reopenedStore.sweep(settings: settings).isEmpty)
        #expect(try history.recent().map(\.id) == [entry.id])
    }

    // Proves links from canvas.json use the newest host's age and protect the target
    // through the host's deletion sweep; the next sweep can delete the orphan.
    @Test func newestLinkControlsLifetimeAndDegradation() throws {
        let directory = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date(timeIntervalSince1970: 0)
        let newest = old.addingTimeInterval(200 * 86_400)
        let clock = Mutex(newest)
        let store = CanvasStore(directory: directory, now: { clock.withLock { $0 } })
        let targetID = UUID(), olderHost = UUID(), newestHost = UUID()
        let targetURL = try store.add(fixtureCanvas(), for: targetID, createdAt: old)
        var host = try fixtureCanvas()
        host.linkedCanvases = [CanvasLink(url: targetURL)]
        try store.add(host, for: olderHost, createdAt: old.addingTimeInterval(150 * 86_400))
        try store.add(host, for: newestHost, createdAt: newest)
        #expect(try store.sweep().map(\.canvasID) == [olderHost])
        #expect(try hasGainMap(at: targetURL.appendingPathComponent("display-1.heic")))
        clock.withLock { $0 = newest.addingTimeInterval(7 * 86_400) }
        let decisions = try store.sweep()
        #expect(Set(decisions.map(\.canvasID)) == [targetID, newestHost])
        #expect(decisions.allSatisfy { $0.actions == [.convertToSDR, .reencodeLossyHEIC] })
        #expect(try !hasGainMap(at: targetURL.appendingPathComponent("display-1.heic")))
        #expect(try store.sweep().isEmpty)
        clock.withLock { $0 = newest.addingTimeInterval(90 * 86_400) }
        let atDeletion = try store.sweep()
        #expect(atDeletion.contains { $0.canvasID == newestHost && $0.actions == [.delete] })
        #expect(!atDeletion.contains { $0.canvasID == targetID && $0.actions.contains(.delete) })
        #expect(try store.url(for: targetID) == targetURL)
        #expect(try store.sweep().map(\.canvasID) == [targetID])
        #expect(try store.url(for: targetID) == nil)
    }

    // Proves never-delete still degrades, and Save file copies outside the store
    // remain byte-for-byte untouched, even when linked or symlinked into it.
    @Test func neverDeleteAndSavedCopies() throws {
        let root = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        let now = Date(timeIntervalSince1970: 1_000 * 86_400)
        let store = CanvasStore(directory: directory, now: { now })
        #expect(try store.sweep().isEmpty)
        let id = UUID()
        let package = try store.add(fixtureCanvas(), for: id, createdAt: Date(timeIntervalSince1970: 0))
        let saved = root.appendingPathComponent("saved.wadjet")
        try FileManager.default.copyItem(at: package, to: saved)
        let original = try packageBytes(at: saved)
        var linked = try #require(try store.canvas(for: id))
        linked.linkedCanvases = [CanvasLink(url: saved)]
        try linked.write(to: package)
        let symlinkID = UUID()
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("\(symlinkID).wadjet"), withDestinationURL: saved)
        #expect(try store.url(for: symlinkID) == nil)
        let settings = CanvasRetentionSettings(daysUntilDeletion: 0)
        #expect(try store.sweep(settings: settings).flatMap(\.actions)
            == [.convertToSDR, .reencodeLossyHEIC, .dropUnusedDisplays])
        #expect(try store.sweep(settings: settings).isEmpty)
        #expect(try store.url(for: id) != nil)
        #expect(try packageBytes(at: saved) == original)
    }

    // Proves a damaged host's unreadable links cannot cause deletion of its target.
    @Test func unreadableManifestAbortsBeforeDeletion() throws {
        let directory = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let store = CanvasStore(directory: directory, now: { now })
        let target = UUID()
        try store.add(fixtureCanvas(), for: target, createdAt: Date(timeIntervalSince1970: 0))
        let hostURL = try store.add(fixtureCanvas(), for: UUID(), createdAt: now)
        try Data("broken".utf8).write(to: hostURL.appendingPathComponent("canvas.json"))
        #expect(throws: (any Error).self) { try store.sweep() }
        #expect(try store.url(for: target) != nil)
    }
}

private func temporaryCanvasDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func fixtureCanvas() throws -> CanvasDocument {
    CanvasDocument(layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scaleFactor: 4)],
        crop: CGRect(x: 4, y: 4, width: 24, height: 24), displayImages: [1: try rasterFixture(hdr: true)])
}

private func rasterFixture(hdr: Bool) throws -> CGImage {
    // Deterministic detailed pixels give lossy HEIC something measurable to discard.
    let pixels: [Float] = (0..<(256 * 256)).flatMap { index -> [Float] in
        let value = Float((index * 73 + index / 256 * 137) % 251) / 250
        return [value * (hdr ? 4 : 1), value * 0.75, value * 0.5, 1]
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    let provider = try #require(CGDataProvider(data: data as CFData))
    return try #require(CGImage(width: 256, height: 256, bitsPerComponent: 32, bitsPerPixel: 128,
        bytesPerRow: 256 * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: [.floatComponents, .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func hasGainMap(at url: URL) throws -> Bool {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
}

private func packageBytes(at url: URL) throws -> [String: Data] {
    let files = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: Data] = [:]
    for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[String(file.path.dropFirst(url.path.count))] = try Data(contentsOf: file)
    }
    return result
}
