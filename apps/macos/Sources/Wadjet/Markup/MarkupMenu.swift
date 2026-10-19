import SwiftUI
import WadjetKit

extension ToolMenuView {
    /// the Transform rows while an Annotation is selected — its section brings
    /// its own leading divider
    @ViewBuilder func selectionRows() -> some View {
        if MarkupController.active.selectedStyle != nil {
            // these act on the canvas — keep the menu open
            section("Transform") {
                MenuRow(title: "Rotate Left", icon: "rotate.left", on: false) {
                    MarkupController.active.transformSelection { $0.rotated(by: .pi / 2) }
                }
                MenuRow(title: "Rotate Right", icon: "rotate.right", on: false) {
                    MarkupController.active.transformSelection { $0.rotated(by: -.pi / 2) }
                }
                MenuRow(title: "Flip Horizontal",
                        icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", on: false) {
                    MarkupController.active.transformSelection { $0.flipped(horizontally: true) }
                }
                MenuRow(title: "Flip Vertical",
                        icon: "arrow.up.and.down.righttriangle.up.righttriangle.down", on: false) {
                    MarkupController.active.transformSelection { $0.flipped(horizontally: false) }
                }
            }
        }
    }
}
