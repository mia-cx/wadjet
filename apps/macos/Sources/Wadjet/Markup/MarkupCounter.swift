import SwiftUI
import WadjetKit

/// The Step counter's format and size, at `markup.tools.counter`. Like
/// MarkupStyles: while a counter is selected these read and edit it,
/// otherwise the Tool's defaults.
@MainActor enum MarkupCounter {
    static let defaultSize: CGFloat = 28
    private static var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    /// the selected counters' formats and diameters, back to front
    static var selectedCounters: [(format: CounterFormat, size: CGFloat)] {
        MarkupController.active.selectedAnnotations.compactMap {
            if case let .counter(_, r, _, f) = $0.kind { (f, 2 * r) } else { nil }
        }
    }
    static var formatMixed: Bool { Mixed(selectedCounters.map(\.format))?.isMixed == true }
    static var sizeMixed: Bool { Mixed(selectedCounters.map(\.size))?.isMixed == true }

    /// the first selected counter's, else configured, else .numbers
    static var format: CounterFormat {
        if let c = selectedCounters.first { return c.format }
        return config.value.markup.tools["counter"]?.format ?? .numbers
    }

    /// relabels every selected counter (values kept), else sets the Tool's format
    static func setFormat(_ f: CounterFormat) {
        guard selectedCounters.isEmpty else {
            setEach { c, r, v, _ in .counter(center: c, radius: r, value: v, format: f) }
            return
        }
        config.update { $0.markup.tools["counter", default: .init()].format = f }
    }

    /// diameter: the first selected counter's 2 × radius, else configured, else defaultSize
    static var size: CGFloat {
        if let c = selectedCounters.first { return c.size }
        return config.value.markup.tools["counter"]?.size ?? defaultSize
    }

    /// resizes every selected counter about its centre, else sets the Tool's size
    static func setSize(_ d: CGFloat) {
        guard selectedCounters.isEmpty else {
            setEach { c, _, v, f in .counter(center: c, radius: d / 2, value: v, format: f) }
            return
        }
        config.update { $0.markup.tools["counter", default: .init()].size = d }
    }

    /// each selected counter rebuilt from its centre, radius, value, and format — one undo step
    private static func setEach(_ change: (CGPoint, CGFloat, Int, CounterFormat) -> AnnotationKind) {
        MarkupController.active.transformSelection { a in
            guard case let .counter(c, r, v, f) = a.kind else { return a }
            var a = a
            a.kind = change(c, r, v, f)
            return a
        }
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
                         on: !MarkupCounter.formatMixed && MarkupCounter.format == .numbers) {
                    MarkupCounter.setFormat(.numbers)
                }
                MenuTile(icon: "textformat.abc", caption: "Letters",
                         on: !MarkupCounter.formatMixed && MarkupCounter.format == .letters) {
                    MarkupCounter.setFormat(.letters)
                }
            }
            MenuSliderRow(icon: "circle.dashed", label: "Size",
                          text: MarkupCounter.sizeMixed && !editing ? "Mixed" : "\(Int(size)) pt",
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
