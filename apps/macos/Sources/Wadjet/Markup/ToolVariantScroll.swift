import AppKit
import WadjetKit

extension Tool {
    /// the Tool's icon in the toolbar, island, and Editor: its armed variant's symbol, else `symbol`
    @MainActor var icon: String {
        toolID.flatMap { AppState.shared.config.value.markup.armedVariant(of: $0) }?.symbol ?? symbol
    }
    /// arms the variant `step` places on, as picking its tile would (finishing
    /// any Pen path); a selected Annotation keeps its own variant
    @MainActor func cycleVariant(by step: Int) {
        guard let id = toolID, !id.variants.isEmpty else { return }
        MarkupController.active.finishPen()
        AppState.shared.config.update { $0.markup.cycleVariant(of: id, by: step) }
        AppDelegate.shared?.overlayCtrl.fitMenu() // an open menu's rows follow the variant
    }
}

/// Scroll ticks: one per wheel notch; trackpads accumulate 24 pt per tick and
/// momentum is ignored. +1 for down (next), -1 for up (previous).
struct ScrollTicks {
    private var acc: CGFloat = 0
    mutating func step(_ e: NSEvent) -> Int {
        guard e.momentumPhase.isEmpty, e.scrollingDeltaY != 0 else { return 0 }
        if !e.hasPreciseScrollingDeltas { return e.scrollingDeltaY > 0 ? -1 : 1 }
        if e.phase == .began { acc = 0 }
        acc += e.scrollingDeltaY
        var n = 0
        while acc >= 24 { acc -= 24; n += 1 }
        while acc <= -24 { acc += 24; n -= 1 }
        return n
    }
}

extension PassthroughHostingView {
    /// scroll over the selected Markup Tool's cell cycles its variants; false
    /// when the pointer is elsewhere, so the event travels on
    func scrollVariant(_ e: NSEvent) -> Bool {
        let s = AppState.shared
        // the cell frames are in SwiftUI's top-left "panel" space
        let q = convert(e.locationInWindow, from: nil)
        let p = isFlipped ? q : CGPoint(x: q.x, y: bounds.height - q.y)
        guard let t = s.tool, t.kind == .markup, s.expandedDisplay == displayIndex,
              ToolbarBtnFrames.rects[displayIndex]?[t]?.contains(p) == true
        else { return false }
        let step = scrollTicks.step(e)
        if step != 0 { t.cycleVariant(by: step) }
        return true
    }
}
