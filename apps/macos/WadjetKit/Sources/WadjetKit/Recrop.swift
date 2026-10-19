import CoreGraphics

/// Which crop edges a Recrop drag moves; empty moves the whole crop.
public struct CropEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let minX = CropEdges(rawValue: 1 << 0)
    public static let maxX = CropEdges(rawValue: 1 << 1)
    public static let minY = CropEdges(rawValue: 1 << 2)
    public static let maxY = CropEdges(rawValue: 1 << 3)
}

extension CanvasDocument {
    /// The bounding box of every display: how far Recrop can extend the crop.
    /// Parts no display covers stay empty.
    public var displayBounds: CGRect {
        layout.map(\.frame).reduce(.null) { $0.union($1) }
    }

    /// Half the crop's shorter side: the largest corner radius it can show.
    public var maxCornerRadius: CGFloat {
        min(crop.width, crop.height) / 2
    }
}

/// Hit-testing and geometry for the Editor's Recrop mode: the crop is a rect
/// in Canvas coordinates the user grabs by its edges, corners, or body.
public enum Recrop {
    /// The edges a press at `point` grabs: within `radius` of a corner takes that
    /// corner's two edges, within `radius` of an edge takes that edge, inside takes
    /// none (a move), anywhere else is nil.
    public static func edges(at point: CGPoint, of crop: CGRect, radius: CGFloat) -> CropEdges? {
        let corners: [(CGPoint, CropEdges)] = [
            (CGPoint(x: crop.minX, y: crop.minY), [.minX, .minY]),
            (CGPoint(x: crop.maxX, y: crop.minY), [.maxX, .minY]),
            (CGPoint(x: crop.minX, y: crop.maxY), [.minX, .maxY]),
            (CGPoint(x: crop.maxX, y: crop.maxY), [.maxX, .maxY]),
        ]
        for (c, edges) in corners where hypot(point.x - c.x, point.y - c.y) <= radius {
            return edges
        }
        // an edge's band reaches `radius` past each end so corners stay grabbable
        let withinY = point.y >= crop.minY - radius && point.y <= crop.maxY + radius
        let withinX = point.x >= crop.minX - radius && point.x <= crop.maxX + radius
        if abs(point.x - crop.minX) <= radius, withinY { return .minX }
        if abs(point.x - crop.maxX) <= radius, withinY { return .maxX }
        if abs(point.y - crop.minY) <= radius, withinX { return .minY }
        if abs(point.y - crop.maxY) <= radius, withinX { return .maxY }
        return crop.contains(point) ? [] : nil
    }

    /// `crop` after dragging `edges` by `delta`, kept inside `bounds` and at
    /// least `minSize` on each side; a move keeps the crop's size.
    public static func drag(_ crop: CGRect, edges: CropEdges, by delta: CGVector,
                            within bounds: CGRect, minSize: CGFloat) -> CGRect {
        guard !edges.isEmpty else {
            var r = crop.offsetBy(dx: delta.dx, dy: delta.dy)
            if r.width <= bounds.width {
                r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
            } else { r.origin.x = bounds.minX }
            if r.height <= bounds.height {
                r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
            } else { r.origin.y = bounds.minY }
            return r
        }
        var r = crop
        if edges.contains(.minX) {
            let x = min(max(crop.minX + delta.dx, bounds.minX), crop.maxX - minSize)
            r.origin.x = x; r.size.width = crop.maxX - x
        }
        if edges.contains(.maxX) {
            let x = max(min(crop.maxX + delta.dx, bounds.maxX), crop.minX + minSize)
            r.size.width = x - r.minX
        }
        if edges.contains(.minY) {
            let y = min(max(crop.minY + delta.dy, bounds.minY), crop.maxY - minSize)
            r.origin.y = y; r.size.height = crop.maxY - y
        }
        if edges.contains(.maxY) {
            let y = max(min(crop.maxY + delta.dy, bounds.maxY), crop.minY + minSize)
            r.size.height = y - r.minY
        }
        return r
    }
}
