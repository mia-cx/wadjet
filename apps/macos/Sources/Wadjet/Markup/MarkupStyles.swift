import AppKit
import Observation
import WadjetKit

/// Per-Tool Annotation styles and the colour control's state. The Tool menu
/// reads `style(for:)` and writes only through `restyle(_:_:)`.
@MainActor @Observable
final class MarkupStyles {
    static let shared = MarkupStyles()
    /// offered before there's colour history — Apple's system colours
    static let presetSwatches = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE", "#000000", "#FFFFFF"]
    static let swatchCount = 6
    /// session state: which colour row's hue wheel is open — it stays open
    /// across menu opens
    var wheel: ColourTarget?

    var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    /// Draw's current variant, persisted at markup.tools.draw.variant
    var drawVariant: DrawVariant {
        get { DrawVariant(rawValue: config.value.markup.tools[Tool.draw.rawValue]?.variant ?? "") ?? .line }
        set { config.update { $0.markup.tools[Tool.draw.rawValue, default: WadjetConfig.MarkupTool()].variant = newValue.rawValue } }
    }

    /// the selected Annotation's style if there is one, else the Tool's
    /// configured default — the #107 selection seam
    func style(for tool: Tool) -> AnnotationStyle {
        MarkupController.active.selectedStyle ?? config.value.markup.tools[tool.styleKey]?.style ?? tool.defaultStyle
    }

    /// While an Annotation is selected this restyles that Annotation alone
    /// (via MarkupController.restyle; `colourPicked` turns an image kind's
    /// coloured border on); with nothing selected the change becomes the
    /// Tool's default for new Annotations.
    func restyle(_ tool: Tool, colourPicked: Bool = false, _ change: (inout AnnotationStyle) -> Void) {
        if !MarkupController.active.selection.isEmpty {
            MarkupController.active.restyleSelection(colourPicked: colourPicked, change)
            return
        }
        config.update {
            var style = $0.markup.tools[tool.styleKey]?.style ?? tool.defaultStyle
            change(&style)
            $0.markup.tools[tool.styleKey, default: WadjetConfig.MarkupTool()].style = style
        }
    }

    /// the colour a row shows — a Magnify's border lives in the kind's
    /// options, so it reads through MarkupMagnify rather than the style
    func colour(for tool: Tool, target: ColourTarget) -> RGBAColour {
        if target == .border { return MarkupMagnify.options.border ?? style(for: tool).colour }
        return style(for: tool).colour(for: target)
    }

    /// the selected Brush stroke's Smoothing if one is selected, else the
    /// variant's configured default
    func smoothing(for tool: Tool) -> Double {
        if let a = MarkupController.active.selected, case let .path(d) = a.kind,
           let s = d.smoothing { return Double(s) }
        return config.value.markup.tools[tool.styleKey]?.smoothing ?? DrawVariant.defaultSmoothing
    }

    /// with a Brush stroke selected the slider refits it; otherwise it sets
    /// the variant's default for new strokes
    func setSmoothing(_ s: Double, for tool: Tool) {
        if MarkupController.active.selectedAnnotations.contains(where: \.isBrushStroke) {
            MarkupController.active.refitSelection(smoothing: CGFloat(s))
            return
        }
        config.update {
            $0.markup.tools[tool.styleKey, default: WadjetConfig.MarkupTool()].smoothing = s
        }
    }

    /// restyles a colour (opaque: transparency is the opacity slider's) on
    /// the selection or Tool default, and always records it in the ranking
    func useColour(_ c: RGBAColour, for tool: Tool, target: ColourTarget = .stroke) {
        let colour = RGBAColour(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        if target == .border { // a Magnify's border is kind data, not style
            MarkupMagnify.setOptions { $0.border = colour }
        } else {
            restyle(tool, colourPicked: true) { $0.setColour(colour, for: target) }
        }
        config.update { $0.markup.recordColour(colour.hex) }
    }

    /// the colour row's swatch cells: recent colours first, presets filling in
    var swatches: [RGBAColour] {
        config.value.markup.recentColours.rankedItems.compactMap(RGBAColour.init(hex:)).prefix(Self.swatchCount).map { $0 }
    }

    /// re-ranks recent colours against the presets when the menu opens —
    /// `update` writes config.json only when the ranking actually changed
    func refreshSwatches() {
        config.update {
            $0.markup.recentColours.refresh(candidates: $0.markup.recentColours.usedItems + Self.presetSwatches)
        }
    }

    // MARK: eyedropper — reuses Pick Colour itself, its loupe included

    /// a pending eyedropper pick: which Markup Tool and colour target take the
    /// colour, which Annotation it restyles (the selection Pick Colour's disarm
    /// clears), and whether it started on the live toolbar (a Freeze Frame it
    /// must drop)
    private(set) var eyedropper: (tool: Tool, target: ColourTarget, annotations: AnnotationSelection, live: Bool)?

    /// hands the pointer to Pick Colour: from .frozen it switches Tool on the
    /// same Freeze Frame, from .toolbar it takes one and opens Pick Colour.
    /// In an Editor there's no Freeze Frame to sample — the system sampler runs.
    func beginEyedropper(for tool: Tool, target: ColourTarget = .stroke) {
        let s = AppState.shared
        if MarkupController.active !== MarkupController.shared {
            NSColorSampler().show { colour in
                MainActor.assumeIsolated {
                    guard let colour,
                          let c = colour.usingColorSpace(.sRGB) else { return }
                    let rgba = RGBAColour(red: c.redComponent, green: c.greenComponent,
                                          blue: c.blueComponent, alpha: 1)
                    self.useColour(rgba, for: tool, target: target)
                }
            }
            return
        }
        // the menu's Tool follows the selection (Select's menu shows a selected
        // Line's Draw controls); the pick returns to the Tool actually armed
        let armed = MarkupController.active.armed ?? tool
        eyedropper = (armed, target, annotations: MarkupController.active.selection, live: s.phase == .toolbar)
        s.openMenu = nil; AppDelegate.shared?.overlayCtrl.syncMenu()
        AppDelegate.shared?.trigger(.pickColour)
    }

    /// the pixel Pick Colour read; true when an eyedropper pick consumed it
    func pick(_ c: RGB8) -> Bool {
        guard let e = eyedropper else { return false }
        let colour = RGBAColour(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1)
        if !e.annotations.isEmpty {
            if e.target == .border {
                for id in e.annotations { MarkupMagnify.setOptions(of: id) { $0.border = colour } }
            } else {
                MarkupController.active.restyle(e.annotations, colourPicked: true) { $0.setColour(colour, for: e.target) }
            }
            config.update { $0.markup.recordColour(colour.hex) }
        } else {
            useColour(colour, for: e.tool, target: e.target)
        }
        restore()
        return true
    }

    /// true when a pending eyedropper was cancelled
    func cancelEyedropper() -> Bool {
        guard eyedropper != nil else { return false }
        restore()
        return true
    }

    /// drops the pending pick and re-arms the Markup Tool — like other menu
    /// picks, the menu stays closed
    private func restore() {
        guard let e = eyedropper else { return }
        eyedropper = nil
        if e.live { AppDelegate.shared?.overlayCtrl.dropFreezeFrame() }
        AppDelegate.shared?.trigger(e.tool)
    }

    /// drops a pending eyedropper the phase change left behind — called from
    /// the phase/tool didSets, so it runs on every state change
    func syncEyedropper() {
        guard let e = eyedropper else { return }
        let s = AppState.shared
        switch s.phase {
        case .desktop:
            eyedropper = nil
        case .frozen where s.tool != .pickColour:
            eyedropper = nil
        // two transitional states must NOT clear it: the Markup Tool is still
        // selected while the live Freeze Frame is being taken, and Pick Colour
        // is selected a moment before the phase turns .frozen (showPanels sets
        // tool before phase)
        case .toolbar where s.tool != e.tool && s.tool != .pickColour:
            eyedropper = nil
        default: break
        }
    }
}

extension Annotation {
    /// a fitted Brush stroke that kept its samples — Smoothing refits it
    var isBrushStroke: Bool {
        if case let .path(d) = kind { return d.rawPoints != nil }
        return false
    }
}

/// which colour a Markup colour control edits: `stroke` is `style.colour`,
/// the main colour every Tool has; `fill` is a shape's `style.fill`; `border`
/// is a Magnify's `options.border`, which lives in the kind, not the style
enum ColourTarget {
    case stroke, fill, border
}

extension AnnotationStyle {
    /// the colour `target` edits — an unfilled shape's fill reads as the
    /// stroke colour, so the wheel opens somewhere sensible
    func colour(for target: ColourTarget) -> RGBAColour {
        switch target {
        case .stroke: colour
        case .fill: fill ?? colour
        case .border: preconditionFailure("a Magnify border lives in its options, not the style")
        }
    }
    mutating func setColour(_ c: RGBAColour, for target: ColourTarget) {
        switch target {
        case .stroke: colour = c
        case .fill: fill = c
        case .border: preconditionFailure("a Magnify border lives in its options, not the style")
        }
    }
}

extension Tool {
    /// the `markup.tools` key a Tool's style lives under — Shapes and Draw keep
    /// one per variant
    @MainActor var styleKey: String {
        switch self {
        case .shapes: MarkupShapes.variant.rawValue
        case .draw: MarkupStyles.shared.drawVariant.rawValue
        default: rawValue
        }
    }

    /// the built-in style a Markup Tool uses until the user restyles it —
    /// Magnify's outline is thinner than the other Tools' 4 pt
    @MainActor var defaultStyle: AnnotationStyle {
        if self == .draw { return MarkupStyles.shared.drawVariant.defaultStyle }
        return AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1),
                               width: self == .magnify ? 2 : 4)
    }
}
