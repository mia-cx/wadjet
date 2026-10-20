import SwiftUI
import WadjetKit

/// Shapes' variant and each variant's option, in config.json under `markup.tools`
/// (`shapes.variant`, `<variant>.shape`). Like MarkupStyles: while a shape is
/// selected these read and edit it, otherwise the Tool's defaults.
@MainActor enum MarkupShapes {
    private static var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    /// the selected shapes' kinds, back to front
    static var selectedShapes: [ShapeKind] {
        MarkupController.active.selectedAnnotations.compactMap {
            if case let .shape(k, _) = $0.kind { k } else { nil }
        }
    }
    /// the selected shapes are of different variants — no variant tile is lit
    static var variantMixed: Bool { Mixed(selectedShapes.map(\.variant))?.isMixed == true }

    /// the first selected shape's variant, else the configured one, else .rectangle
    static var variant: ShapeVariant {
        if let k = selectedShapes.first { return k.variant }
        return config.value.markup.tools["shapes"]?.variant.flatMap(ShapeVariant.init) ?? .rectangle
    }

    /// every selected shape turns into the variant (keeping its rect and
    /// style); with no shape selected it becomes the variant new shapes draw
    static func pick(_ v: ShapeVariant) {
        guard !selectedShapes.isEmpty else {
            config.update { $0.markup.tools["shapes", default: .init()].variant = v.rawValue }
            return
        }
        let k = shape(for: v)
        setEach { $0.variant == v ? $0 : k }
    }

    /// the first selected shape's kind if it's this variant, else
    /// `markup.tools.<v>.shape`, else v.defaultShape
    static func shape(for v: ShapeVariant) -> ShapeKind {
        if let k = selectedShapes.first(where: { $0.variant == v }) { return k }
        return config.value.markup.tools[v.rawValue]?.shape ?? v.defaultShape
    }

    /// edits every selected shape's option (via
    /// MarkupController.transformSelection), or the remembered one for its variant
    static func setShape(_ k: ShapeKind) {
        guard selectedShapes.isEmpty else { setEach { _ in k }; return }
        config.update { $0.markup.tools[k.variant.rawValue, default: .init()].shape = k }
    }

    /// each selected shape's kind replaced, its rect kept — one undo step
    private static func setEach(_ change: (ShapeKind) -> ShapeKind) {
        MarkupController.active.transformSelection { a in
            guard case let .shape(k, rect) = a.kind else { return a }
            var a = a
            a.kind = .shape(change(k), rect: rect)
            return a
        }
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
                             on: !MarkupShapes.variantMixed && MarkupShapes.variant == v) {
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
    var shared: AnnotationStyle.Shared? { MarkupController.active.sharedStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
                .padding(.horizontal, 20).padding(.vertical, 3)
            // a mixed toggle reads off, and turns every selected shape's on
            let strokeMixed = shared?.stroked.isMixed == true
            let fillMixed = Mixed((MarkupController.active.selectedAnnotations).map { $0.style.fill != nil })?.isMixed == true
            MenuRow(title: "Stroke", subtitle: strokeMixed ? "Mixed" : nil, icon: "square",
                    on: !strokeMixed && style.stroked, isToggle: true) {
                let on = strokeMixed || !style.stroked
                styles.restyle(tool) { st in
                    st.stroked = on
                    if !st.stroked, st.fill == nil { st.fill = st.colour }
                }
                ctrl.fitMenu() // dropping the stroke can bring in the fill colour row
            }
            MenuRow(title: "Fill", subtitle: fillMixed ? "Mixed" : nil, icon: "square.fill",
                    on: !fillMixed && style.fill != nil, isToggle: true) {
                let on = fillMixed || style.fill == nil
                styles.restyle(tool) { st in
                    if on { if st.fill == nil { st.fill = st.colour } }
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
