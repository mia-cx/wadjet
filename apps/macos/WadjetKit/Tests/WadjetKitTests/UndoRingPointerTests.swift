import CoreGraphics
import Testing
import WadjetKit

struct UndoRingPointerTests {
    // Proves hover expands the island everywhere but the ring, and leaving collapses it.
    @Test func ringHoverStaysCollapsed() {
        var p = UndoRingPointer()
        p.moved(inside: true, onRing: false)
        #expect(p.expands)
        p.moved(inside: true, onRing: true)
        #expect(!p.expands && p.inside)
        p.moved(inside: false, onRing: false)
        #expect(!p.expands && !p.inside)
    }

    // Proves a click on the ring counts, then the island stays collapsed until the pointer leaves.
    @Test func clickHoldsUntilLeave() {
        var p = UndoRingPointer()
        p.moved(inside: true, onRing: true)
        let counted = p.clickedRing()
        #expect(counted)
        // the ring is gone and the pointer still rests where it was
        p.moved(inside: true, onRing: false)
        #expect(!p.expands)
        p.moved(inside: false, onRing: false)
        p.moved(inside: true, onRing: false)
        #expect(p.expands)
    }

    // Proves a hold carried into a fresh pointer (Undo rebuilt the island) lasts until the pointer leaves.
    @Test func heldAcrossARebuild() {
        var p = UndoRingPointer(held: true)
        #expect(p.held)
        p.moved(inside: true, onRing: false)
        #expect(!p.expands && p.held)
        p.moved(inside: false, onRing: false)
        #expect(!p.held)
        p.moved(inside: true, onRing: false)
        #expect(p.expands)
        #expect(!UndoRingPointer().held)
    }

    // Proves a click off the ring is not an undo and leaves hover alone.
    @Test func clickOffTheRing() {
        var p = UndoRingPointer()
        p.moved(inside: true, onRing: false)
        let off = p.clickedRing()
        #expect(!off && p.expands)
        // outside the island the ring can't be under the pointer
        p.moved(inside: false, onRing: true)
        let outside = p.clickedRing()
        #expect(!p.onRing && !outside)
    }

    // Proves the target grows a small ring to the minimum size about its centre, inside the island.
    @Test func target() {
        let island = CGRect(x: 0, y: 0, width: 120, height: 24)
        let t = UndoRingPointer.target(ring: CGRect(x: 100, y: 5, width: 14, height: 14), island: island)
        #expect(t == CGRect(x: 95, y: 0, width: 24, height: 24))
        // near the island's end it's clipped, never past it
        let edge = UndoRingPointer.target(ring: CGRect(x: 110, y: 5, width: 10, height: 14), island: island)
        #expect(edge.maxX == 120 && edge.minX == 103)
        // a ring bigger than the minimum keeps its frame
        let big = CGRect(x: 10, y: 0, width: 30, height: 24)
        #expect(UndoRingPointer.target(ring: big, island: island) == big)
        #expect(UndoRingPointer.target(ring: .null, island: island).isNull)
    }
}
