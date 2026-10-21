import QuickLookUI
import UniformTypeIdentifiers
import WadjetKit

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping @Sendable (QLPreviewReply?, (any Error)?) -> Void) {
        let url = request.fileURL
        handler(QLPreviewReply(dataOfContentType: .png, contentSize: .zero) { _ in
            try CanvasQuickLook.previewPNG(for: CanvasDocument.read(from: url))
        }, nil)
    }
}
