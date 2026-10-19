import AppKit
import UniformTypeIdentifiers
import WadjetKit

/// Opens plain images as untitled Canvases, so Save can never write over the
/// image — the document types in Info.plist all route through here.
final class EditorDocumentController: NSDocumentController {
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        if typeName != CanvasDocument.contentType.identifier,
           UTType(typeName)?.conforms(to: .image) == true {
            let doc = try makeUntitledDocument(ofType: CanvasDocument.contentType.identifier)
            try (doc as! CanvasEditorDocument).load(image: url)
            return doc
        }
        return try super.makeDocument(withContentsOf: url, ofType: typeName)
    }
}
