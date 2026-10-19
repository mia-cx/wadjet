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

/// One window captured whole, independent of what covers it, from the capture boundary.
public struct CapturedWindow: Sendable {
    public var frame: CGRect   // AppKit global points
    public var image: CGImage
    public var app: String?
    public var title: String?
    public init(frame: CGRect, image: CGImage, app: String? = nil, title: String? = nil) {
        self.frame = frame
        self.image = image
        self.app = app
        self.title = title
    }
}

extension CanvasDocument {
    /// Keeps every captured display for recropping. Region/screen captures retain
    /// off-crop Annotations; a window capture retains fills/strokes touching its frame.
    public init(capturedDisplays: [CapturedCanvasDisplay], crop: CGRect, cornerRadius: CGFloat = 0,
                annotations: LayerStack, windowCapture: Bool = false) {
        let frames = windowCapture ? [crop] : capturedDisplays.map(\.display.frame)
        let kept = annotations.annotations.filter { annotation in
            let coverage = PathGeometry.coverage(for: annotation)
            return frames.contains { frame in
                coverage.intersects(CGPath(rect: frame, transform: nil), using: .winding)
            }
        }
        self.init(layout: capturedDisplays.map(\.display), crop: crop, cornerRadius: cornerRadius,
            layerStack: LayerStack(kept),
            displayImages: Dictionary(uniqueKeysWithValues: capturedDisplays.map { ($0.display.id, $0.image) }))
    }

    /// Keeps each window as its own layer. `windows` is front first (window-list
    /// order); each becomes a CanvasWindowLayer and a `.window` Annotation, all
    /// below every existing Annotation, the frontmost window highest among them.
    public mutating func addWindowLayers(_ windows: [CapturedWindow]) {
        var added: [Annotation] = []
        for (index, w) in windows.enumerated() {
            let layerID = UUID()
            windowLayers.append(CanvasWindowLayer(frame: w.frame, zOrder: windows.count - 1 - index,
                imageFileName: "window-\(layerID.uuidString).heic", image: w.image,
                id: layerID, app: w.app, title: w.title))
            added.append(Annotation(kind: .window(layerID: layerID, frame: w.frame),
                style: AnnotationStyle(colour: RGBAColour(red: 0, green: 0, blue: 0, alpha: 1), width: 0)))
        }
        layerStack.annotations = added.reversed() + layerStack.annotations
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
