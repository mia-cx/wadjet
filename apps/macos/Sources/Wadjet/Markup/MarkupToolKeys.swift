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
        // — only when a Markup panel is the frontmost window under the pointer,
        // so the toolbar, menus, and Layers keep their own cursors
        if isScreen {
            let front = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            panels.first { $0.windowNumber == front }?.view.setToolCursor()
        }
        AppLog.line("markup key: \(key.character) -> \(tool.title)")
        return true
    }
}
