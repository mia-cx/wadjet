import SwiftUI
import WadjetKit

extension MarkupStyles {
    /// the selected Annotation's method if it's a Censor, else Censor's
    /// configured default for new Annotations
    var censorMethod: CensorMethod {
        if case let .censor(_, method) = MarkupController.active.selected?.kind { return method }
        return config.value.markup.tools["censor"]?.censorMethod ?? .blackOut
    }

    /// a selected Censor changes alone; with nothing selected the method
    /// becomes Censor's default for new Annotations (mirroring `restyle`)
    func setCensorMethod(_ m: CensorMethod) {
        if let a = MarkupController.active.selected, case .censor = a.kind {
            MarkupController.active.transformSelection {
                var a = $0
                if case let .censor(rect, _) = a.kind { a.kind = .censor(rect: rect, method: m) }
                return a
            }
            return
        }
        config.update { $0.markup.tools["censor", default: WadjetConfig.MarkupTool()].censorMethod = m }
    }
}

/// Censor's menu body: the three method tiles — Black out paints over, Blur
/// and Pixelate sample what's beneath — plus a strength slider while a
/// sampling method is on. Tiles keep the menu open so the slider stays reachable.
struct CensorControls: View {
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    var styles: MarkupStyles { .shared }
    @State var strength: Double = 0
    /// a slider is mid-drag — re-seeding then would fight the user's thumb
    @State var editing = false

    var method: CensorMethod { styles.censorMethod }
    var strengthValue: Double {
        switch method {
        case .blackOut: strength
        case let .blur(radius): radius
        case let .pixelate(blockSize): blockSize
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tiles.indices, id: \.self) { i in
                    if i > 0 { Rectangle().fill(.white.opacity(0.15)).frame(width: 0.5, height: 36) }
                    ForEach(tiles[i], id: \.caption) { $0 }
                }
            }
            switch method {
            case .blackOut:
                EmptyView()
            case .blur:
                MenuSliderRow(icon: "drop.halffull", label: "Blur radius", text: "\(Int(strength)) pt",
                              value: $strength, range: 2...40, step: 1, editing: $editing) {
                    styles.setCensorMethod(.blur(radius: strength))
                }
            case .pixelate:
                MenuSliderRow(icon: "square.grid.3x3", label: "Block size", text: "\(Int(strength)) pt",
                              value: $strength, range: 4...48, step: 2, editing: $editing) {
                    styles.setCensorMethod(.pixelate(blockSize: strength))
                }
            }
        }
        .onAppear { strength = strengthValue }
        // the selection can change under an open menu — follow it unless a
        // slider is mid-drag
        .onChange(of: method) { _, _ in
            guard !editing else { return }
            strength = strengthValue
        }
    }

    /// the method tiles: picking a sampling method seeds its default strength
    /// only when switching cases, so a tuned radius survives a tap on its tile
    var tiles: [[MenuTile]] {
        [[
            MenuTile(icon: "rectangle.fill", caption: "Black out", on: method == .blackOut) {
                styles.setCensorMethod(.blackOut)
                s.openMenu = nil; ctrl.syncMenu()
            },
            MenuTile(icon: "aqi.medium", caption: "Blur", on: isBlur) {
                if !isBlur { styles.setCensorMethod(.defaultBlur) }
                ctrl.fitMenu()
            },
            MenuTile(icon: "squareshape.split.3x3", caption: "Pixelate", on: isPixelate) {
                if !isPixelate { styles.setCensorMethod(.defaultPixelate) }
                ctrl.fitMenu()
            },
        ]]
    }
    var isBlur: Bool { if case .blur = method { true } else { false } }
    var isPixelate: Bool { if case .pixelate = method { true } else { false } }
}
