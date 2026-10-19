import CoreGraphics
import Foundation

/// An image Smart Redact reads and the global-point rect it covers: one
/// Freeze Frame display, or a Canvas flattened at its crop.
public struct SmartRedactSource: Sendable {
    public var image: CGImage
    public var frame: CGRect
    public init(image: CGImage, frame: CGRect) {
        self.image = image
        self.frame = frame
    }
}

/// Finds what to redact and turns it into Black out Censors. Boxes are in
/// global screen points, matching Annotations.
public enum SmartRedact {
    /// points added on every side of a match, so antialiased glyph edges stay covered
    public static let padding: CGFloat = 2

    /// Global-point boxes to black out across `sources`: OCR text matches in
    /// the enabled categories (Vision's box for the matched range, else the
    /// detector's proportional box), plus face boxes when `.face` is on.
    /// Skips OCR when no text category is enabled.
    public static func boxes(in sources: [SmartRedactSource],
                             categories: Set<SmartRedactCategory>) async throws -> [CGRect] {
        let detector = try SmartRedactDetector()
        let wantsText = categories.contains { $0 != .face }
        var boxes: [CGRect] = []
        for source in sources {
            if wantsText {
                for line in try await recognizeTextLines(in: source.image) {
                    for match in detector.matches(in: [line.line], categories: categories) {
                        boxes.append(global(line.bounds(of: match.range) ?? match.bounds,
                                            in: source.frame))
                    }
                }
            }
            if categories.contains(.face) {
                for box in try await SmartRedactDetector.faceBoxes(in: source.image) {
                    boxes.append(global(box, in: source.frame))
                }
            }
        }
        return boxes
    }

    /// One Black out Censor per box, padded by `padding`, in `style`. Boxes
    /// are taken largest first; a padded box already covered by an accepted
    /// one (rect containment, so identical or edge-sharing boxes dedupe) or
    /// by an existing visible Black out Censor in `existing` that no later
    /// visible Annotation overlaps — a Blur or Pixelate above it repaints
    /// original pixels, and a Magnify paints source pixels into its frame —
    /// is skipped. Existing coverage tests the four corners of a 0.5 pt
    /// shrink inside the Censor's transformed path, so an equal rect counts.
    public static func censors(covering boxes: [CGRect], style: AnnotationStyle,
                               existing: LayerStack) -> [Annotation] {
        let layers = existing.annotations
        var placed: [CGRect] = []
        var annotations: [Annotation] = []
        for box in boxes.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let padded = box.insetBy(dx: -padding, dy: -padding)
            let inner = padded.insetBy(dx: 0.5, dy: 0.5)
            let corners = [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                           CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)]
            let covered = placed.contains { $0.contains(padded) }
                || layers.indices.contains { i in
                    let a = layers[i]
                    guard !a.hidden, case .censor(_, .blackOut) = a.kind else { return false }
                    let path = PathGeometry.path(for: a)
                    guard corners.allSatisfy({ path.contains($0) }) else { return false }
                    return !layers[(i + 1)...].contains {
                        !$0.hidden && PathGeometry.path(for: $0).boundingBoxOfPath
                            .union(PathGeometry.coverage(for: $0).boundingBoxOfPath)
                            .intersects(padded)
                    }
                }
            guard !covered else { continue }
            placed.append(padded)
            annotations.append(Annotation(kind: .censor(rect: padded, method: .blackOut), style: style))
        }
        return annotations
    }

    /// the normalized (0...1, lower-left) rect as global points in `frame`
    static func global(_ r: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
               width: r.width * frame.width, height: r.height * frame.height)
    }
}
