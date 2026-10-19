import Foundation

extension CanvasDocument {
    /// Returns a permanent package whose linked Annotations use embedded full
    /// sources. Retains those sources in memory for later saves in the same
    /// Editor session, without pruning the live pixels needed by Undo.
    @discardableResult
    public mutating func archiveLinkedCanvases() throws -> FileWrapper {
        var retained: [URL: CanvasDocument] = [:]
        let wrapper = try Self.preservingLinks(in: fileWrapper(), known: self,
            visiting: [], retained: &retained)
        retainSources(retained)
        return wrapper
    }

    // Live Annotations and undo snapshots keep their original linked identities;
    // saved Annotations use NestedCanvas.embedded. No second persisted link model.
    private mutating func retainSources(_ sources: [URL: CanvasDocument]) {
        linkedDocuments.merge(sources) { _, archived in archived }
        for name in embeddedCanvases.keys { embeddedCanvases[name]?.retainSources(sources) }
    }

    /// Copies a package and full dependencies without reencoding its image bytes.
    /// The parent read keeps retention out while traversing History dependencies.
    static func saveCopy(from source: URL, to destination: URL) throws {
        var outcome: Result<Void, Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source.deletingLastPathComponent(),
            options: .withoutChanges, error: &error) { _ in
            outcome = Result {
                var retained: [URL: CanvasDocument] = [:]
                let wrapper = try preservedPackage(at: source, known: nil, visiting: [], retained: &retained)
                try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
            }
        }
        if let error { throw error }
        try outcome!.get()
    }

    private static func preservedPackage(at url: URL, known: CanvasDocument?, visiting: Set<URL>,
                                          retained: inout [URL: CanvasDocument]) throws -> FileWrapper {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard !visiting.contains(canonical) else { throw CanvasDocumentError.invalidPackage("cyclic Canvas link") }
        let visiting = visiting.union([canonical])
        // Prefer the pixels pasted into this session, including unsaved Editor
        // copies and sources already archived before History expired.
        if let known {
            return try preservingLinks(in: known.fileWrapper(), known: known, visiting: visiting, retained: &retained)
        }
        var outcome: Result<FileWrapper, Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url.deletingLastPathComponent(),
            options: .withoutChanges, error: &error) { _ in
            outcome = Result {
                var reading: Result<FileWrapper, Error>?
                var readingError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                    error: &readingError) { url in
                    reading = Result {
                        try preservingLinks(in: FileWrapper(url: url, options: .immediate), known: nil,
                            visiting: visiting, retained: &retained)
                    }
                }
                if let readingError { throw readingError }
                return try reading!.get()
            }
        }
        if let error { throw error }
        return try outcome!.get()
    }

    private static func preservingLinks(in wrapper: FileWrapper, known: CanvasDocument?, visiting: Set<URL>,
                                         retained: inout [URL: CanvasDocument]) throws -> FileWrapper {
        guard let data = wrapper.fileWrappers?["canvas.json"]?.regularFileContents,
              let annotations = wrapper.fileWrappers?["annotations.json"]?.regularFileContents else {
            throw CanvasDocumentError.invalidPackage("Canvas metadata")
        }
        var manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == version else { throw CanvasDocumentError.unsupportedVersion(manifest.version) }
        var stack = try LayerStack(json: annotations)
        let embedded = wrapper.fileWrappers?["embedded"] ?? FileWrapper(directoryWithFileWrappers: [:])
        if wrapper.fileWrappers?["embedded"] == nil {
            embedded.preferredFilename = "embedded"
            wrapper.addFileWrapper(embedded)
        }
        for (name, child) in embedded.fileWrappers ?? [:] {
            _ = try preservingLinks(in: child, known: known?.embeddedCanvases[name],
                visiting: visiting, retained: &retained)
        }
        let links = manifest.linkedCanvases + stack.annotations.compactMap {
            if case let .canvas(.linked(link), _) = $0.kind { return link }
            return nil
        }
        var names: [URL: String] = [:]
        for link in links where names[link.url] == nil {
            let child = try preservedPackage(at: link.url, known: known?.linkedDocuments[link.url],
                visiting: visiting, retained: &retained)
            let name = "linked-\(UUID().uuidString).wadjet"
            child.preferredFilename = name
            embedded.addFileWrapper(child)
            manifest.embeddedCanvases.append("embedded/\(name)")
            names[link.url] = name
            retained[link.url] = try CanvasDocument(fileWrapper: child)
        }
        for var annotation in stack.annotations {
            guard case let .canvas(.linked(link), placement) = annotation.kind else { continue }
            annotation.kind = .canvas(.embedded(names[link.url]!), placement)
            stack.replace(annotation)
        }
        manifest.linkedCanvases = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        replace("canvas.json", with: try encoder.encode(manifest), in: wrapper)
        replace("annotations.json", with: try stack.json(), in: wrapper)
        return wrapper
    }

    private static func replace(_ name: String, with data: Data, in wrapper: FileWrapper) {
        if let old = wrapper.fileWrappers?[name] { wrapper.removeFileWrapper(old) }
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        wrapper.addFileWrapper(file)
    }
}
