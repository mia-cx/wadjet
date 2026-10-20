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

    // Proves the undo grace is open only between its opening and its end, and closes early on demand.
    @Test func undoGrace() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var g = UndoGrace()
        #expect(!g.isOpen(at: t0))
        g.open(at: t0, for: 6)
        #expect(g.isOpen(at: t0.addingTimeInterval(5.9)))
        #expect(!g.isOpen(at: t0.addingTimeInterval(6)))
        g.close()
        #expect(!g.isOpen(at: t0.addingTimeInterval(1)))
    }
}
