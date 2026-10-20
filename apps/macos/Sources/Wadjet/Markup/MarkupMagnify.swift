import SwiftUI
import WadjetKit

/// Magnify's options, at `markup.tools.magnify.magnifier` in config.json. Like
/// MarkupShapes: while a Magnify is selected these read and edit it, otherwise
/// the Tool's defaults.
@MainActor enum MarkupMagnify {
    private static var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    /// the first selected Magnify's options, else the configured defaults, else stock
    static var options: MagnifierOptions {
        if let m = selectedMagnifiers.first { return m.options }
        return config.value.markup.tools["magnify"]?.magnifier ?? .init()
    }
    /// the selected Magnifies, back to front
    static var selectedMagnifiers: [Magnifier] {
        MarkupController.active.selectedAnnotations.compactMap {
            if case let .magnify(m) = $0.kind { m } else { nil }
        }
    }
    /// whether the selected Magnifies disagree on an option
    static func mixed<T: Equatable>(_ read: (MagnifierOptions) -> T) -> Bool {
        Mixed(selectedMagnifiers.map { read($0.options) })?.isMixed == true
    }

    /// every selected Magnify changes (via MarkupController.transformSelection),
    /// each keeping the options the change doesn't touch; with none selected
    /// the change becomes the Tool's default
    static func setOptions(_ change: (inout MagnifierOptions) -> Void) {
        if !selectedMagnifiers.isEmpty {
            MarkupController.active.transformSelection { a in
                guard case var .magnify(m) = a.kind else { return a }
                var a = a
                change(&m.options)
                a.kind = .magnify(m)
                return a
            }
            return
        }
        config.update {
            var o = $0.markup.tools["magnify"]?.magnifier ?? .init()
            change(&o)
            $0.markup.tools["magnify", default: .init()].magnifier = o
        }
    }

    /// restyles one Magnify's options by id — the eyedropper's border target,
    /// whose selection Pick Colour's disarm cleared
    static func setOptions(of id: Annotation.ID, _ change: (inout MagnifierOptions) -> Void) {
        MarkupController.active.update(id) {
            guard case var .magnify(m) = $0.kind else { return }
            change(&m.options)
            $0.kind = .magnify(m)
        }
    }

    /// whether any selected Magnify zoomed away from a fresh lens's zoom
    static var zoomOverridden: Bool { selectedMagnifiers.contains { !$0.zoomIsAuto } }
    /// every selected Magnify's lens back at a fresh lens's zoom, about its centre
    static func resetZoom() {
        MarkupController.active.transformSelection { a in
            guard case let .magnify(m) = a.kind else { return a }
            var a = a
            a.kind = .magnify(m.resettingZoom())
            return a
        }
    }
}

/// Magnify's menu head: the three magnifier shapes as pick tiles — they keep
/// the menu open like ShapeVariantControls' variant tiles
struct MagnifyShapeControls: View {
    @ObservedObject var s = AppState.shared
    static let icons: [MagnifierShape: String] = [
        .superellipse: "app", .circle: "circle", .rectangle: "rectangle",
    ]
    static let captions: [MagnifierShape: String] = [
        .superellipse: "Superellipse", .circle: "Circle", .rectangle: "Rectangle",
    ]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(MagnifierShape.allCases, id: \.self) { shape in
                MenuTile(icon: Self.icons[shape] ?? "app", caption: Self.captions[shape] ?? shape.rawValue,
                         on: !MarkupMagnify.mixed(\.shape) && MarkupMagnify.options.shape == shape) {
                    MarkupMagnify.setOptions { $0.shape = shape }
                }
            }
        }
    }
}

extension ToolMenuView {
    /// Magnify's rows below its style controls: the Leader/Glass/Border
    /// toggles, the Scaling radios, and Reset Zoom all keep the menu open
    @ViewBuilder func magnifyRows() -> some View {
        divider()
        // a mixed toggle reads off and turns every selected Magnify on
        let leaderMixed = MarkupMagnify.mixed(\.leader), glassMixed = MarkupMagnify.mixed(\.glass)
        let borderMixed = MarkupMagnify.mixed { $0.border != nil }
        MenuRow(title: "Leader Line", subtitle: leaderMixed ? "Mixed" : nil, icon: "line.diagonal",
                on: !leaderMixed && MarkupMagnify.options.leader, isToggle: true) {
            let on = leaderMixed || !MarkupMagnify.options.leader
            MarkupMagnify.setOptions { $0.leader = on }
        }
        MenuRow(title: "Glass", subtitle: glassMixed ? "Mixed" : nil, icon: "drop",
                on: !glassMixed && MarkupMagnify.options.glass, isToggle: true) {
            let on = glassMixed || !MarkupMagnify.options.glass
            MarkupMagnify.setOptions { $0.glass = on }
        }
        MenuRow(title: "Border", subtitle: borderMixed ? "Mixed" : nil, icon: "app.dashed",
                on: !borderMixed && MarkupMagnify.options.border != nil, isToggle: true) {
            // turning on seeds a border with the outline colour
            let on = borderMixed || MarkupMagnify.options.border == nil
            let colour = MarkupStyles.shared.style(for: .magnify).colour
            MarkupMagnify.setOptions { $0.border = on ? $0.border ?? colour : nil }
            ctrl.fitMenu() // the border colour row appears or leaves below
        }
        if MarkupMagnify.options.border != nil {
            MarkupColourRow(tool: .magnify, target: .border, ctrl: ctrl)
        }
        section("Scaling") {
            row("Nearest Neighbour", icon: "square.grid.3x3",
                on: !MarkupMagnify.mixed(\.scaling) && MarkupMagnify.options.scaling == .nearestNeighbour) {
                MarkupMagnify.setOptions { $0.scaling = .nearestNeighbour }
            }
            row("Lanczos", icon: "circle.grid.3x3",
                on: !MarkupMagnify.mixed(\.scaling) && MarkupMagnify.options.scaling == .lanczos) {
                MarkupMagnify.setOptions { $0.scaling = .lanczos }
            }
        }
        if MarkupMagnify.zoomOverridden {
            MenuRow(title: "Reset Zoom", icon: "arrow.counterclockwise", on: false) {
                MarkupMagnify.resetZoom()
            }
        }
    }
}
