import AppKit
import UniformTypeIdentifiers
import WadjetKit

/// One pasteboard item offers normal image formats to other apps and the whole
/// editable package to wadjet. Build it before replacing the user's clipboard.
@MainActor
enum CanvasClipboard {
    /// the History package URL the copy belongs to, so a wadjet paste can link it
    nonisolated static let linkType = NSPasteboard.PasteboardType("cx.mia.wadjet.canvas-link")
    static let packageType = NSPasteboard.PasteboardType(CanvasDocument.contentType.identifier)

    /// A Screenshot's Copy image: the image goes on the pasteboard at once. Its
    /// Canvas is still being written, so the package and link join the same
    /// item once it's on disk, unless something else was copied meanwhile.
    static func copyImage(_ file: URL, canvas: Task<URL, any Error>?) throws {
        let copied = try write(image: Data(contentsOf: file), heic: file.pathExtension.lowercased() == "heic",
            canvas: nil, label: "<image \(file.lastPathComponent)>")
        guard let canvas else { return }
        Task {
            do {
                let url = try await canvas.value
                let package = try await Task.detached { try CanvasDocument.read(from: url).serializedPackage() }.value
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount == copied else { return }
                pasteboard.addTypes([packageType, linkType], owner: nil)
                pasteboard.setData(package, forType: packageType)
                pasteboard.setString(url.absoluteString, forType: linkType)
                AppState.shared.lastClipboard = "<image+canvas \(file.lastPathComponent)>"
            } catch {
                AppLog.line("copy image: Canvas not added: \(error.localizedDescription)")
            }
        }
    }

    /// the Editor's Copy: the flattened image plus the live package; `link` is
    /// the document's file URL, so a wadjet paste can link that package
    static func copy(_ canvas: CanvasDocument, link: URL? = nil) throws {
        let flat = try canvas.flatImage()
        try write(image: flat.data, heic: flat.type == .heic,
            canvas: canvas.serializedPackage(), link: link, label: "<image+canvas editor>")
    }

    /// Replaces the pasteboard with one item; returns its change count. `data`
    /// is HEIC or PNG — flatImage's two outputs — and only HEIC is re-encoded.
    @discardableResult
    private static func write(image data: Data, heic: Bool, canvas package: Data?,
                              link: URL? = nil, label: String) throws -> Int {
        let item = NSPasteboardItem()
        var png = data
        if heic {
            item.setData(data, forType: .init(UTType.heic.identifier))
            guard let rep = NSBitmapImageRep(data: data),
                  let encoded = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            png = encoded
        }
        item.setData(png, forType: .png)
        if let package {
            item.setData(package, forType: packageType)
            if let link { item.setString(link.absoluteString, forType: linkType) }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
        AppState.shared.lastClipboard = label
        return pasteboard.changeCount
    }
}
