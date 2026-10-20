import CoreGraphics
import Foundation
import Synchronization

/// Persisted in canvas.json, independently of filesystem creation/modification dates.
/// `id` is the History entry's; packages from before it existed carry it in their name.
struct CanvasStoreMetadata: Codable {
    var createdAt: Date
    var state: CanvasRetentionState = []
    var id: UUID?
}

/// Owns History's .wadjet packages in one directory, the screenshots folder's
/// `original/`. Packages are named by capture date and found by the History
/// id in their canvas.json. Save file copies carry no store metadata, so the
/// store never owns them; links never grant it another directory.
/// Store mutations coordinate directory access with each other and NSDocument
/// Editors, so a background sweep cannot overwrite a simultaneous package save.
public struct CanvasStore: Sendable {
    public let directory: URL
    /// ImageIO quality used for the irreversible lossy retention stage.
    public static let lossyHEICQuality = 0.65
    private let now: @Sendable () -> Date
    private let index = Index()

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory.standardizedFileURL
        self.now = now
    }

    /// id → package, rebuilt when the directory's entries change, so lookups
    /// for Recordings and deleted Canvases don't rescan every manifest.
    private final class Index: Sendable {
        let state = Mutex<(stamp: Date?, urls: [UUID: URL])>((nil, [:]))
    }

    /// Adds a new History Canvas, using the entry's ID and capture date. Existing
    /// entries are never overwritten; Editor changes can write to the returned URL.
    /// Named `name`, else by `createdAt` (`Wadjet 2026-10-20 at 12.30.00.wadjet`),
    /// with ` 2`, ` 3`, … when the name is taken.
    @discardableResult
    public func add(_ canvas: CanvasDocument, for entryID: UUID, createdAt: Date,
                    name: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try coordinateMutation {
            guard try url(for: entryID) == nil else { throw CocoaError(.fileWriteFileExists) }
            let taken = CaptureName.takenBaseNames(in: [directory])
            let base = CaptureName.unique(name ?? CaptureName.base(for: createdAt), isTaken: taken.contains)
            let url = directory.appendingPathComponent("\(base).wadjet", isDirectory: false)
            var canvas = canvas
            canvas.storeMetadata = CanvasStoreMetadata(createdAt: createdAt, id: entryID)
            try canvas.write(to: url)
            return url
        }
    }

    /// Finds an owned Canvas while its package still exists. History outlives it.
    public func url(for entryID: UUID) throws -> URL? {
        let stamp = directoryStamp()
        let (cached, fresh) = index.state.withLock { ($0.urls[entryID], $0.stamp == stamp && stamp != nil) }
        if let cached, (try? ownedID(at: cached)) == entryID { return cached }
        guard !fresh, stamp != nil else { return nil }
        let urls = try ownedPackages(packageURLs()).mapValues(\.url)
        index.state.withLock { $0 = (stamp, urls) }
        return urls[entryID]
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
    /// Awaits file presenters and performs package IO on a utility queue.
    @discardableResult
    public func sweep(settings: CanvasRetentionSettings = .init()) async throws -> [CanvasRetentionDecision] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        // A plain directory writer does not lock its children. Acquire every
        // actual package in one batch, awaiting access without blocking Swift's
        // cooperative executor or nesting one lock frame per History entry.
        while true {
            let urls = try packageURLs()
            guard !urls.isEmpty else { return [] }
            let intents = [NSFileAccessIntent.writingIntent(with: directory, options: [])]
                + urls.map { NSFileAccessIntent.writingIntent(with: $0, options: .forMerging) }
            let decisions: [CanvasRetentionDecision]? = try await withCheckedThrowingContinuation { continuation in
                // Only the granted accessor uses this coordinator after the
                // asynchronous request has been scheduled.
                nonisolated(unsafe) let coordinator = NSFileCoordinator()
                coordinator.coordinate(with: intents, queue: Self.sweepQueue) { error in
                    continuation.resume(with: Result {
                        if let error { throw error }
                        func paths(_ urls: [URL]) -> Set<String> {
                            Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
                        }
                        // An add may have won the directory before access was
                        // granted. Retry including the new package in the batch.
                        guard try paths(packageURLs()) == paths(intents.dropFirst().map(\.url)) else { return nil }
                        return try sweepCoordinated(settings: settings, coordinator: coordinator)
                    })
                }
            }
            if let decisions { return decisions }
        }
    }

    private static let sweepQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Canvas retention"
        queue.qualityOfService = .utility
        return queue
    }()

    func packageURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter(isPackage)
            .sorted { $0.path < $1.path }
    }

    private func directoryStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
    }

    /// The History id a package belongs to: its metadata's, else its legacy UUID name.
    func ownedID(at url: URL, manifest: CanvasDocument.Manifest? = nil) throws -> UUID? {
        guard try isPackage(url), let store = try (manifest ?? self.manifest(at: url)).store else { return nil }
        return store.id ?? UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    /// The store's packages by id. A Finder duplicate carries its original's id;
    /// the earliest-created package keeps it and the copies stay unowned, so
    /// retention never touches them. A package without metadata isn't History's.
    /// `strict` throws on an unreadable package, as retention needs; lookups skip
    /// it, so one damaged file in the folder can't hide every other Canvas.
    func ownedPackages(_ urls: [URL], strict: Bool = false) throws
        -> [UUID: (url: URL, manifest: CanvasDocument.Manifest, created: Date)] {
        var owned: [UUID: (url: URL, manifest: CanvasDocument.Manifest, created: Date)] = [:]
        for url in urls {
            let manifest: CanvasDocument.Manifest
            do { manifest = try self.manifest(at: url) } catch {
                if strict { throw error }
                continue
            }
            guard let id = try ownedID(at: url, manifest: manifest) else { continue }
            let created = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate]
                as? Date ?? .distantFuture
            if let other = owned[id], (other.created, other.url.path) <= (created, url.path) { continue }
            // the same form `add` returns: enumeration adds a trailing slash to packages
            owned[id] = (directory.appendingPathComponent(url.lastPathComponent, isDirectory: false), manifest, created)
        }
        return owned
    }

    private func sweepCoordinated(settings: CanvasRetentionSettings,
                                  coordinator: NSFileCoordinator) throws -> [CanvasRetentionDecision] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        var records: [CanvasRetentionRecord] = []
        var packages: [UUID: URL] = [:]
        var links: [UUID: [CanvasLink]] = [:]
        var linkedCrops: [String: [CGRect]] = [:]
        for (id, package) in try ownedPackages(packageURLs(), strict: true).sorted(by: { $0.value.url.path < $1.value.url.path }) {
            guard let metadata = package.manifest.store else { continue }
            packages[id] = package.url
            links[id] = try linkedCanvases(in: package.manifest, at: package.url, crops: &linkedCrops)
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

    func manifest(at url: URL) throws -> CanvasDocument.Manifest {
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
        var links = manifest.linkedCanvases
        let stack = try LayerStack(json: Data(contentsOf: url.appendingPathComponent("annotations.json")))
        for annotation in stack.annotations {
            switch annotation.kind {
            case let .canvas(.embedded(name), placement):
                crops[url.appendingPathComponent("embedded/\(name)").standardizedFileURL.path, default: []]
                    .append(placement.crop)
            case let .canvas(.linked(link), placement):
                links.append(link)
                crops[link.url.standardizedFileURL.path, default: []].append(placement.crop)
            default: break
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

    func isPackage(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return url.pathExtension == "wadjet" && values.isDirectory == true && values.isSymbolicLink != true
    }

    // Coordinate the directory, including link planning, rather than separate
    // packages: adding a newer linker must not race deletion of its target.
    func coordinateMutation<T>(_ operation: () throws -> T) throws -> T {
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
