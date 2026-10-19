import AppKit
import UniformTypeIdentifiers
import WadjetKit

/// One pasteboard item offers normal image formats to other apps and the whole
/// editable package to wadjet. Build it before replacing the user's clipboard.
@MainActor
enum CanvasClipboard {
    static func copyImage(_ file: URL, canvas: URL?) throws {
        let data = try Data(contentsOf: file)
        try write(image: data, heic: file.pathExtension.lowercased() == "heic",
            canvas: canvas.map { try CanvasDocument.read(from: $0).serializedPackage() },
            label: "<image+canvas \(file.lastPathComponent)>")
    }

    /// the Editor's Copy: the flattened image plus the live package
    static func copy(_ canvas: CanvasDocument) throws {
        let flat = try canvas.flatImage()
        try write(image: flat.data, heic: flat.type == .heic,
            canvas: canvas.serializedPackage(), label: "<image+canvas editor>")
    }

    private static func write(image data: Data, heic: Bool, canvas package: Data?, label: String) throws {
        let item = NSPasteboardItem()
        if heic {
            item.setData(data, forType: .init(UTType.heic.identifier))
        }
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        item.setData(png, forType: .png)
        if let package {
            item.setData(package, forType: .init(CanvasDocument.contentType.identifier))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
        AppState.shared.lastClipboard = label
    }
}
