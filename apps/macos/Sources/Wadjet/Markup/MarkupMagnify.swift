import SwiftUI
import WadjetKit

/// Magnify's options, at `markup.tools.magnify.magnifier` in config.json. Like
/// MarkupShapes: while a Magnify is selected these read and edit it, otherwise
/// the Tool's defaults.
@MainActor enum MarkupMagnify {
    private static var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    /// the selected Magnify's options, else the configured defaults, else stock
    static var options: MagnifierOptions {
        if case let .magnify(m) = MarkupController.active.selected?.kind { return m.options }
        return config.value.markup.tools["magnify"]?.magnifier ?? .init()
    }

    /// a selected Magnify changes alone (via MarkupController.transformSelection);
    /// with nothing selected the change becomes the Tool's default
    static func setOptions(_ change: (inout MagnifierOptions) -> Void) {
        if var a = MarkupController.active.selected, case var .magnify(m) = a.kind {
            change(&m.options)
            a.kind = .magnify(m)
            MarkupController.active.transformSelection { _ in a }
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

    /// whether the selected Magnify zoomed away from a fresh lens's zoom
    static var zoomOverridden: Bool {
        if case let .magnify(m) = MarkupController.active.selected?.kind { return !m.zoomIsAuto }
        return false
    }
    /// the selected Magnify's lens back at a fresh lens's zoom, about its centre
    static func resetZoom() {
        guard var a = MarkupController.active.selected, case let .magnify(m) = a.kind else { return }
        a.kind = .magnify(m.resettingZoom())
        MarkupController.active.transformSelection { _ in a }
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
                         on: MarkupMagnify.options.shape == shape) {
                    MarkupMagnify.setOptions { $0.shape = shape }
                }
            }
        }
    }
}

extension ToolMenuView {
    /// Magnify's rows below its style controls: Leader/Glass/Border toggles
    /// and Reset Zoom keep the menu open, the Scaling radios behave like the
    /// other pick rows and close it
    @ViewBuilder func magnifyRows() -> some View {
        divider()
        MenuRow(title: "Leader Line", icon: "line.diagonal",
                on: MarkupMagnify.options.leader, isToggle: true) {
            MarkupMagnify.setOptions { $0.leader.toggle() }
        }
        MenuRow(title: "Glass", icon: "drop",
                on: MarkupMagnify.options.glass, isToggle: true) {
            MarkupMagnify.setOptions { $0.glass.toggle() }
        }
        MenuRow(title: "Border", icon: "app.dashed",
                on: MarkupMagnify.options.border != nil, isToggle: true) {
            // turning on seeds the border with the outline colour
            MarkupMagnify.setOptions {
                $0.border = $0.border == nil ? MarkupStyles.shared.style(for: .magnify).colour : nil
            }
            ctrl.fitMenu() // the border colour row appears or leaves below
        }
        if MarkupMagnify.options.border != nil {
            MarkupColourRow(tool: .magnify, target: .border, ctrl: ctrl)
        }
        section("Scaling") {
            row("Nearest Neighbour", icon: "square.grid.3x3",
                on: MarkupMagnify.options.scaling == .nearestNeighbour) {
                MarkupMagnify.setOptions { $0.scaling = .nearestNeighbour }
            }
            row("Lanczos", icon: "circle.grid.3x3",
                on: MarkupMagnify.options.scaling == .lanczos) {
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
