import AppKit
import WadjetKit

extension Tool {
    /// whether this Tool opens on a Freeze Frame right now: during a Recording, Markup draws on the
    /// live screen so the video keeps moving. #105's Freeze Frame policy replaces this.
    @MainActor var opensFreezeFrame: Bool { kind != .markup || !AppState.shared.recActive }
}

extension OverlayController {
    /// Markup on the live screen: the toolbar comes up, or stays, with `tool` armed and no Freeze Frame
    func showLiveToolbar(armed tool: Tool) {
        let s = AppState.shared
        // stay active: the armed Tool needs the pointer's cursor, and syncArmed records whose focus we took
        let prev = prevFrontmost; prevFrontmost = nil
        dropFreezeFrame()
        prevFrontmost = prev
        s.tool = tool; s.triggerWorkflow = nil // a cancelled Freeze Frame takes its Shortcut's Workflow pick with it
        AppLog.line("markup: live toolbar with \(tool.title)")
    }
}
