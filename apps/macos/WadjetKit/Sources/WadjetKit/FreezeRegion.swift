import CoreGraphics
import Foundation

/// Freeze region's variants: drag out a region, or click a window
public enum FreezeVariant: String, CaseIterable, Sendable {
    case region, window
    public var variant: ToolVariant {
        switch self {
        case .region: ToolVariant(id: rawValue, title: "Region", symbol: "rectangle.dashed")
        case .window: ToolVariant(id: rawValue, title: "Window", symbol: "macwindow.and.cursorarrow")
        }
    }
}

extension CanvasDocument {
    /// Freeze region's embedded Canvas: only the pixels of `displays` under
    /// `rect` (global points) — each display contributes the intersection,
    /// cropped 1:1 from its image at its own scale so nothing resamples and
    /// HDR values keep their headroom
    public init(freezing displays: [CapturedCanvasDisplay], rect: CGRect) {
        var layout: [CanvasDisplay] = [], images: [UInt32: CGImage] = [:]
        for captured in displays {
            let frame = captured.display.frame, s = captured.display.scaleFactor
            let part = frame.intersection(rect)
            guard part.width > 0, part.height > 0 else { continue }
            let image = captured.image
            // pixel rows are top-left origin; the crop snaps outward to the grid
            let x0 = max(0, floor((part.minX - frame.minX) * s)),
                x1 = min(CGFloat(image.width), ceil((part.maxX - frame.minX) * s)),
                y0 = max(0, floor((frame.maxY - part.maxY) * s)),
                y1 = min(CGFloat(image.height), ceil((frame.maxY - part.minY) * s))
            guard x1 > x0, y1 > y0,
                  let cropped = image.cropping(to: CGRect(x: x0, y: y0,
                                                          width: x1 - x0, height: y1 - y0))
            else { continue }
            var display = captured.display // the pixel rect back in global points
            display.frame = CGRect(x: frame.minX + x0 / s, y: frame.maxY - y1 / s,
                                   width: (x1 - x0) / s, height: (y1 - y0) / s)
            layout.append(display)
            images[display.id] = cropped
        }
        self.init(layout: layout, crop: rect, cornerRadius: 0, displayImages: images)
    }
}

extension Annotation {
    /// Freeze region's result: the embedded Canvas `name` shown whole at exactly its crop, so nothing visibly
    /// moves, rounded by the Canvas's corner radius, with the default Auto border marking it frozen
    public static func frozenRegion(embedding name: String, _ canvas: CanvasDocument, style: AnnotationStyle) -> Annotation {
        Annotation(kind: .canvas(.embedded(name), ImagePlacement(
            frame: canvas.crop, crop: canvas.crop, cornerRadius: canvas.cornerRadius)), style: style)
    }
}

extension LayerStack {
    /// adds `a` beneath every Annotation — Freeze region's pixels never cover what's drawn
    public mutating func addAtBottom(_ a: Annotation) {
        annotations.insert(a, at: 0)
    }
}
