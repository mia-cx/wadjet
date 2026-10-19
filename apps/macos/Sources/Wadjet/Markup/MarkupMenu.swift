import SwiftUI
import WadjetKit

extension ToolMenuView {
    /// the top of a Markup Tool's menu while an Annotation is selected:
    /// restyle and transform that Annotation alone
    @ViewBuilder func selectionRows() -> some View {
        if let style = MarkupController.shared.selectedStyle {
            tileRow([[2, 4, 8].map { w in
                MenuTile(icon: "lineweight", caption: "\(w) pt", on: style.width == CGFloat(w)) {
                    MarkupController.shared.selectedStyle?.width = CGFloat(w)
                    s.openMenu = nil; ctrl.syncMenu()
                }
            }])
            // these act on the canvas — keep the menu open
            section("Transform") {
                MenuRow(title: "Rotate Left", icon: "rotate.left", on: false) {
                    MarkupController.shared.transformSelection { $0.rotated(by: .pi / 2) }
                }
                MenuRow(title: "Rotate Right", icon: "rotate.right", on: false) {
                    MarkupController.shared.transformSelection { $0.rotated(by: -.pi / 2) }
                }
                MenuRow(title: "Flip Horizontal",
                        icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", on: false) {
                    MarkupController.shared.transformSelection { $0.flipped(horizontally: true) }
                }
                MenuRow(title: "Flip Vertical",
                        icon: "arrow.up.and.down.righttriangle.up.righttriangle.down", on: false) {
                    MarkupController.shared.transformSelection { $0.flipped(horizontally: false) }
                }
            }
            divider()
        }
    }
}
