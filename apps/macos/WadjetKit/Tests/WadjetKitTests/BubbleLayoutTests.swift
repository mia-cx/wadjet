import CoreGraphics
import Testing
import WadjetKit

struct BubbleLayoutTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // Proves the bubble picks the shape's right side, flips left when that would leave
    // the screen, and drops under it right-aligned when neither side has room.
    @Test(arguments: [
        (shape: CGRect(x: 660, y: 870, width: 120, height: 24), size: CGSize(width: 60, height: 28),
         expected: CGRect(x: 788, y: 866, width: 60, height: 28)),   // right of the pill
        (shape: CGRect(x: 1350, y: 870, width: 80, height: 24), size: CGSize(width: 60, height: 28),
         expected: CGRect(x: 1282, y: 866, width: 60, height: 28)), // no room right -> left
        (shape: CGRect(x: 300, y: 870, width: 1140, height: 24), size: CGSize(width: 300, height: 28),
         expected: CGRect(x: 1140, y: 834, width: 300, height: 28)), // neither side -> below
    ])
    func frame(shape: CGRect, size: CGSize, expected: CGRect) {
        #expect(BubbleLayout.frame(size: size, beside: shape, top: 894, in: Self.screen) == expected)
    }
}
