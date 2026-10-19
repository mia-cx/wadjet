import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import WadjetKit

struct CanvasStoreTests {
    // Proves saving omits deleted window images from disk while retaining their
    // live source pixels, so Undo can restore a window and save/export it again.
    @Test func archivingKeepsWindowSourcesForUndo() throws {
        var live = try fixtureCanvas()
        let id = UUID()
        live.windowLayers = [.init(frame: live.crop, zOrder: 0, imageFileName: "window.heic",
            image: try rasterFixture(hdr: false), id: id)]
        let original = LayerStack([Annotation(kind: .window(layerID: id, frame: live.crop),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1))])
        live.layerStack = original
        live.layerStack.clear()
        let saved = try live.archiveLinkedCanvases()
        #expect(try CanvasDocument(fileWrapper: saved).windowLayers.isEmpty)
        #expect(saved.fileWrappers?["window.heic"] == nil)
        live.layerStack = original // the Editor's Undo restores the layer stack
        #expect(try live.flatten().width > 0)
        #expect(try CanvasDocument(fileWrapper: live.archiveLinkedCanvases()).windowLayers.map(\.id) == [id])
    }

    // Proves Save file keeps full recroppable sources after both History
    // packages expire, including links inside embedded hosts and Editor resaves.
    @Test(arguments: [false, true]) func savedCanvasOutlivesLinkedHistory(embedded: Bool) async throws {
        let root = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = Date(timeIntervalSince1970: 1_000_000)
        let clock = Mutex(created)
        let store = CanvasStore(directory: root.appendingPathComponent("History"), now: { clock.withLock { $0 } })
        let targetID = UUID(), hostID = UUID()
        let target = try fixtureCanvas()
        let targetURL = try store.add(target, for: targetID, createdAt: created)
        var host = try fixtureCanvas()
        let link = CanvasLink(url: targetURL)
        host.linkedCanvases = [link]
        host.linkedDocuments = [targetURL: target]
        host.layerStack = LayerStack([Annotation(kind: .canvas(.linked(link),
            .init(frame: host.crop, crop: CGRect(x: 8, y: 8, width: 8, height: 8))),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1))])
        if embedded {
            var parent = try fixtureCanvas()
            parent.embeddedCanvases = ["child.wadjet": host]
            host = parent
        }
        let hostURL = try store.add(host, for: hostID, createdAt: created)
        let image = root.appendingPathComponent("Screenshot.png")
        try Data("image".utf8).write(to: image)
        let savedDirectory = root.appendingPathComponent("Saved")
        let workflow = Workflow(name: "Keep Canvas", takes: .screenshot,
            steps: [.saveFile(folder: nil, format: .canvas)])
        var events: [RunEvent] = []
        for await event in WorkflowRunner(effects: FakeEffects()).run(image, through: workflow,
            defaultFolder: savedDirectory, canvas: hostURL) { events.append(event) }
        guard case let .done(saved, errors) = events.last else { Issue.record("no completion"); return }
        #expect(errors.isEmpty)
        let savedURL = try #require(saved.first)
        let original = try packageBytes(at: savedURL)
        var live = try CanvasDocument.read(from: hostURL)
        try live.archiveLinkedCanvases() // first save in an open Editor, without reopening it
        clock.withLock { $0 = created.addingTimeInterval(90 * 86_400) }
        try store.sweep()
        try store.sweep()
        #expect(try store.url(for: targetID) == nil)
        #expect(try store.url(for: hostID) == nil)
        #expect(try packageBytes(at: savedURL) == original)
        live.cornerRadius = 2 // a live edit made after the original sources expired
        let nextSave = try live.archiveLinkedCanvases()
        #expect(try CanvasDocument(fileWrapper: nextSave).cornerRadius == 2)
        var reopened = try CanvasDocument.read(from: savedURL)
        let savedHost = embedded ? try #require(reopened.embeddedCanvases["child.wadjet"]) : reopened
        guard case let .canvas(.embedded(name), _) = savedHost.layerStack.annotations[0].kind else {
            Issue.record("saved sources must use NestedCanvas.embedded"); return
        }
        #expect(savedHost.linkedCanvases.isEmpty)
        let source = try #require(savedHost.embeddedCanvases[name])
        #expect(source.layout == target.layout)
        #expect(source.displayImages[1]?.width == target.displayImages[1]?.width)
        #expect(try source.flatten(crop: CGRect(x: 32, y: 32, width: 16, height: 16)).width > 0)
        // The Editor can save the archived dependency again after History is gone.
        try reopened.archiveLinkedCanvases().write(to: savedURL, options: .atomic, originalContentsURL: nil)
        let edited = try CanvasDocument.read(from: savedURL)
        #expect((embedded ? edited.embeddedCanvases["child.wadjet"] : edited)?.embeddedCanvases[name] != nil)
    }

    // Proves an Editor's pending save is flushed before retention reads its
    // package, and deleting a presented package delivers deletion accommodation.
    @Test func sweepCoordinatesPresentedPackages() async throws {
        let directory = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_000_000)
        let clock = Mutex(created.addingTimeInterval(7 * 86_400))
        let store = CanvasStore(directory: directory, now: { clock.withLock { $0 } })
        let id = UUID()
        let url = try store.add(fixtureCanvas(), for: id, createdAt: created)
        let presenter = RetentionEditorPresenter(url: url)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        _ = try await Task.detached { try store.sweep() }.value
        #expect(try store.canvas(for: id)?.crop.width == 20)
        #expect(try !hasGainMap(at: url.appendingPathComponent("display-1.heic")))
        #expect(try store.sweep().isEmpty) // the Editor save and stage markers both survived
        clock.withLock { $0 = created.addingTimeInterval(90 * 86_400) }
        _ = try await Task.detached { try store.sweep() }.value
        #expect(presenter.deleted.withLock { $0 })
        #expect(try store.url(for: id) == nil)
    }

    // Proves root and embedded linking Annotations preserve whole displays for
    // recropping, even when those displays are outside the target's own crop.
    @Test(arguments: [false, true], [false, true])
    func linkedRecropKeepsItsDisplays(embedded: Bool, embeddedTarget: Bool) throws {
        let directory = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_000_000)
        let clock = Mutex(created)
        let store = CanvasStore(directory: directory, now: { clock.withLock { $0 } })
        var target = try fixtureCanvas()
        for id: UInt32 in [2, 3, 4] {
            target.layout.append(.init(id: id,
                frame: CGRect(x: Int(id - 1) * 100, y: 0, width: 64, height: 64), scaleFactor: 4))
            target.displayImages[id] = target.displayImages[1]
        }
        let id = UUID()
        let url = directory.appendingPathComponent("\(id).wadjet")
        if !embeddedTarget { try store.add(target, for: id, createdAt: created) }
        var host = try fixtureCanvas()
        let source: NestedCanvas
        if embeddedTarget {
            host.embeddedCanvases["target.wadjet"] = target
            source = .embedded("target.wadjet")
        } else {
            host.linkedCanvases = [CanvasLink(url: url)]
            source = .linked(CanvasLink(url: url))
        }
        host.layerStack = LayerStack([100, 200].map { x in
            Annotation(kind: .canvas(source,
                ImagePlacement(frame: host.crop, crop: CGRect(x: x + 4, y: 4, width: 8, height: 8))),
                style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 1))
        })
        if embedded {
            var root = try fixtureCanvas()
            root.embeddedCanvases = ["child.wadjet": host]
            host = root
        }
        let hostURL = try store.add(host, for: UUID(), createdAt: created)
        let targetURL = embeddedTarget
            ? hostURL.appendingPathComponent(embedded ? "embedded/child.wadjet/embedded/target.wadjet" : "embedded/target.wadjet")
            : url
        let settings = CanvasRetentionSettings(daysUntilDeletion: 0)
        clock.withLock { $0 = created.addingTimeInterval(6 * 86_400) }
        #expect(try store.sweep(settings: settings).isEmpty)
        #expect(try hasGainMap(at: targetURL.appendingPathComponent("display-1.heic")))
        clock.withLock { $0 = created.addingTimeInterval(7 * 86_400) }
        try store.sweep(settings: settings)
        #expect(try !hasGainMap(at: targetURL.appendingPathComponent("display-1.heic")))
        clock.withLock { $0 = created.addingTimeInterval(29 * 86_400) }
        #expect(try store.sweep(settings: settings).isEmpty)
        clock.withLock { $0 = created.addingTimeInterval(30 * 86_400) }
        try store.sweep(settings: settings)
        #expect(try CanvasDocument.read(from: targetURL).layout.map(\.id) == [1, 2, 3])
        #expect(FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("display-2.heic").path))
        #expect(FileManager.default.fileExists(atPath: targetURL.appendingPathComponent("display-3.heic").path))
    }

    // Proves persisted, configurable deadlines change real pixels/files exactly once,
    // prune each nested Canvas by its own crop/stroked Annotations, and leave History intact.
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
        var child = canvas
        child.crop.origin.x = 104
        var childStroke = stroke
        childStroke.kind = .line(start: CGPoint(x: 196, y: 10), end: CGPoint(x: 196, y: 40))
        child.layerStack = LayerStack([childStroke])
        var grandchild = canvas
        grandchild.crop.origin.x = 204
        var grandchildStroke = stroke
        grandchildStroke.kind = .line(start: CGPoint(x: 68, y: 10), end: CGPoint(x: 68, y: 40))
        grandchild.layerStack = LayerStack([grandchildStroke])
        child.embeddedCanvases = ["grandchild.wadjet": grandchild]
        canvas.embeddedCanvases = ["child.wadjet": child]
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
        let pruned = try #require(try reopenedStore.canvas(for: entry.id))
        let prunedChild = try #require(pruned.embeddedCanvases["child.wadjet"])
        #expect(prunedChild.layout.map(\.id) == [2, 3])
        #expect(prunedChild.embeddedCanvases["grandchild.wadjet"]?.layout.map(\.id) == [1, 3])
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("embedded/child.wadjet/display-1.heic").path))
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("embedded/child.wadjet/embedded/grandchild.wadjet/display-2.heic").path))
        #expect(try Data(contentsOf: displayURL) == once)
        let prunedBytes = try packageBytes(at: package)
        #expect(try reopenedStore.sweep(settings: settings).isEmpty)
        #expect(try packageBytes(at: package) == prunedBytes)
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

    // Proves the stage that drops unused displays keeps the display a Magnify
    // samples: its viewport reaches display 2 though every painted part —
    // source outline, leader, magnifier — stays on display 1.
    @Test @MainActor func magnifyViewportKeepsItsDisplay() throws {
        let directory = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_000_000)
        let clock = Mutex(created)
        let store = CanvasStore(directory: directory, now: { clock.withLock { $0 } })
        let history = try HistoryStore.inMemory()
        let entry = try history.record(kind: .screenshot, createdAt: created, file: nil)
        var canvas = try fixtureCanvas() // display 1 (0,0,64,64), crop (4,4,24,24)
        canvas.layout += [.init(id: 2, frame: CGRect(x: 64, y: 0, width: 64, height: 64), scaleFactor: 1)]
        canvas.displayImages[2] = canvas.displayImages[1]
        // the stroked source outline stays under x = 63; the 24 pt viewport
        // around its centre reaches x = 72, 8 pt onto display 2
        let m = Magnifier(source: CGRect(x: 58, y: 28, width: 4, height: 4),
                          frame: CGRect(x: 10, y: 4, width: 48, height: 48), zoom: 2,
                          options: .init(glass: false))
        canvas.layerStack = LayerStack([Annotation(kind: .magnify(m),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))])
        let package = try store.add(canvas, for: entry.id, createdAt: entry.createdAt)
        let settings = CanvasRetentionSettings(daysUntilSDRAndLossyHEIC: 10,
            daysUntilDroppingUnusedDisplays: 4, daysUntilDeletion: 20)
        clock.withLock { $0 = created.addingTimeInterval(4 * 86_400) }
        #expect(try store.sweep(settings: settings).flatMap(\.actions) == [.dropUnusedDisplays])
        #expect(try store.canvas(for: entry.id)?.layout.map(\.id) == [1, 2])
        #expect(FileManager.default.fileExists(atPath:
            package.appendingPathComponent("display-2.heic").path))
    }

    // Proves root and nested links use the newest root host's age and protect the
    // target through that host's deletion sweep; the next sweep deletes the orphan.
    @Test(arguments: [0, 1, 2]) func newestLinkControlsLifetimeAndDegradation(depth: Int) throws {
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
        for _ in 0..<depth {
            var parent = try fixtureCanvas()
            parent.embeddedCanvases = ["child.wadjet": host]
            host = parent
        }
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
        #expect(try store.sweep().flatMap(\.actions) == [.delete])
        #expect(try store.url(for: id) == nil)
        #expect(try packageBytes(at: saved) == original)
    }

    // Proves a damaged host's unreadable links cannot cause deletion of its target.
    @Test(arguments: [0, 1, 2]) func unreadableManifestAbortsBeforeDeletion(depth: Int) throws {
        let directory = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let store = CanvasStore(directory: directory, now: { now })
        let target = UUID()
        try store.add(fixtureCanvas(), for: target, createdAt: Date(timeIntervalSince1970: 0))
        var host = try fixtureCanvas()
        for _ in 0..<depth {
            var parent = try fixtureCanvas()
            parent.embeddedCanvases = ["child.wadjet": host]
            host = parent
        }
        var damagedURL = try store.add(host, for: UUID(), createdAt: now)
        for _ in 0..<depth { damagedURL.appendPathComponent("embedded/child.wadjet") }
        try Data("broken".utf8).write(to: damagedURL.appendingPathComponent("canvas.json"))
        #expect(throws: (any Error).self) { try store.sweep() }
        #expect(try store.url(for: target) != nil)
    }

    // Proves Run Workflow's new entry is independent: its own ID and package,
    // holding the Editor's changes while the source Canvas keeps none, with the
    // flattened PNG on disk at crop × outputScale pixels.
    @Test func runWorkflowFilesTheEditedCanvasAsItsOwnEntry() throws {
        let root = temporaryCanvasDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CanvasStore(directory: root.appendingPathComponent("Canvases"))
        let files = CaptureFiles(directory: root.appendingPathComponent("Captures"))
        let source = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 64, height: 64), scaleFactor: 2)],
            crop: CGRect(x: 4, y: 4, width: 12, height: 10), displayImages: [1: try sdrImage(size: 128)])
        let sourceID = UUID()
        let sourcePackage = try store.add(source, for: sourceID, createdAt: Date())

        var edited = try #require(try store.canvas(for: sourceID))
        edited.layerStack = LayerStack([Annotation(
            kind: .line(start: CGPoint(x: 4, y: 4), end: CGPoint(x: 16, y: 14)),
            style: .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2))])
        let shot = try store.addScreenshot(edited, files: files, createdAt: Date())

        #expect(shot.id != sourceID && shot.package != sourcePackage)
        #expect(try store.canvas(for: shot.id)?.layerStack.annotations.count == 1)
        #expect(try store.canvas(for: sourceID)?.layerStack.annotations.isEmpty == true)
        #expect(shot.file.pathExtension == "png")
        let image = try #require(CGImageSourceCreateWithURL(shot.file as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(CGSize(width: image.width, height: image.height)
            == edited.crop.size.applying(CGAffineTransform(scaleX: 2, y: 2)))
    }
}

/// A native file presenter with a pending crop edit, using the same save and
/// deletion callbacks NSDocument participates in, without opening app windows.
private final class RetentionEditorPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let deleted = Mutex(false)
    private let needsSave = Mutex(true)

    init(url: URL) {
        presentedItemURL = url
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func savePresentedItemChanges(completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            if needsSave.withLock({ pending in let save = pending; pending = false; return save }) {
                var canvas = try CanvasDocument.read(from: presentedItemURL!)
                canvas.crop.size.width = 20
                try canvas.write(to: presentedItemURL!)
            }
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        deleted.withLock { $0 = true }
        completionHandler(nil)
    }
}

private func sdrImage(size: Int) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return try #require(context.makeImage())
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
