import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct ScreenshotFoldersTests {
    // Proves capture names read like the capture's date and count up like Finder on collision.
    @Test(arguments: [
        ([], "Wadjet 2026-10-20 at 12.30.00"),
        (["Wadjet 2026-10-20 at 12.30.00"], "Wadjet 2026-10-20 at 12.30.00 2"),
        (["Wadjet 2026-10-20 at 12.30.00", "Wadjet 2026-10-20 at 12.30.00 2"], "Wadjet 2026-10-20 at 12.30.00 3"),
        (["Wadjet 2026-10-20 at 12.30.00 2"], "Wadjet 2026-10-20 at 12.30.00"),
    ] as [([String], String)])
    func captureNamesCountUpLikeFinder(taken: [String], expected: String) {
        let base = CaptureName.base(for: Date(timeIntervalSince1970: 1_792_499_400),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(CaptureName.unique(base, isTaken: Set(taken).contains) == expected)
    }

    // Proves migration names each Canvas by its capture date, oldest first, so a
    // same-second pair and an existing file in original/ push later ones to " 2", " 3".
    @Test func migrationPlanNamesByCaptureDate() {
        let utc = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_792_499_400)
        let older = UUID(), newer = UUID(), other = UUID()
        let legacy = URL(fileURLWithPath: "/legacy")
        let original = URL(fileURLWithPath: "/Pictures/Wadjet/original")
        let moves = CanvasMigrationPlan.moves([
            .init(id: newer, url: legacy.appendingPathComponent("\(newer).wadjet"), createdAt: noon.addingTimeInterval(0.5)),
            .init(id: other, url: legacy.appendingPathComponent("\(other).wadjet"), createdAt: noon.addingTimeInterval(60)),
            .init(id: older, url: legacy.appendingPathComponent("\(older).wadjet"), createdAt: noon),
        ], into: original, taken: ["Wadjet 2026-10-20 at 12.30.00"], timeZone: utc)
        #expect(moves.map(\.id) == [older, newer, other])
        #expect(moves.map(\.to.lastPathComponent) == [
            "Wadjet 2026-10-20 at 12.30.00 2.wadjet",
            "Wadjet 2026-10-20 at 12.30.00 3.wadjet",
            "Wadjet 2026-10-20 at 12.31.00.wadjet",
        ])
        #expect(moves.allSatisfy { $0.to.deletingLastPathComponent().path == original.path })
    }

    // Proves a Screenshot's Canvas in original/ and the image Save file writes
    // to flattened/ share one base name, even when flattened/ already holds it.
    @Test func screenshotPairsCanvasAndFlattenedImage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = ScreenshotFolders(root: root)
        let store = CanvasStore(directory: folders.original)
        let files = CaptureFiles(directory: root.appendingPathComponent("Captures"))
        let created = Date(timeIntervalSince1970: 1_792_499_400)
        try FileManager.default.createDirectory(at: folders.flattened, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: folders.flattened
            .appendingPathComponent("\(CaptureName.base(for: created)).png"))

        let shot = try store.addScreenshot(try canvasFixture(), files: files, createdAt: created,
            pairedWith: [folders.flattened])
        let workflow = Workflow(name: "Screenshot", takes: .screenshot, steps: [.saveFile(folder: nil)])
        var saved: [URL] = []
        for await event in WorkflowRunner(effects: FakeEffects()).run(shot.file, through: workflow,
            defaultFolder: folders.flattened, canvasFolder: folders.root, id: shot.id, canvas: shot.package) {
            if case let .done(urls, _) = event { saved = urls }
        }
        let base = "\(CaptureName.base(for: created)) 2"
        #expect(shot.package.path == folders.original.appendingPathComponent("\(base).wadjet").path)
        #expect(saved.map(\.path) == [folders.flattened.appendingPathComponent("\(base).png").path])
        #expect(try store.url(for: shot.id)?.path == shot.package.path)
    }

    // Proves migration moves container Canvases into original/ by capture date,
    // keeps History finding them by id, points root, Annotation and embedded links
    // at the new files, removes the emptied container folder, and reruns as a no-op.
    @Test func migrationMovesRelinksAndReruns() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Container/Canvases")
        let folders = ScreenshotFolders(root: root.appendingPathComponent("Pictures/Wadjet"))
        let created = Date(timeIntervalSince1970: 1_792_499_400)
        let targetID = UUID(), hostID = UUID()
        let target = try addLegacy(try canvasFixture(), id: targetID, createdAt: created, to: legacy)
        let link = CanvasLink(url: target)
        var host = try canvasFixture()
        host.linkedCanvases = [link]
        host.layerStack = LayerStack([Annotation(kind: .canvas(.linked(link),
            .init(frame: host.crop, crop: CGRect(x: 8, y: 8, width: 8, height: 8))),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1))])
        var embedding = try canvasFixture()
        embedding.embeddedCanvases = ["child.wadjet": host]
        embedding.linkedCanvases = [link]
        embedding.layerStack = host.layerStack
        _ = try addLegacy(embedding, id: hostID, createdAt: created.addingTimeInterval(60), to: legacy)
        let userFile = legacy.deletingLastPathComponent().appendingPathComponent("Wadjet 2026-10-20 at 12.30.00.png")
        try Data("user".utf8).write(to: userFile)
        try FileManager.default.createDirectory(at: folders.original, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: userFile, to: folders.original
            .appendingPathComponent("\(CaptureName.base(for: created)).png"))

        let store = CanvasStore(directory: folders.original)
        let report = try store.migrate(from: legacy)
        #expect(report.failures.isEmpty)
        #expect(report.moved.count == 2)
        #expect(report.relinked == 1)
        let newTarget = try #require(try store.url(for: targetID))
        let newHost = try #require(try store.url(for: hostID))
        #expect(newTarget.lastPathComponent == "\(CaptureName.base(for: created)) 2.wadjet")
        #expect(newHost.lastPathComponent == "\(CaptureName.base(for: created.addingTimeInterval(60))).wadjet")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: userFile.path))

        let moved = try CanvasDocument.read(from: newHost)
        let child = try #require(moved.embeddedCanvases["child.wadjet"])
        for canvas in [moved, child] {
            #expect(canvas.linkedCanvases.map(\.url.path) == [newTarget.path])
            guard case let .canvas(.linked(annotationLink), _) = canvas.layerStack.annotations[0].kind else {
                Issue.record("the Annotation must stay linked"); return
            }
            #expect(annotationLink.url.path == newTarget.path)
        }

        let again = try store.migrate(from: legacy)
        #expect(again.moved.isEmpty && again.relinked == 0 && again.failures.isEmpty)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let rerun = try store.migrate(from: legacy)
        #expect(rerun.moved.isEmpty && rerun.relinked == 0 && rerun.failures.isEmpty)
        #expect(try store.url(for: targetID) == newTarget)
    }

    // Proves retention deletes only History's Canvases in original/: the flattened
    // image and a Save file Canvas, even one saved into original/, stay.
    @Test func retentionTouchesOnlyHistoryCanvasesInOriginal() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = ScreenshotFolders(root: root)
        let created = Date(timeIntervalSince1970: 1_792_499_400)
        let store = CanvasStore(directory: folders.original, now: { created.addingTimeInterval(90 * 86_400) })
        let files = CaptureFiles(directory: root.appendingPathComponent("Captures"))
        let shot = try store.addScreenshot(try canvasFixture(), files: files, createdAt: created,
            pairedWith: [folders.flattened])
        let workflow = Workflow(name: "Keep both", takes: .screenshot, steps: [
            .saveFile(folder: nil), .saveFile(folder: folders.original.path, format: .canvas),
        ])
        var saved: [URL] = []
        for await event in WorkflowRunner(effects: FakeEffects()).run(shot.file, through: workflow,
            defaultFolder: folders.flattened, canvasFolder: folders.root, id: shot.id, canvas: shot.package) {
            if case let .done(urls, _) = event { saved = urls }
        }
        #expect(saved.count == 2)

        #expect(try await store.sweep().map(\.actions) == [[.delete]])
        #expect(try store.url(for: shot.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: shot.package.path))
        for url in saved { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(try await store.sweep().isEmpty)
    }

    // Proves a Finder duplicate of a History Canvas never becomes History's:
    // retention deletes the original and leaves the copy byte-for-byte, sweep after sweep.
    @Test func finderDuplicateOutlivesRetention() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_792_499_400)
        let later = { @Sendable in created.addingTimeInterval(100 * 86_400) }
        let id = UUID()
        let original = try CanvasStore(directory: directory).add(try canvasFixture(), for: id, createdAt: created)
        let copy = directory.appendingPathComponent("\(CaptureName.base(for: created)) copy.wadjet")
        try FileManager.default.copyItem(at: original, to: copy)
        let bytes = try fileBytes(in: copy)

        #expect(CanvasStore(directory: directory).owns(original))
        #expect(!CanvasStore(directory: directory).owns(copy))
        #expect(try await CanvasStore(directory: directory, now: later).sweep().map(\.actions) == [[.delete]])
        #expect(try await CanvasStore(directory: directory, now: later).sweep().isEmpty)
        #expect(try CanvasStore(directory: directory).url(for: id) == nil)
        #expect(try fileBytes(in: copy) == bytes)
    }

    // Proves a migration whose relinking fails keeps the container folder as its
    // retry trigger, and the next launch finishes the relink once the package reads again.
    @Test func failedRelinkRetriesNextLaunch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Container/Canvases")
        let created = Date(timeIntervalSince1970: 1_792_499_400)
        let targetID = UUID(), hostID = UUID()
        let target = try addLegacy(try canvasFixture(), id: targetID, createdAt: created, to: legacy)
        var host = try canvasFixture()
        let link = CanvasLink(url: target)
        host.layerStack = LayerStack([Annotation(kind: .canvas(.linked(link),
            .init(frame: host.crop, crop: CGRect(x: 8, y: 8, width: 8, height: 8))),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1))])
        let legacyHost = try addLegacy(host, id: hostID, createdAt: created.addingTimeInterval(60), to: legacy)
        try Data("broken".utf8).write(to: legacyHost.appendingPathComponent("annotations.json"))

        let store = CanvasStore(directory: root.appendingPathComponent("original"))
        let first = try store.migrate(from: legacy)
        #expect(first.moved.count == 2 && first.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: legacy.path))

        let movedHost = try #require(try store.url(for: hostID))
        try host.layerStack.json().write(to: movedHost.appendingPathComponent("annotations.json"))
        let retry = try store.migrate(from: legacy)
        #expect(retry.moved.isEmpty && retry.relinked == 1 && retry.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        guard case let .canvas(.linked(relinked), _) = try CanvasDocument.read(from: movedHost)
            .layerStack.annotations[0].kind else { Issue.record("the Annotation must stay linked"); return }
        #expect(relinked.url.path == (try store.url(for: targetID))?.path)
    }
}

/// Writes a Canvas the way the container store named them before ids moved
/// into canvas.json: `<UUID>.wadjet`, with no id in its metadata.
private func addLegacy(_ canvas: CanvasDocument, id: UUID, createdAt: Date, to legacy: URL) throws -> URL {
    let staging = legacy.deletingLastPathComponent().appendingPathComponent("staging-\(id)")
    let written = try CanvasStore(directory: staging).add(canvas, for: id, createdAt: createdAt)
    let manifestURL = written.appendingPathComponent("canvas.json")
    var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    var store = try #require(manifest["store"] as? [String: Any])
    store["id"] = nil
    manifest["store"] = store
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let url = legacy.appendingPathComponent("\(id.uuidString).wadjet", isDirectory: false)
    try FileManager.default.moveItem(at: written, to: url)
    try FileManager.default.removeItem(at: staging)
    return url
}

/// Every regular file in a package, by path inside it.
private func fileBytes(in package: URL) throws -> [String: Data] {
    var bytes: [String: Data] = [:]
    for case let file as URL in FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil)!
    where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        bytes[String(file.path.dropFirst(package.path.count))] = try Data(contentsOf: file)
    }
    return bytes
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func canvasFixture() throws -> CanvasDocument {
    let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    return CanvasDocument(layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scaleFactor: 1)],
        crop: CGRect(x: 4, y: 4, width: 24, height: 24), displayImages: [1: try #require(context.makeImage())])
}
