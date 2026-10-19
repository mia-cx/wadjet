import Foundation

extension CanvasDocument {
    /// A saved Canvas keeps full copies of its linked sources, so History can
    /// expire without breaking later recrops. Cyclic or unreadable dependencies
    /// fail the save before replacing any existing package.
    public func savedFileWrapper() throws -> FileWrapper {
        try Self.preservingLinks(in: fileWrapper(), visiting: [])
    }

    /// Copies an existing package with its full linked sources, preserving image
    /// bytes. The History directory read prevents retention from deleting a
    /// dependency between reading the host and archiving its sources.
    static func saveCopy(from source: URL, to destination: URL) throws {
        var outcome: Result<Void, Error>?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source.deletingLastPathComponent(),
            options: .withoutChanges, error: &error) { _ in
            outcome = Result {
                let wrapper = try preservedPackage(at: source, visiting: [])
                try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
            }
        }
        if let error { throw error }
        try outcome!.get()
    }

    private static func preservedPackage(at url: URL, visiting: Set<URL>) throws -> FileWrapper {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard !visiting.contains(url) else { throw CanvasDocumentError.invalidPackage("cyclic Canvas link") }
        var outcome: Result<FileWrapper, Error>?
        var error: NSError?
        // Take the store-directory read before a package read: retention's
        // batched writer must not get between this source and its dependencies.
        NSFileCoordinator().coordinate(readingItemAt: url.deletingLastPathComponent(),
            options: .withoutChanges, error: &error) { _ in
            outcome = Result {
                var reading: Result<FileWrapper, Error>?
                var readingError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                    error: &readingError) { url in
                    reading = Result {
                        try preservingLinks(in: FileWrapper(url: url, options: .immediate),
                            visiting: visiting.union([url]))
                    }
                }
                if let readingError { throw readingError }
                return try reading!.get()
            }
        }
        if let error { throw error }
        return try outcome!.get()
    }

    private static func preservingLinks(in wrapper: FileWrapper, visiting: Set<URL>) throws -> FileWrapper {
        guard let data = wrapper.fileWrappers?["canvas.json"]?.regularFileContents,
              let annotations = wrapper.fileWrappers?["annotations.json"]?.regularFileContents else {
            throw CanvasDocumentError.invalidPackage("Canvas metadata")
        }
        var manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == version else { throw CanvasDocumentError.unsupportedVersion(manifest.version) }
        let embedded = wrapper.fileWrappers?["embedded"] ?? FileWrapper(directoryWithFileWrappers: [:])
        if wrapper.fileWrappers?["embedded"] == nil {
            embedded.preferredFilename = "embedded"
            wrapper.addFileWrapper(embedded)
        }
        // Archive dependencies inside existing embedded hosts as well.
        for child in (embedded.fileWrappers ?? [:]).values {
            _ = try preservingLinks(in: child, visiting: visiting)
        }
        let links = manifest.linkedCanvases + (try LayerStack(json: annotations)).annotations.compactMap {
            if case let .canvas(link, _) = $0.kind { return link }
            return nil
        }
        var preserved = manifest.preservedLinks ?? [:]
        for link in links where !preserved.values.contains(where: { $0.url == link.url }) {
            let child = try preservedPackage(at: link.url, visiting: visiting)
            let name = "linked-\(UUID().uuidString).wadjet"
            child.preferredFilename = name
            embedded.addFileWrapper(child)
            manifest.embeddedCanvases.append("embedded/\(name)")
            preserved[name] = link
        }
        manifest.preservedLinks = preserved.isEmpty ? nil : preserved
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        wrapper.removeFileWrapper(wrapper.fileWrappers!["canvas.json"]!)
        let file = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        file.preferredFilename = "canvas.json"
        wrapper.addFileWrapper(file)
        return wrapper
    }
}
