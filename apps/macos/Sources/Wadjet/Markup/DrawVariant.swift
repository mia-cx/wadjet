import SwiftUI
import WadjetKit

/// Draw's variants, picked from the Draw menu's tile row; each keeps its own
/// style under `markup.tools.<variant>`
enum DrawVariant: String, CaseIterable {
    case line, pen, brush, highlighter
    /// Brush strokes fit to a path at this Smoothing until the user moves the slider
    static let defaultSmoothing = 0.5
    var title: String {
        switch self {
        case .line: "Line"; case .pen: "Pen"; case .brush: "Brush"; case .highlighter: "Highlighter"
        }
    }
    var symbol: String {
        switch self {
        case .line: "line.diagonal"; case .pen: "pencil.tip"
        case .brush: "paintbrush.pointed"; case .highlighter: "highlighter"
        }
    }
    /// Brush and Highlighter strokes fit to paths on release
    var isBrush: Bool { self == .brush || self == .highlighter }
    /// the built-in style until the user restyles the variant; the
    /// Highlighter remembers its own wide translucent multiply yellow
    var defaultStyle: AnnotationStyle {
        switch self {
        case .highlighter:
            AnnotationStyle(colour: RGBAColour(hex: "#FFF200")!, width: 20,
                            opacity: 0.4, blend: .multiply)
        default:
            AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
        }
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
