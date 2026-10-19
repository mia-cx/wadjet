import SwiftUI
import WadjetKit

/// The Step counter's format and size, at `markup.tools.counter`. Like
/// MarkupStyles: while a counter is selected these read and edit it,
/// otherwise the Tool's defaults.
@MainActor enum MarkupCounter {
    static let defaultSize: CGFloat = 28
    private static var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    /// the selected counter's, else configured, else .numbers
    static var format: CounterFormat {
        if case let .counter(_, _, _, f) = MarkupController.shared.selected?.kind { return f }
        return config.value.markup.tools["counter"]?.format ?? .numbers
    }

    /// relabels the selected counter (value kept), else sets the Tool's format
    static func setFormat(_ f: CounterFormat) {
        if var a = MarkupController.shared.selected,
           case let .counter(c, r, v, _) = a.kind {
            a.kind = .counter(center: c, radius: r, value: v, format: f)
            MarkupController.shared.transformSelection { _ in a }
            return
        }
        config.update { $0.markup.tools["counter", default: .init()].format = f }
    }

    /// diameter: the selected counter's 2 × radius, else configured, else defaultSize
    static var size: CGFloat {
        if case let .counter(_, r, _, _) = MarkupController.shared.selected?.kind { return 2 * r }
        return config.value.markup.tools["counter"]?.size ?? defaultSize
    }

    /// resizes the selected counter about its centre, else sets the Tool's size
    static func setSize(_ d: CGFloat) {
        if var a = MarkupController.shared.selected,
           case let .counter(c, _, v, f) = a.kind {
            a.kind = .counter(center: c, radius: d / 2, value: v, format: f)
            MarkupController.shared.transformSelection { _ in a }
            return
        }
        config.update { $0.markup.tools["counter", default: .init()].size = d }
    }
}

/// the Step counter menu's head: Numbers/Letters tiles, then the Size slider.
/// The slider commits on release only, seeded while no drag is in flight.
struct CounterControls: View {
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    @State var size: Double = MarkupCounter.defaultSize
    /// a slider is mid-drag — re-seeding then would fight the user's thumb
    @State var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                MenuTile(icon: "textformat.123", caption: "Numbers",
                         on: MarkupCounter.format == .numbers) {
                    MarkupCounter.setFormat(.numbers)
                }
                MenuTile(icon: "textformat.abc", caption: "Letters",
                         on: MarkupCounter.format == .letters) {
                    MarkupCounter.setFormat(.letters)
                }
            }
            MenuSliderRow(icon: "circle.dashed", label: "Size", text: "\(Int(size)) pt",
                          value: $size, range: 16...64, step: 2, editing: $editing) {
                MarkupCounter.setSize(size)
            }
        }
        .onAppear { size = MarkupCounter.size }
        // the selection can change under an open menu — follow it unless the
        // slider is mid-drag
        .onChange(of: MarkupCounter.size) { _, d in
            guard !editing else { return }
            size = d
        }
    }
}
