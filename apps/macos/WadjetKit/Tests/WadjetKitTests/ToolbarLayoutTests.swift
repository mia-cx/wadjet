import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct ToolbarLayoutTests {
    // the toolbar's own measurements: 72 pt cells 8 apart, a 17 pt divider, 20 pt ends
    private static let bar = ToolbarRowGeometry(cell: 72, gap: 8, divider: 17, edge: 20)
    // Markup has 8 Tools in the row, Still, Video and Utilities 3 each
    private static let counts = [8, 3, 3, 3]

    // Proves the row model puts each slot where the toolbar's HStack draws it: Current re-fits
    // the bar to the open group, Uniform keeps one width whichever group is open and centres a
    // small group in the widest group's slot.
    @Test(arguments: [
        (style: ToolbarLayoutStyle.current, open: 0, width: 987.0, still: 721.0, firstOpen: 56.0),
        (style: .current, open: 1, width: 587, still: 161, firstOpen: 161),
        (style: .uniform, open: 0, width: 987, still: 721, firstOpen: 56),
        (style: .uniform, open: 1, width: 987, still: 361, firstOpen: 361), // (632 − 232) / 2 inset
    ])
    func row(style: ToolbarLayoutStyle, open: Int, width: CGFloat, still: CGFloat, firstOpen: CGFloat) {
        let r = Self.bar.row(counts: Self.counts, open: open, style: style)
        #expect(r.width == width)
        #expect(r.centre(group: 1, index: open == 1 ? 0 : nil) == still)
        #expect(r.centre(group: open, index: 0) == firstOpen)
    }

    // Proves Steady keeps the cell under the pointer still: opening Still from Markup holds
    // Markup's slot, so the bar only grows, and the shift lands Still's first Tool on the screen
    // x its collapsed cell had.
    @Test func steadyAnchorsTheOpenedCell() {
        let before = Self.bar.row(counts: Self.counts, open: 0, style: .steady)
        let after = Self.bar.row(counts: Self.counts, open: 1, style: .steady, reserve: [632, 0, 0, 0])
        #expect(after.width == 1147) // grew by Still's spread, never shrank
        let x0 = before.centre(group: 1, index: nil)!, x1 = after.centre(group: 1, index: 0)!
        let limit = SteadyAnchor.limit(width: after.width, screenWidth: 1512, margin: 8, keep: 0)
        let o = SteadyAnchor.offset(current: 0, before: (x0, before.width), after: (x1, after.width), limit: limit)
        #expect(o == 80)
        #expect(o - after.width / 2 + x1 == 0 - before.width / 2 + x0) // same screen x
    }

    // Proves Steady's held slots never grow the row past the screen: on a 1280 pt display
    // (1240 pt budget), a sweep across every group releases just enough held width to fit,
    // widest hold first, and the open group keeps its full spread.
    @Test func steadyHoldFitsTheScreen() {
        let counts = [7, 3, 3, 3], held: [CGFloat] = [560, 232, 232, 232] // all visited, Utilities open
        #expect(Self.bar.row(counts: counts, open: 3, style: .steady, reserve: held).width == 1395)
        let fitted = Self.bar.fitReserve(counts: counts, open: 3, reserve: held, budget: 1240)
        #expect(fitted == [405, 232, 232, 232])
        #expect(Self.bar.row(counts: counts, open: 3, style: .steady, reserve: fitted).width == 1240)
        #expect(Self.bar.fitReserve(counts: counts, open: 3, reserve: held, budget: 1500) == held) // fits: untouched
    }

    // Proves the shift never pushes the bar off screen or off a notch it hangs around.
    @Test(arguments: [
        (width: 1147.0, screen: 1200.0, keep: 0.0, limit: 18.5),  // screen edge binds
        (width: 587, screen: 1512, keep: 300, limit: 143.5),        // notch binds
        (width: 1400, screen: 1200, keep: 0, limit: 0),             // wider than the screen
    ])
    func steadyLimit(width: CGFloat, screen: CGFloat, keep: CGFloat, limit: CGFloat) {
        #expect(SteadyAnchor.limit(width: width, screenWidth: screen, margin: 8, keep: keep) == limit)
        #expect(SteadyAnchor.offset(current: 0, before: (0, 0), after: (-500, 0), limit: limit) == limit)
    }

    // Proves Two Rows' header strip is the same whichever group shows, while its second bar
    // holds only the shown group's Tools.
    @Test func twoRowsStripHoldsStillAndBarSwaps() {
        let strip = Self.bar.strip(headers: 4)
        #expect(strip.width == 352)
        #expect(strip.centres == [56, 136, 216, 296])
        let small = ToolbarRowGeometry(cell: 52, gap: 6, divider: 0, edge: 16)
        let markup = small.row(counts: Self.counts, open: 0, style: .twoRows)
        let still = small.row(counts: Self.counts, open: 1, style: .twoRows)
        #expect(markup.width == 490)
        #expect(still.width == 200)
        #expect(still.centre(group: 1, index: 0) == 42)
        #expect(still.centre(group: 0, index: nil) == nil) // hidden groups have no cell
    }

    // Proves an existing config.json without the key keeps today's toolbar, and a chosen
    // layout survives a save.
    @Test func layoutDefaultsToCurrentAndRoundTrips() throws {
        #expect(try JSONDecoder().decode(WadjetConfig.self, from: Data("{}".utf8)).toolbarLayout == .current)
        var c = WadjetConfig()
        c.toolbarLayout = .twoRows
        #expect(try JSONDecoder().decode(WadjetConfig.self, from: JSONEncoder().encode(c)).toolbarLayout == .twoRows)
    }
}
