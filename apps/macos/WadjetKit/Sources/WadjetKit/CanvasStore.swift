import CoreGraphics
import Foundation
import Synchronization

/// Persisted in canvas.json, independently of filesystem creation/modification dates.
struct CanvasStoreMetadata: Codable {
    var createdAt: Date
    var state: CanvasRetentionState = []
}

/// Owns History's UUID-named .wadjet packages in one directory. Save file copies live
/// elsewhere; links never grant this store ownership of another directory.
/// Store mutations coordinate directory access with each other and NSDocument
/// Editors, so a background sweep cannot overwrite a simultaneous package save.
public struct CanvasStore: Sendable {
    public let directory: URL
    /// ImageIO quality used for the irreversible lossy retention stage.
    public static let lossyHEICQuality = 0.65
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory.standardizedFileURL
        self.now = now
    }

    /// Adds a new History Canvas, using the entry's ID and capture date. Existing
    /// entries are never overwritten; Editor changes can write to the returned URL.
    @discardableResult
    public func add(_ canvas: CanvasDocument, for entryID: UUID, createdAt: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try coordinateMutation {
            let url = packageURL(for: entryID)
            guard !fm.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
            var canvas = canvas
            canvas.storeMetadata = CanvasStoreMetadata(createdAt: createdAt)
            try canvas.write(to: url)
            return url
        }
    }

    /// Finds an owned Canvas while its package still exists. History outlives it.
    public func url(for entryID: UUID) throws -> URL? {
        let url = packageURL(for: entryID)
        guard FileManager.default.fileExists(atPath: url.path), try isPackage(url),
              try manifest(at: url).store != nil else { return nil }
        return url
    }

    /// Opens a History Canvas without resolving any of its links.
    public func canvas(for entryID: UUID) throws -> CanvasDocument? {
        guard let url = try url(for: entryID) else { return nil }
        return try CanvasDocument.read(from: url)
    }

    /// Plans from on-disk metadata and links, then atomically replaces each changed
    /// package with its completed stages. A failed package is left intact; other
    /// decisions still run and failures surface together. An unreadable manifest
    /// aborts planning, because its links may protect another package from deletion.
    /// Blocks for file presenters; run off the main thread in an app with Editors.
    @discardableResult
    public func sweep(settings: CanvasRetentionSettings = .init()) throws -> [CanvasRetentionDecision] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        // A plain directory writer does not lock its children. Acquire the
        // directory (for additions) and every actual package in one batch, so
        // Editor saves finish before link planning and cannot race its commits.
        while true {
            let urls = try packageURLs()
            let intents = [NSFileAccessIntent.writingIntent(with: directory, options: [])]
                + urls.map { NSFileAccessIntent.writingIntent(with: $0, options: .forMerging) }
            let result = Mutex<Result<[CanvasRetentionDecision]?, Error>?>(nil)
            let finished = DispatchSemaphore(value: 0)
            // The accessor exclusively uses this coordinator after the batch
            // is granted; no other thread calls it during the operation.
            nonisolated(unsafe) let coordinator = NSFileCoordinator()
            let queue = OperationQueue()
            coordinator.coordinate(with: intents, queue: queue) { error in
                defer { finished.signal() }
                let outcome = Result<[CanvasRetentionDecision]?, Error> {
                    if let error { throw error }
                    let granted = intents.dropFirst().map(\.url)
                    // An add may have won the directory before the batch was
                    // granted. Retry with that new package included in the lock.
                    func paths(_ urls: [URL]) -> Set<String> {
                        Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
                    }
                    guard try paths(packageURLs()) == paths(Array(granted)) else { return nil }
                    return try sweepCoordinated(settings: settings, coordinator: coordinator)
                }
                result.withLock { $0 = outcome }
            }
            withExtendedLifetime(queue) { finished.wait() }
            if let decisions = try result.withLock({ try $0!.get() }) { return decisions }
        }
    }

    private func packageURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return false }
                return try isPackage(url)
            }
            .sorted { $0.path < $1.path }
    }

    private func sweepCoordinated(settings: CanvasRetentionSettings,
                                  coordinator: NSFileCoordinator) throws -> [CanvasRetentionDecision] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted { $0.path < $1.path }
        var records: [CanvasRetentionRecord] = []
        var packages: [UUID: URL] = [:]
        var links: [UUID: [CanvasLink]] = [:]
        var linkedCrops: [String: [CGRect]] = [:]
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  try isPackage(url) else { continue }
            let manifest = try manifest(at: url)
            guard let metadata = manifest.store else { continue }
            packages[id] = url.standardizedFileURL
            links[id] = try linkedCanvases(in: manifest, at: url, crops: &linkedCrops)
            records.append(.init(id: id, createdAt: metadata.createdAt, state: metadata.state))
        }
        // Directory enumeration adds a trailing slash; file URL equality would
        // otherwise miss links created from add's returned package URL.
        let idsByPath = Dictionary(uniqueKeysWithValues: packages.map { ($0.value.path, $0.key) })
        for index in records.indices {
            records[index].linkedCanvasIDs = Set(links[records[index].id, default: []].compactMap {
                idsByPath[$0.url.standardizedFileURL.path]
            })
        }
        let decisions = CanvasRetentionPolicy(now: now).actionsDue(for: records, settings: settings)
        var failures: [Error] = []
        for decision in decisions {
            do {
                let url = packages[decision.canvasID]!
                if decision.actions == [.delete] {
                    var deletionError: NSError?
                    var deletion: Result<Void, Error>?
                    coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &deletionError) { url in
                        deletion = Result { try fm.removeItem(at: url) }
                    }
                    if let deletionError { throw deletionError }
                    try deletion!.get()
                } else {
                    try apply(decision.actions, to: url, linkedCrops: linkedCrops)
                }
            } catch { failures.append(error) }
        }
        if let first = failures.first {
            throw failures.count == 1 ? first : NSError(domain: "wadjet", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Canvas sweep: \(failures.count) packages failed: \(first.localizedDescription)",
                NSUnderlyingErrorKey: first,
            ])
        }
        return decisions
    }

    private func apply(_ actions: [CanvasRetentionAction], to url: URL,
                       linkedCrops: [String: [CGRect]]) throws {
        let wrapper = try FileWrapper(url: url, options: .immediate)
        let canvas = try CanvasDocument(fileWrapper: wrapper)
        var manifest = try manifest(at: url)
        guard var metadata = manifest.store else { return }
        let sdr = actions.contains(.convertToSDR), lossy = actions.contains(.reencodeLossyHEIC)
        if sdr || lossy {
            try degrade(canvas, in: wrapper, sdr: sdr,
                quality: lossy || metadata.state.contains(.lossyHEIC) ? Self.lossyHEICQuality : 1)
        }
        if actions.contains(.dropUnusedDisplays) {
            try dropUnusedDisplays(canvas, at: url, in: wrapper, manifest: &manifest, linkedCrops: linkedCrops)
            metadata.state.insert(.unusedDisplaysDropped)
        }
        if sdr { metadata.state.insert(.sdr) }
        if lossy { metadata.state.insert(.lossyHEIC) }
        manifest.store = metadata
        try replaceManifest(manifest, in: wrapper)
        // Image bytes and stage markers commit together; a failed write can be retried.
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
    }

    private func degrade(_ canvas: CanvasDocument, in wrapper: FileWrapper, sdr: Bool, quality: Double) throws {
        let images = canvas.layout.map { ($0.imageFileName, canvas.displayImages[$0.id]!) }
            + canvas.windowLayers.map { ($0.imageFileName, $0.image) }
        for (name, image) in images {
            let output = try sdr ? CanvasImageCodec.sdr(image) : image
            replace(name, with: try CanvasImageCodec.heic(output, quality: quality), in: wrapper)
        }
        // PNG assets are already SDR; only the HEIC ones degrade
        if let assets = wrapper.fileWrappers?["images"] {
            for (name, _) in assets.fileWrappers ?? [:] where name.hasSuffix(".heic") {
                guard let asset = UUID(uuidString: String(name.dropLast(5))),
                      let image = canvas.images[asset] else { continue }
                let output = try sdr ? CanvasImageCodec.sdr(image) : image
                replace(name, with: try CanvasImageCodec.heic(output, quality: quality), in: assets)
            }
        }
        for (name, child) in canvas.embeddedCanvases {
            try degrade(child, in: wrapper.fileWrappers!["embedded"]!.fileWrappers![name]!, sdr: sdr, quality: quality)
        }
    }

    private func dropUnusedDisplays(_ canvas: CanvasDocument, at url: URL, in wrapper: FileWrapper,
                                    manifest: inout CanvasDocument.Manifest,
                                    linkedCrops: [String: [CGRect]]) throws {
        // a display stays while it paints the canvas, an Annotation's coverage,
        // or the source pixels one samples — a Magnify's viewport may sit
        // wholly on a display its magnifier doesn't touch
        let bounds = canvas.layerStack.annotations.flatMap {
            [PathGeometry.coverage(for: $0).boundingBoxOfPath] + ($0.sampledRect.map { [$0] } ?? [])
        } + linkedCrops[url.standardizedFileURL.path, default: []]
        // Keep each touched display in full: a pasted Canvas can recrop beyond
        // its current Annotation crop to any other part of that display.
        manifest.layout.removeAll { display in
            guard !touches(display.frame, canvas.crop),
                  !bounds.contains(where: { touches(display.frame, $0) }) else { return false }
            wrapper.removeFileWrapper(wrapper.fileWrappers![display.imageFileName]!)
            return true
        }
        for (name, child) in canvas.embeddedCanvases {
            let childWrapper = wrapper.fileWrappers!["embedded"]!.fileWrappers![name]!
            var childManifest = try JSONDecoder().decode(CanvasDocument.Manifest.self,
                from: childWrapper.fileWrappers!["canvas.json"]!.regularFileContents!)
            try dropUnusedDisplays(child, at: url.appendingPathComponent("embedded/\(name)"),
                in: childWrapper, manifest: &childManifest, linkedCrops: linkedCrops)
            try replaceManifest(childManifest, in: childWrapper)
        }
    }

    private func replaceManifest(_ manifest: CanvasDocument.Manifest, in wrapper: FileWrapper) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        replace("canvas.json", with: try encoder.encode(manifest), in: wrapper)
    }

    private func manifest(at url: URL) throws -> CanvasDocument.Manifest {
        let file = try FileWrapper(url: url.appendingPathComponent("canvas.json"), options: .immediate)
        guard file.isRegularFile, let data = file.regularFileContents else {
            throw CanvasDocumentError.invalidPackage("canvas.json")
        }
        let manifest = try JSONDecoder().decode(CanvasDocument.Manifest.self, from: data)
        guard manifest.version == CanvasDocument.version else {
            throw CanvasDocumentError.unsupportedVersion(manifest.version)
        }
        return manifest
    }

    // Embedded Canvases age with their root package, so their links are root edges too.
    // Read all required metadata before planning any destructive action.
    private func linkedCanvases(in manifest: CanvasDocument.Manifest, at url: URL,
                                crops: inout [String: [CGRect]]) throws -> [CanvasLink] {
        let preserved = manifest.preservedLinks ?? [:]
        var links = manifest.linkedCanvases.filter { link in
            !preserved.values.contains(where: { $0.url == link.url })
        }
        let stack = try LayerStack(json: Data(contentsOf: url.appendingPathComponent("annotations.json")))
        for annotation in stack.annotations {
            guard case let .canvas(link, placement) = annotation.kind else { continue }
            if let name = preserved.first(where: { $0.value.url == link.url })?.key {
                crops[url.appendingPathComponent("embedded/\(name)").standardizedFileURL.path, default: []]
                    .append(placement.crop)
            } else {
                links.append(link)
                crops[link.url.standardizedFileURL.path, default: []].append(placement.crop)
            }
        }
        for path in manifest.embeddedCanvases {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "embedded", parts[1] != ".", parts[1] != "..",
                  !path.contains("\0") else { throw CanvasDocumentError.invalidPackage(path) }
            let embedded = url.appendingPathComponent("embedded")
            let values = try embedded.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let child = url.appendingPathComponent(path)
            guard values.isDirectory == true, values.isSymbolicLink != true, try isPackage(child) else {
                throw CanvasDocumentError.invalidPackage(path)
            }
            links += try linkedCanvases(in: self.manifest(at: child), at: child, crops: &crops)
        }
        return links
    }

    private func isPackage(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return url.pathExtension == "wadjet" && values.isDirectory == true && values.isSymbolicLink != true
    }

    private func packageURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("wadjet")
    }

    // Coordinate the directory, including link planning, rather than separate
    // packages: adding a newer linker must not race deletion of its target.
    private func coordinateMutation<T>(_ operation: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: directory, options: [], error: &error) { _ in
            result = Result { try operation() }
        }
        if let error { throw error }
        return try result!.get()
    }

    private func replace(_ name: String, with data: Data, in wrapper: FileWrapper) {
        if let old = wrapper.fileWrappers?[name] { wrapper.removeFileWrapper(old) }
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        wrapper.addFileWrapper(file)
    }

    private func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        !b.isNull && a.maxX >= b.minX && b.maxX >= a.minX && a.maxY >= b.minY && b.maxY >= a.minY
    }
}
