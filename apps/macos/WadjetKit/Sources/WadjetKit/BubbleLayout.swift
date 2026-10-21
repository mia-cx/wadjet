import CoreGraphics

/// Where the Recording bubble sits beside the island or toolbar shape so the two never overlap:
/// `gap` to the shape's right, top-aligned with the island pill; to its left when the right side
/// would leave the screen, and under the shape, right-aligned with it, when neither side has room.
public enum BubbleLayout {
    public static let gap: CGFloat = 8
    /// all rects in AppKit screen points (bottom-left origin); `top` is the island pill's top edge
    public static func frame(size: CGSize, beside shape: CGRect, top: CGFloat, in screen: CGRect) -> CGRect {
        var x = shape.maxX + gap
        if x + size.width <= screen.maxX {
            return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
        x = shape.minX - gap - size.width
        if x >= screen.minX {
            return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
        return CGRect(x: min(max(screen.minX, shape.maxX - size.width), screen.maxX - size.width),
                      y: shape.minY - gap - size.height, width: size.width, height: size.height)
    }
}
