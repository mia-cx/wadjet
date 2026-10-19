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
    /// session state: the hue wheel stays open across menu opens
    var wheelOpen = false

    private var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    func style(for tool: Tool) -> AnnotationStyle {
        config.value.markup.tools[tool.rawValue]?.style ?? tool.defaultStyle
    }

    /// With nothing selected, the change becomes the Tool's default for new
    /// Annotations. #107's selection seam plugs in here (and in `style(for:)`):
    /// while an Annotation is selected, read and restyle that Annotation instead.
    func restyle(_ tool: Tool, _ change: (inout AnnotationStyle) -> Void) {
        config.update {
            var style = $0.markup.tools[tool.rawValue]?.style ?? tool.defaultStyle
            change(&style)
            $0.markup.tools[tool.rawValue, default: WadjetConfig.MarkupTool()].style = style
        }
    }

    /// restyles the Tool's colour (opaque: transparency is the opacity slider's)
    /// and pushes it into the recent-colour ranking
    func useColour(_ c: RGBAColour, for tool: Tool) {
        let colour = RGBAColour(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        config.update {
            var style = $0.markup.tools[tool.rawValue]?.style ?? tool.defaultStyle
            style.colour = colour
            $0.markup.tools[tool.rawValue, default: WadjetConfig.MarkupTool()].style = style
            $0.markup.recentColours.recordUse(of: colour.hex)
        }
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

    /// a pending eyedropper pick: which Markup Tool takes the colour, and
    /// whether it started on the live toolbar (a Freeze Frame it must drop)
    private(set) var eyedropper: (tool: Tool, live: Bool)?

    /// hands the pointer to Pick Colour: from .frozen it switches Tool on the
    /// same Freeze Frame, from .toolbar it takes one and opens Pick Colour
    func beginEyedropper(for tool: Tool) {
        let s = AppState.shared
        eyedropper = (tool, live: s.phase == .toolbar)
        s.openMenu = nil; AppDelegate.shared?.overlayCtrl.syncMenu()
        AppDelegate.shared?.trigger(.pickColour)
    }

    /// the pixel Pick Colour read; true when an eyedropper pick consumed it
    func pick(_ c: RGB8) -> Bool {
        guard let e = eyedropper else { return false }
        useColour(RGBAColour(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1), for: e.tool)
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
        // while the live Freeze Frame is being taken the phase is still
        // .toolbar with the Markup Tool selected — that must NOT clear it
        case .toolbar where s.tool != e.tool:
            eyedropper = nil
        default: break
        }
    }
}

extension Tool {
    /// the built-in style a Markup Tool uses until the user restyles it
    var defaultStyle: AnnotationStyle {
        // every Markup Tool so far (Line): opaque red, 4 pt
        AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    }
}
