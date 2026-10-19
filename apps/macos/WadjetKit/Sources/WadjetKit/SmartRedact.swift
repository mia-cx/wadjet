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
    /// one or by an existing visible Black out Censor in `existing` (all four
    /// corners inside its transformed path) is skipped.
    public static func censors(covering boxes: [CGRect], style: AnnotationStyle,
                               existing: LayerStack) -> [Annotation] {
        let blackOuts = existing.annotations.compactMap { a -> CGPath? in
            guard !a.hidden, case .censor(_, .blackOut) = a.kind else { return nil }
            return PathGeometry.path(for: a)
        }
        var placed: [CGRect] = []
        var annotations: [Annotation] = []
        for box in boxes.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let padded = box.insetBy(dx: -padding, dy: -padding)
            let corners = [
                CGPoint(x: padded.minX, y: padded.minY), CGPoint(x: padded.maxX, y: padded.minY),
                CGPoint(x: padded.minX, y: padded.maxY), CGPoint(x: padded.maxX, y: padded.maxY),
            ]
            let covered = placed.contains { r in corners.allSatisfy(r.contains) }
                || blackOuts.contains { p in corners.allSatisfy { p.contains($0) } }
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
