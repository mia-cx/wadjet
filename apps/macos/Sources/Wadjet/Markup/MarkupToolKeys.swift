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
        AppLog.line("markup key: \(key.character) -> \(tool.title)")
        return true
    }
}
