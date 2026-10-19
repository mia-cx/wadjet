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
            let path = PathGeometry.path(for: annotation)
            let area: CGPath
            switch annotation.kind {
            case .censor: area = path
            case .line: area = path.copy(strokingWithWidth: annotation.style.width,
                lineCap: .round, lineJoin: .round, miterLimit: 10)
            }
            return frames.contains { frame in
                area.intersects(CGPath(rect: frame, transform: nil), using: .winding)
            }
        }
        self.init(layout: capturedDisplays.map(\.display), crop: crop, cornerRadius: cornerRadius,
            layerStack: LayerStack(kept),
            displayImages: Dictionary(uniqueKeysWithValues: capturedDisplays.map { ($0.display.id, $0.image) }))
    }

    /// Completes a standalone window capture at the crop. Only a measured corner
    /// radius may clip pixels; an unmeasured window keeps its own alpha and corners.
    public mutating func setCapturedWindow(_ image: CGImage, cornerRadius: CGFloat? = nil) {
        self.cornerRadius = cornerRadius ?? 0
        windowLayers = [.init(frame: crop, zOrder: 0, imageFileName: "captured-window.heic",
            image: image, isolatesBackground: true)]
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
