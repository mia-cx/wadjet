import Foundation
import Testing
import WadjetKit

struct ClearFeedbackTests {
    // Proves an empty screen gets the "nothing to clear" cue instead of a fade.
    @Test func nothingToClear() {
        #expect(ClearFeedback.response(annotationCount: 0, reduceMotion: false) == .nothingToClear)
        #expect(ClearFeedback.response(annotationCount: 0, reduceMotion: true) == .nothingToClear)
    }

    // Proves the fade is quick, scales down slightly, and lands the clear after it ends.
    @Test func fadeOut() {
        guard case .fadeOut(let f) = ClearFeedback.response(annotationCount: 3, reduceMotion: false)
        else { Issue.record("expected a fade"); return }
        #expect((0.18...0.25).contains(f.duration))
        #expect(f.endScale < 1 && f.endScale > 0.9)
        #expect(f.settle >= f.duration)
    }

    // Proves Reduce Motion keeps only a short cross-fade: no scale, shorter than the full fade.
    @Test func reduceMotion() {
        guard case .fadeOut(let f) = ClearFeedback.response(annotationCount: 1, reduceMotion: true),
              case .fadeOut(let full) = ClearFeedback.response(annotationCount: 1, reduceMotion: false)
        else { Issue.record("expected fades"); return }
        #expect(f.endScale == 1)
        #expect(f.duration < full.duration && f.settle < full.settle)
        #expect(f.settle >= f.duration)
    }

    // Proves the shake starts and ends at rest and never swings past its distance.
    @Test func shake() {
        #expect(ClearFeedback.shakeOffset(progress: 0) == 0)
        #expect(ClearFeedback.shakeOffset(progress: 1) == 0)
        let swings = stride(from: 0.0, through: 1, by: 0.01).map { ClearFeedback.shakeOffset(progress: $0) }
        #expect(swings.allSatisfy { abs($0) <= 4 })
        #expect(swings.contains { $0 > 1 } && swings.contains { $0 < -1 })
    }

    // Proves the windows after a Clear that closed the toolbar: ⌘Z for 3 s,
    // the ring holding the island for 3 s, the Undo cell for 6 s, then nothing.
    @Test func afterADismissingClear() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        var u = ClearUndo()
        u.cleared(at: t0, ring: true)
        // (seconds, ⌘Z, island held, Undo offered)
        let rows: [(Double, Bool, Bool, Bool)] = [
            (0, true, true, true), (2, true, true, true), (2.99, true, true, true),
            (3, false, false, true), (4, false, false, true), (5.99, false, false, true),
            (6, false, false, false), (60, false, false, false),
        ]
        for (s, key, island, offer) in rows {
            #expect(u.takesShortcut(at: at(s)) == key, "⌘Z at \(s) s")
            #expect(u.holdsIsland(at: at(s)) == island, "island at \(s) s")
            #expect(u.offersUndo(at: at(s)) == offer, "Undo at \(s) s")
        }
        #expect(u.ringLeft(at: at(0)) == 1)
        #expect(u.ringLeft(at: at(1.5)) == 0.5)
        #expect(u.nextChange(after: at(0)) == at(3))
        #expect(u.nextChange(after: at(3)) == at(6))
        #expect(u.nextChange(after: at(6)) == nil)
    }

    // Proves Reduce Motion's text counts down 3, 2, 1 and goes when the ring empties.
    @Test func countdownText() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var u = ClearUndo()
        u.cleared(at: t0, ring: true)
        #expect([0, 0.5, 1.2, 2.5, 3].map { u.ringSeconds(at: t0.addingTimeInterval($0)) } == [3, 3, 2, 1, nil])
    }

    // Proves hovering the island stops the drain, and the Undo offer outlasts 6 s
    // until the resumed ring empties.
    @Test func hoverPausesTheRing() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        var u = ClearUndo()
        u.cleared(at: t0, ring: true)
        u.hover(true, at: at(1))
        #expect(u.ringLeft(at: at(5)) == u.ringLeft(at: at(1)))
        #expect(u.holdsIsland(at: at(7)))
        #expect(u.offersUndo(at: at(7)))
        #expect(!u.takesShortcut(at: at(7))) // ⌘Z goes back to the front app regardless
        u.hover(false, at: at(7))
        // 2 s of ring were left at the pause
        #expect(u.holdsIsland(at: at(8.9)) && u.offersUndo(at: at(8.9)))
        #expect(!u.holdsIsland(at: at(9)) && !u.offersUndo(at: at(9)))
        #expect(u.nextChange(after: at(7)) == at(9))
    }

    // Proves a Clear on a Freeze Frame (no ring) never holds the island but still offers Undo for 6 s.
    @Test func withoutARing() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var u = ClearUndo()
        u.cleared(at: t0, ring: false)
        u.hover(true, at: t0)
        #expect(!u.holdsIsland(at: t0))
        #expect(u.offersUndo(at: t0.addingTimeInterval(5.9)))
        #expect(!u.offersUndo(at: t0.addingTimeInterval(6)))
    }

    // Proves Undo (or a later edit) ends every window at once, mid-ring.
    @Test func endCancels() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var u = ClearUndo()
        u.cleared(at: t0, ring: true)
        u.end()
        let t = t0.addingTimeInterval(1)
        #expect(!u.takesShortcut(at: t) && !u.holdsIsland(at: t) && !u.offersUndo(at: t))
        #expect(u.nextChange(after: t) == nil)
    }
}
