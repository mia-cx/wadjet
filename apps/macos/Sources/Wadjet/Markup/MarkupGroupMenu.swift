import AppKit
import SwiftUI
import WadjetKit

extension ToolMenuView {
    /// the Markup group's settings live in Select's menu
    @ViewBuilder func markupGroupRows() -> some View {
        divider()
        clearAfterScreenshotRow()
        row("Peer Through", icon: "circle.dashed", on: s.config.value.markup.peerThrough, isToggle: true) {
            s.config.update { $0.markup.peerThrough.toggle() }
            PeerThrough.shared.sync()
        }
    }

    func clearAfterScreenshotRow() -> some View {
        row("Clear After Screenshot", icon: "trash", on: s.config.value.markup.clearAfterScreenshot, isToggle: true) {
            s.config.update { $0.markup.clearAfterScreenshot.toggle() }
        }
    }
}
