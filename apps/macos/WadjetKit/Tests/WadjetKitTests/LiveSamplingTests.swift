import CoreGraphics
import Testing
import WadjetKit

struct LiveSamplingTests {
    let display = CGRect(x: 0, y: 0, width: 100, height: 100)

    // Proves the union covers only what touches the display, clipped and integral.
    @Test func unionClipsAndRoundsOut() {
        let r = LiveSampling.union(of: [
            CGRect(x: 10, y: 10, width: 20, height: 20),
            CGRect(x: 80, y: 90, width: 40, height: 40), // hangs off the edge
            CGRect(x: 200, y: 200, width: 10, height: 10), // off the display entirely
        ], on: display)
        #expect(r == CGRect(x: 10, y: 10, width: 90, height: 90))
    }

    @Test func unionIsNilOffDisplay() {
        #expect(LiveSampling.union(of: [CGRect(x: 200, y: 0, width: 10, height: 10)], on: display) == nil)
        #expect(LiveSampling.union(of: [], on: display) == nil)
    }

    @Test func unionRoundsOutward() {
        let r = LiveSampling.union(of: [CGRect(x: 10.5, y: 10.5, width: 10.5, height: 10.5)], on: display)
        #expect(r == CGRect(x: 10, y: 10, width: 11, height: 11))
    }

    // Proves a global rect converts to SCStreamConfiguration's display-local
    // top-left points on a non-origin secondary display.
    @Test func sourceRectOnSecondaryDisplay() {
        let secondary = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        // global y is bottom-up, sourceRect y top-down: the display's top edge
        // (global maxY 880) is local 0, its bottom (global minY -200) is local 1080
        let r = LiveSampling.sourceRect(CGRect(x: 1440, y: -200, width: 100, height: 60), on: secondary)
        #expect(r == CGRect(x: 0, y: 1020, width: 100, height: 60))
        let top = LiveSampling.sourceRect(CGRect(x: 1500, y: 800, width: 50, height: 80), on: secondary)
        #expect(top == CGRect(x: 60, y: 0, width: 50, height: 80))
    }
}
