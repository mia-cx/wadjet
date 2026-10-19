import AppKit
import UniformTypeIdentifiers
import WadjetKit

/// One pasteboard item offers normal image formats to other apps and the whole
/// editable package to wadjet. Build it before replacing the user's clipboard.
@MainActor
enum CanvasClipboard {
    static func copyImage(_ file: URL, canvas: URL?) throws {
        let data = try Data(contentsOf: file)
        let item = NSPasteboardItem()
        if file.pathExtension.lowercased() == "heic" {
            item.setData(data, forType: .init(UTType.heic.identifier))
        }
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        item.setData(png, forType: .png)
        if let canvas {
            item.setData(try CanvasDocument.read(from: canvas).serializedPackage(),
                forType: .init(CanvasDocument.contentType.identifier))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
        AppState.shared.lastClipboard = "<image+canvas \(file.lastPathComponent)>"
    }
}
