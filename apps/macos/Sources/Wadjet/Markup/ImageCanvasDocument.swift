import AppKit
import WadjetKit

extension CanvasEditorDocument {
    /// ⌘S on an opened image writes the Canvas beside it as a related item —
    /// the image itself is never touched. A refusal (no sandbox grant) falls
    /// back to the Save panel.
    override func save(_ sender: Any?) {
        if fileURL == nil, let image = sourceImage {
            let sibling = image.deletingPathExtension().appendingPathExtension("wadjet")
            if !FileManager.default.fileExists(atPath: sibling.path) {
                do {
                    try writeSibling(sibling, of: image)
                    AppLog.line("editor: saved \(sibling.lastPathComponent) beside its image (related item)")
                    return
                } catch {
                    AppLog.line("editor: related-item save refused (\(error)); asking with a Save panel")
                }
            }
        }
        super.save(sender)
    }

    /// an untitled image Canvas starts its Save panel beside the source
    override func prepareSavePanel(_ panel: NSSavePanel) -> Bool {
        if fileURL == nil, let image = sourceImage {
            panel.directoryURL = image.deletingLastPathComponent()
            panel.nameFieldStringValue = image.deletingPathExtension().lastPathComponent + ".wadjet"
        }
        return super.prepareSavePanel(panel)
    }

    /// Writes the package beside `image` through NSFileCoordinator — the
    /// sandbox grants the sibling write because the document opened the image
    /// (NSIsRelatedItemType). The presenter is then kept, holding that access
    /// for later autosaves.
    func writeSibling(_ sibling: URL, of image: URL) throws {
        let presenter = SiblingPresenter(primary: image, sibling: sibling)
        NSFileCoordinator.addFilePresenter(presenter)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: sibling,
            options: .forReplacing, error: &coordinatorError) { url in
            do {
                try fileWrapper(ofType: CanvasDocument.contentType.identifier)
                    .write(to: url, options: [], originalContentsURL: nil)
            } catch { writeError = error }
        }
        if let error = writeError ?? coordinatorError {
            NSFileCoordinator.removeFilePresenter(presenter)
            throw error
        }
        siblingPresenter = presenter
        fileType = CanvasDocument.contentType.identifier
        fileURL = sibling
        fileModificationDate = try? sibling
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        updateChangeCount(.changeCleared)
    }
}

/// NSFileCoordinator needs a file presenter to treat the .wadjet sibling as a
/// related item of the opened image.
private final class SiblingPresenter: NSObject, NSFilePresenter {
    var primaryPresentedItemURL: URL?
    var presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main

    init(primary: URL, sibling: URL) {
        primaryPresentedItemURL = primary
        presentedItemURL = sibling
    }
}
