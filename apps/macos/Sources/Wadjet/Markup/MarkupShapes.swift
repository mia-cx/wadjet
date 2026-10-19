import SwiftUI
import WadjetKit

/// Shapes' variant and each variant's option, in config.json under `markup.tools`
/// (`shapes.variant`, `<variant>.shape`). Like MarkupStyles: while a shape is
/// selected these read and edit it, otherwise the Tool's defaults.
@MainActor enum MarkupShapes {
    private static var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    /// the selected shape's variant, else the configured one, else .rectangle
    static var variant: ShapeVariant {
        if case let .shape(k, _) = MarkupController.active.selected?.kind { return k.variant }
        return config.value.markup.tools["shapes"]?.variant.flatMap(ShapeVariant.init) ?? .rectangle
    }

    /// picks the variant new shapes draw; a selected shape turns into it
    /// (keeping its rect and style)
    static func pick(_ v: ShapeVariant) {
        config.update { $0.markup.tools["shapes", default: .init()].variant = v.rawValue }
        guard var a = MarkupController.active.selected,
              case let .shape(_, rect) = a.kind else { return }
        a.kind = .shape(shape(for: v), rect: rect)
        MarkupController.active.transformSelection { _ in a }
    }

    /// the selected shape's kind if it's this variant, else
    /// `markup.tools.<v>.shape`, else v.defaultShape
    static func shape(for v: ShapeVariant) -> ShapeKind {
        if case let .shape(k, _) = MarkupController.active.selected?.kind, k.variant == v { return k }
        return config.value.markup.tools[v.rawValue]?.shape ?? v.defaultShape
    }

    /// edits the selected shape's option (via
    /// MarkupController.transformSelection), or the remembered one for its variant
    static func setShape(_ k: ShapeKind) {
        if var a = MarkupController.active.selected, case let .shape(_, rect) = a.kind {
            a.kind = .shape(k, rect: rect)
            MarkupController.active.transformSelection { _ in a }
            return
        }
        config.update { $0.markup.tools[k.variant.rawValue, default: .init()].shape = k }
    }
}

/// the Shapes menu's head: the four variant tiles, then the picked variant's
/// option sliders (none for Ellipse). Sliders commit on release only.
struct ShapeVariantControls: View {
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    @State var radius: Double = 0
    @State var sides: Double = 5
    @State var points: Double = 5
    @State var innerRatio: Double = 0.4
    /// a slider is mid-drag — re-seeding then would fight the user's thumb
    @State var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ShapeVariant.allCases, id: \.self) { v in
                    MenuTile(icon: v.symbol, caption: v.title,
                             on: MarkupShapes.variant == v) {
                        MarkupShapes.pick(v)
                        ctrl.fitMenu() // the option sliders change with the variant
                    }
                }
            }
            switch MarkupShapes.variant {
            case .rectangle:
                slider(icon: "square.dashed", label: "Corner radius", text: "\(Int(radius)) pt",
                       value: $radius, range: 0...40, step: 1) {
                    MarkupShapes.setShape(.rectangle(cornerRadius: radius))
                }
            case .ellipse:
                EmptyView()
            case .polygon:
                slider(icon: "pentagon", label: "Sides", text: "\(Int(sides))",
                       value: $sides, range: 3...12, step: 1) {
                    MarkupShapes.setShape(.polygon(sides: Int(sides)))
                }
            case .star:
                slider(icon: "star", label: "Points", text: "\(Int(points))",
                       value: $points, range: 3...12, step: 1) {
                    commitStar()
                }
                slider(icon: "star.leadinghalf.filled", label: "Inner radius",
                       text: "\(Int((innerRatio * 100).rounded()))%",
                       value: $innerRatio, range: 0.2...0.8, step: 0.05) {
                    commitStar()
                }
            }
        }
        .onAppear(perform: seed)
        // the selection can change under an open menu — follow it unless a
        // slider is mid-drag
        .onChange(of: MarkupShapes.shape(for: MarkupShapes.variant)) { _, _ in
            guard !editing else { return }; seed()
        }
    }

    func commitStar() { MarkupShapes.setShape(.star(points: Int(points), innerRatio: innerRatio)) }

    func slider(icon: String, label: String, text: String, value: Binding<Double>,
                range: ClosedRange<Double>, step: Double, commit: @escaping () -> Void) -> some View {
        MenuSliderRow(icon: icon, label: label, text: text,
                      value: value, range: range, step: step, editing: $editing, commit: commit)
    }

    /// reads the current variant's option into the sliders
    func seed() {
        switch MarkupShapes.shape(for: MarkupShapes.variant) {
        case let .rectangle(r): radius = r
        case .ellipse: break
        case let .polygon(n): sides = Double(n)
        case let .star(n, r): points = Double(n); innerRatio = r
        }
    }
}

/// a shape's stroke/fill toggles, and the fill's colour row while fill is on.
/// The rows keep the menu open; a shape always keeps a stroke or a fill.
struct ShapePaintControls: View {
    let tool: Tool
    let ctrl: OverlayController
    var styles: MarkupStyles { .shared }
    var style: AnnotationStyle { styles.style(for: tool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
                .padding(.horizontal, 20).padding(.vertical, 3)
            MenuRow(title: "Stroke", icon: "square", on: style.stroked, isToggle: true) {
                styles.restyle(tool) { st in
                    st.stroked.toggle()
                    if !st.stroked, st.fill == nil { st.fill = st.colour }
                }
                ctrl.fitMenu() // dropping the stroke can bring in the fill colour row
            }
            MenuRow(title: "Fill", icon: "square.fill", on: style.fill != nil, isToggle: true) {
                styles.restyle(tool) { st in
                    if st.fill == nil { st.fill = st.colour }
                    else { st.fill = nil; st.stroked = true }
                }
                ctrl.fitMenu() // the fill colour row appears or leaves below
            }
            if style.fill != nil {
                MarkupColourRow(tool: tool, target: .fill, ctrl: ctrl)
            }
        }
    }
}
