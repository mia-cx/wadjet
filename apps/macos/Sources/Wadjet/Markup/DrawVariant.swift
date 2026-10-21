import SwiftUI
import WadjetKit

extension ToolMenuView {
    /// Draw's variants — picking one finishes any Pen path in progress
    var drawTiles: [[MenuTile]] {
        [DrawVariant.allCases.map { v in
            MenuTile(icon: v.symbol, caption: v.title, on: MarkupStyles.shared.drawVariant == v) {
                MarkupController.active.finishPen()
                MarkupStyles.shared.drawVariant = v
                s.openMenu = nil; ctrl.syncMenu()
            }
        }]
    }
}
