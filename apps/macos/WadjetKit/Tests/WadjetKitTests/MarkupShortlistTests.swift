import Foundation
import Testing
import WadjetKit

struct MarkupShortlistTests {
    static let catalogue = ["select", "eraser", "shapes", "draw", "text", "censor", "stepCounter"]
    static let pinned: Set<String> = ["select", "eraser"]

    // Proves pinned lead, the first three unpinned catalogue items are the
    // default slots, and a reserved pin is skipped until it exists.
    @Test(arguments: [
        (catalogue: catalogue, pinned: ["select", "eraser"], slots: ["shapes", "draw", "text"], overflow: ["censor", "stepCounter"]),
        (catalogue: ["select", "draw", "censor"], pinned: ["select"], slots: ["draw", "censor"], overflow: []),
    ])
    func defaults(catalogue: [String], pinned: [String], slots: [String], overflow: [String]) {
        var ranking = FrecencyRanker<String>()
        let list = MarkupShortlist.open(catalogue, pinned: Self.pinned, ranking: &ranking, at: Date(timeIntervalSince1970: 0))
        #expect(list.pinned == pinned)
        #expect(list.slots == slots)
        #expect(list.overflow == overflow)
    }

    // Proves re-ranking waits for the next open and pinned uses never take a slot.
    @Test func ranksOnOpenOnly() {
        let now = Date(timeIntervalSince1970: 0)
        var ranking = FrecencyRanker<String>()
        let held = MarkupShortlist.open(Self.catalogue, pinned: Self.pinned, ranking: &ranking, at: now)
        ranking.recordUse(of: "censor", at: now)
        ranking.recordUse(of: "censor", at: now)
        for _ in 0 ..< 5 { ranking.recordUse(of: "select", at: now) }
        #expect(held.slots == ["shapes", "draw", "text"])
        let next = MarkupShortlist.open(Self.catalogue, pinned: Self.pinned, ranking: &ranking, at: now)
        #expect(next.pinned == ["select", "eraser"])
        #expect(next.slots == ["censor", "shapes", "draw"])
        #expect(next.overflow == ["text", "stepCounter"])
    }

    // Proves an armed overflow item takes the last slot — the displaced slot
    // returns to the overflow in rank order — until the next open restores it.
    @Test func armedOverflowToolShowsUntilNextOpen() {
        let now = Date(timeIntervalSince1970: 0)
        var ranking = FrecencyRanker<String>()
        var list = MarkupShortlist.open(Self.catalogue, pinned: Self.pinned, ranking: &ranking, at: now)
        list.show("stepCounter")
        #expect(list.slots == ["shapes", "draw", "stepCounter"])
        #expect(list.overflow == ["text", "censor"])
        list.show("censor")
        #expect(list.slots == ["shapes", "draw", "censor"])
        #expect(list.overflow == ["text", "stepCounter"])
        list.show("draw")   // already slotted: no change
        list.show("select") // pinned: no change
        #expect(list.slots == ["shapes", "draw", "censor"])
        let reopened = MarkupShortlist.open(Self.catalogue, pinned: Self.pinned, ranking: &ranking, at: now)
        #expect(reopened.slots == ["shapes", "draw", "text"])
    }
}
