import CoreGraphics
import Testing
import WadjetKit

struct WindowLayerPickerTests {
    // Proves a floating window becomes a layer only when it covers a kept
    // window behind it — wadjet's own only at level 0 with includeWadjet —
    // and off-display or clear windows stay in the flat screens.
    @Test func candidates() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        func w(_ id: UInt32, _ level: Int, _ frame: CGRect, wadjet: Bool = false) -> ListedWindow {
            ListedWindow(id: id, level: level, frame: frame, ownedByWadjet: wadjet)
        }
        let whole = CGRect(x: 0, y: 0, width: 10, height: 10)
        let cases: [(windows: [ListedWindow], includeWadjet: Bool, want: [UInt32])] = [
            // a level-3 palette over a level-0 window: both kept, palette first
            ([w(1, 3, whole), w(2, 0, whole)], true, [1, 2]),
            // a level-25 status item clear of every window: dropped
            ([w(1, 25, CGRect(x: 80, y: 80, width: 10, height: 10)), w(2, 0, whole)], true, [2]),
            // a level-0 window off every display: dropped
            ([w(1, 0, CGRect(x: 200, y: 200, width: 10, height: 10)), w(2, 0, whole)], true, [2]),
            // wadjet's level-0 window kept only while the shot shows wadjet;
            // its level-20 panel never
            ([w(1, 20, whole, wadjet: true), w(2, 0, whole, wadjet: true), w(3, 0, whole)], true, [2, 3]),
            ([w(1, 20, whole, wadjet: true), w(2, 0, whole, wadjet: true), w(3, 0, whole)], false, [3]),
            // a level-8 banner over a kept level-3 palette over a level-0
            // window, touching only the palette: all three kept
            ([w(1, 8, CGRect(x: 2, y: 2, width: 4, height: 4)),
              w(2, 3, CGRect(x: 1, y: 1, width: 8, height: 8)),
              w(3, 0, whole)], true, [1, 2, 3]),
            // a level-20 Dock behind every level-0 window and overlapping one:
            // nothing kept is behind it, so it's dropped
            ([w(1, 0, whole), w(2, 0, CGRect(x: 20, y: 0, width: 10, height: 10)),
              w(3, 20, CGRect(x: 5, y: 5, width: 8, height: 8))], true, [1, 2]),
        ]
        for (windows, includeWadjet, want) in cases {
            #expect(windowLayerCandidates(windows, includeWadjet: includeWadjet,
                                          over: [display]).map(\.id) == want)
        }
    }
}
