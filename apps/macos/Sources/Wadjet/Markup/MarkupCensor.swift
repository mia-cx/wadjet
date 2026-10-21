import SwiftUI
import WadjetKit

extension MarkupStyles {
    /// the selected Annotation's method if it's a Censor, else Censor's
    /// configured default for new Annotations
    var censorMethod: CensorMethod {
        if let m = selectedCensorMethods.first { return m }
        return config.value.markup.tools["censor"]?.censorMethod ?? .blackOut
    }
    /// the selected Censors' methods, back to front
    var selectedCensorMethods: [CensorMethod] {
        MarkupController.active.selectedAnnotations.compactMap {
            if case let .censor(_, m) = $0.kind { m } else { nil }
        }
    }
    /// the selected Censors use different methods — no method tile is lit
    var censorMethodMixed: Bool { Mixed(selectedCensorMethods.map(\.title))?.isMixed == true }
    /// the selected Censors differ in method or strength — the slider reads Mixed
    var censorStrengthMixed: Bool { Mixed(selectedCensorMethods)?.isMixed == true }

    /// every selected Censor changes; with none selected the method becomes
    /// Censor's default for new Annotations (mirroring `restyle`)
    func setCensorMethod(_ m: CensorMethod) {
        if !selectedCensorMethods.isEmpty {
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
                MenuSliderRow(icon: "drop.halffull", label: "Blur radius",
                              text: styles.censorStrengthMixed && !editing ? "Mixed" : "\(Int(strength)) pt",
                              value: $strength, range: 2...40, step: 1, editing: $editing) {
                    styles.setCensorMethod(.blur(radius: strength))
                }
            case .pixelate:
                MenuSliderRow(icon: "square.grid.3x3", label: "Block size",
                              text: styles.censorStrengthMixed && !editing ? "Mixed" : "\(Int(strength)) pt",
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
            MenuTile(icon: CensorMethod.blackOut.variant.symbol, caption: CensorMethod.blackOut.variant.title, on: !mixed && method == .blackOut) {
                styles.setCensorMethod(.blackOut)
                ctrl.fitMenu() // the strength slider leaves
            },
            MenuTile(icon: CensorMethod.defaultBlur.variant.symbol, caption: CensorMethod.defaultBlur.variant.title, on: !mixed && isBlur) {
                if !isBlur || mixed { styles.setCensorMethod(.defaultBlur) }
                ctrl.fitMenu()
            },
            MenuTile(icon: CensorMethod.defaultPixelate.variant.symbol, caption: CensorMethod.defaultPixelate.variant.title, on: !mixed && isPixelate) {
                if !isPixelate || mixed { styles.setCensorMethod(.defaultPixelate) }
                ctrl.fitMenu()
            },
        ]]
    }
    var mixed: Bool { styles.censorMethodMixed }
    var isBlur: Bool { if case .blur = method { true } else { false } }
    var isPixelate: Bool { if case .pixelate = method { true } else { false } }
}
