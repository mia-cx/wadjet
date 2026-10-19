import CoreGraphics
import Foundation

/// One full-resolution, Markup-free display supplied by the capture boundary.
public struct CapturedCanvasDisplay {
    public var display: CanvasDisplay
    public var image: CGImage

    public init(display: CanvasDisplay, image: CGImage) {
        self.display = display
        self.image = image
    }
}

extension CanvasDocument {
    /// Keeps every captured display for recropping. Region/screen captures retain
    /// off-crop Annotations; a window capture retains only strokes touching its frame.
    public init(capturedDisplays: [CapturedCanvasDisplay], crop: CGRect, cornerRadius: CGFloat = 0,
                annotations: LayerStack, windowCapture: Bool = false) {
        let frames = windowCapture ? [crop] : capturedDisplays.map(\.display.frame)
        let kept = annotations.annotations.filter { annotation in
            let outline = PathGeometry.path(for: annotation).copy(strokingWithWidth: annotation.style.width,
                lineCap: .round, lineJoin: .round, miterLimit: 10)
            return frames.contains { frame in
                outline.intersects(CGPath(rect: frame, transform: nil), using: .winding)
            }
        }
        self.init(layout: capturedDisplays.map(\.display), crop: crop, cornerRadius: cornerRadius,
            layerStack: LayerStack(kept),
            displayImages: Dictionary(uniqueKeysWithValues: capturedDisplays.map { ($0.display.id, $0.image) }))
    }

    /// The private pasteboard representation contains the entire package, not a
    /// path into History that may expire before the user pastes it.
    public func serializedPackage() throws -> Data {
        guard let data = try fileWrapper().serializedRepresentation else {
            throw CanvasDocumentError.invalidPackage("couldn't serialize Canvas")
        }
        return data
    }

    /// Reopens the package carried by wadjet's private Canvas pasteboard type.
    public static func read(serializedPackage data: Data) throws -> CanvasDocument {
        guard let wrapper = FileWrapper(serializedRepresentation: data) else {
            throw CanvasDocumentError.invalidPackage("unreadable serialized Canvas")
        }
        return try CanvasDocument(fileWrapper: wrapper)
    }
}
