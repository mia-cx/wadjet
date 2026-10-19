import AppKit
import SwiftUI
import WadjetKit

extension OverlayController {
    /// Back on the live desktop: nothing is selected, and the island stays on
    /// every display while Annotations exist or a Recording shows its island.
    /// Hovering it expands the toolbar unarmed.
    func syncDesktopChrome() {
        let s = AppState.shared
        guard s.phase == .desktop else { return }
        s.tool = nil
        chromeScreens = s.recActive || !MarkupController.shared.stack.isEmpty ? NSScreen.screens : []
        refreshToolbars()
    }
    /// a display plugged in or out: the live chrome follows the new screen set,
    /// keeping whatever Markup Tool is armed on the live toolbar. Display
    /// indices shift, so an armed Tool re-claims the pointer's display.
    func screensChanged() {
        let s = AppState.shared
        guard s.phase == .toolbar || s.phase == .desktop else { return }
        s.expandedDisplay = nil
        guard s.phase == .toolbar else { return syncDesktopChrome() }
        chromeScreens = NSScreen.screens
        refreshToolbars()
    }
}

extension AppDelegate {
    /// Clear removes every Annotation; on the desktop the island goes with them
    func clearAnnotations() {
        MarkupController.shared.clear()
        AppLog.line("markup: cleared")
        overlayCtrl.syncDesktopChrome()
    }
    /// the menu bar's Markup item
    @objc func armLastMarkupTool() { trigger(Tool.lastMarkup) }
}

extension ToolbarView {
    /// the count the collapsed island shows while no Markup Tool is armed and
    /// no Freeze Frame is up; nil while anything else owns the island
    var annotationCount: Int? {
        let n = MarkupController.shared.stack.annotations.count
        return recording || s.phase == .frozen || MarkupController.shared.armed != nil || n == 0 ? nil : n
    }
    /// the group the bar opens on with nothing selected: Markup while Annotations exist
    var restingGroup: Tool.Kind { s.tool?.kind ?? (MarkupController.shared.stack.isEmpty ? .shot : .markup) }
}

