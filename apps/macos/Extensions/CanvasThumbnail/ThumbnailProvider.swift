import QuickLookThumbnailing
import WadjetKit

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void) {
        do {
            let image = try CanvasQuickLook.thumbnail(at: request.fileURL, maximumSize: request.maximumSize, scale: request.scale)
            let size = CanvasQuickLook.thumbnailSize(for: image, maximumSize: request.maximumSize)
            handler(QLThumbnailReply(contextSize: size) { context in
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(origin: .zero, size: size))
                return true
            }, nil)
        } catch {
            handler(nil, error)
        }
    }
}
