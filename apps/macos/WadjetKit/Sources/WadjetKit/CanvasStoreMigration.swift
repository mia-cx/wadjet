import Foundation

/// What one migration run did, for the app log.
public struct CanvasMigrationReport: Sendable {
    public var moved: [CanvasMigrationMove] = []
    /// packages whose links were pointed at a moved Canvas
    public var relinked = 0
    public var failures: [String] = []
}

extension CanvasStore {
    /// Moves History's container Canvases (`<UUID>.wadjet` in `legacy`) into
    /// this store under their capture's date-based name, records each id in its
    /// canvas.json, and points every store package's links (root and embedded)
    /// at the moved Canvases. Safe to rerun: a package that fails stays in
    /// `legacy` for the next launch, and `legacy` is removed only once empty
    /// and every link is rewritten.
    /// Nothing outside `legacy` is moved or deleted.
    @discardableResult
    public func migrate(from legacy: URL) throws -> CanvasMigrationReport {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return CanvasMigrationReport() }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return try coordinateMutation {
            var report = CanvasMigrationReport()
            let present = try ownedPackages(packageURLs())
            var sources: [CanvasMigrationPlan.Source] = []
            for url in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      (try? isPackage(url)) == true else { continue }
                do {
                    guard let store = try manifest(at: url).store else { continue }
                    // a copy already here means an interrupted move: keep both, never delete
                    guard present[id] == nil else {
                        report.failures.append("\(url.lastPathComponent): already in \(directory.lastPathComponent)/")
                        continue
                    }
                    sources.append(.init(id: id, url: url, createdAt: store.createdAt))
                } catch {
                    report.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let moves = CanvasMigrationPlan.moves(sources, into: directory,
                taken: CaptureName.takenBaseNames(in: [directory]))
            for move in moves {
                do {
                    // the id goes in first: once renamed, the name no longer carries it
                    var manifest = try manifest(at: move.from)
                    manifest.store?.id = move.id
                    manifest.store?.name = move.to.lastPathComponent
                    try encode(manifest).write(to: move.from.appendingPathComponent("canvas.json"), options: .atomic)
                    try fm.moveItem(at: move.from, to: move.to)
                    report.moved.append(move)
                } catch {
                    report.failures.append("\(move.from.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // Relink every package, not just this run's moves, so a run that
            // stopped between moving and relinking finishes the job.
            let owned = try ownedPackages(packageURLs())
            let resolve: (UUID) -> URL? = { owned[$0]?.url }
            for package in owned.values {
                do {
                    if try relink(package.url, resolve: resolve) { report.relinked += 1 }
                } catch {
                    report.failures.append("relink \(package.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // the folder is the retry trigger: it goes only once every move and relink succeeded
            let left = (try? fm.contentsOfDirectory(atPath: legacy.path))?.filter { $0 != ".DS_Store" } ?? []
            if left.isEmpty, report.failures.isEmpty { try? fm.removeItem(at: legacy) }
            return report
        }
    }

    /// Rewrites links to a moved Canvas inside one package and its embedded
    /// Canvases. Returns whether anything changed.
    private func relink(_ package: URL, resolve: (UUID) -> URL?) throws -> Bool {
        var changed = false
        var manifest = try manifest(at: package)
        let links = manifest.linkedCanvases.map { CanvasLink.migrated($0, resolve: resolve) }
        if links != manifest.linkedCanvases {
            manifest.linkedCanvases = links
            try encode(manifest).write(to: package.appendingPathComponent("canvas.json"), options: .atomic)
            changed = true
        }
        let annotationsURL = package.appendingPathComponent("annotations.json")
        var stack = try LayerStack(json: Data(contentsOf: annotationsURL))
        var stackChanged = false
        for var annotation in stack.annotations {
            guard case let .canvas(.linked(link), placement) = annotation.kind else { continue }
            let moved = CanvasLink.migrated(link, resolve: resolve)
            guard moved != link else { continue }
            annotation.kind = .canvas(.linked(moved), placement)
            stack.replace(annotation)
            stackChanged = true
        }
        if stackChanged {
            try stack.json().write(to: annotationsURL, options: .atomic)
            changed = true
        }
        for path in manifest.embeddedCanvases {
            let child = package.appendingPathComponent(path)
            guard (try? isPackage(child)) == true else { continue }
            if try relink(child, resolve: resolve) { changed = true }
        }
        return changed
    }

    private func encode(_ manifest: CanvasDocument.Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}

extension CanvasLink {
    /// A link to a container Canvas (`<UUID>.wadjet`) that now lives elsewhere
    /// points there instead; any other link is returned unchanged. The bookmark
    /// is dropped with the old URL so nothing resolves to the stale location.
    static func migrated(_ link: CanvasLink, resolve: (UUID) -> URL?) -> CanvasLink {
        guard link.url.pathExtension == "wadjet",
              let id = UUID(uuidString: link.url.deletingPathExtension().lastPathComponent),
              let url = resolve(id), url.standardizedFileURL.path != link.url.standardizedFileURL.path
        else { return link }
        return CanvasLink(url: url)
    }
}
