import AppKit
import WadjetKit

extension MarkupToolKey {
    /// the Tool the key arms; Select has no ToolID, so nil means Select
    var markupTool: Tool { tool.flatMap { Tool(rawValue: $0.rawValue) } ?? .select }
}

extension MarkupController {
    /// presses a Markup Tool Key: arms its Tool — and variant, when the key
    /// names one — on this Markup. False when the key can't apply (an Editor
    /// has no Freeze Region); true when it armed or nothing had to change,
    /// so the key is always consumed.
    @discardableResult
    func press(_ key: MarkupToolKey) -> Bool {
        let tool = key.markupTool
        let current = isScreen ? AppState.shared.tool : armed
        if !isScreen, tool == .freezeRegion { return false }
        if tool == current,
           key.variant == nil
            || key.tool.flatMap({ AppState.shared.config.value.markup.armedVariant(of: $0) }) == key.variant {
            return true
        }
        if let variant = key.variant { tool.armVariant(variant) }
        if tool != current {
            if isScreen {
                AppDelegate.shared?.trigger(tool) // a More click's path: overflow Tools take the last slot
            } else {
                arm(tool)
                MarkupToolbar.shared.armed(tool)
            }
        }
        // a same-Tool variant switch (E/K) arms nothing, so nothing else
        // swaps the cursor under a resting pointer; the Editor refreshes its own
        if isScreen, AppDelegate.shared?.overlayCtrl.pointerOverUI != true {
            panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.view.setToolCursor()
        }
        AppLog.line("markup key: \(key.character) -> \(tool.title)")
        return true
    }
}
