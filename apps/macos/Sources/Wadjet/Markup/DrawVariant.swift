import SwiftUI
import WadjetKit

/// Draw's variants, picked from the Draw menu's tile row; each keeps its own
/// style under `markup.tools.<variant>`
enum DrawVariant: String, CaseIterable {
    case line, pen
    var title: String {
        switch self { case .line: "Line"; case .pen: "Pen" }
    }
    var symbol: String {
        switch self { case .line: "line.diagonal"; case .pen: "pencil.tip" }
    }
    /// the built-in style until the user restyles the variant
    var defaultStyle: AnnotationStyle {
        AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    }
}

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
