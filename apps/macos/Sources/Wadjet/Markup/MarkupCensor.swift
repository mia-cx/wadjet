import SwiftUI
import WadjetKit

extension ToolMenuView {
    /// Censor's variants: Black out is the only one until #124 adds Blur and Pixelate
    var censorTiles: [[MenuTile]] {
        [[
            MenuTile(icon: "rectangle.fill", caption: "Black out", on: true) {
                s.openMenu = nil; ctrl.syncMenu()
            },
            MenuTile(icon: "aqi.medium", caption: "Blur", on: false, disabled: true) {},
            MenuTile(icon: "squareshape.split.3x3", caption: "Pixelate", on: false, disabled: true) {},
        ]]
    }
}
