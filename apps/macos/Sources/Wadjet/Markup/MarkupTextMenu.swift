import AppKit
import CoreText
import SwiftUI
import WadjetKit

extension MarkupStyles {
    /// whether the Tool menu's text controls apply: the selection is a .text
    /// Annotation, or nothing is selected and the armed Tool is Text
    func editsText(_ tool: Tool) -> Bool {
        if let sel = MarkupController.shared.selected {
            if case .text = sel.kind { return true }
            return false
        }
        return tool == .text
    }

    /// the selected text's format, else the Tool's configured default
    func textFormat(for tool: Tool) -> TextFormat {
        if let sel = MarkupController.shared.selected, case let .text(d) = sel.kind {
            return d.format
        }
        return config.value.markup.textFormat
    }

    /// the same rule as `restyle`: the selection only when a text is
    /// selected, else the change becomes the Tool's default format
    func restyleText(_ tool: Tool, _ change: (inout TextFormat) -> Void) {
        if let sel = MarkupController.shared.selected, case .text = sel.kind {
            MarkupController.shared.restyleSelectedText { change(&$0.format) }
            return
        }
        config.update {
            var f = $0.markup.textFormat
            change(&f)
            $0.markup.textFormat = f
        }
    }

    /// a font pick styles the selected text if any AND always becomes the new
    /// default; the family joins the recent ranking
    func pickFont(family: String, weight: TextWeight, for tool: Tool) {
        if let sel = MarkupController.shared.selected, case .text = sel.kind {
            MarkupController.shared.restyleSelectedText { $0.format.font = family; $0.format.weight = weight }
        }
        config.update {
            $0.markup.textFormat.font = family
            $0.markup.textFormat.weight = weight
            $0.markup.recentFonts.recordUse(of: family)
        }
    }

    /// re-ranks recent fonts against everything used when the menu opens —
    /// `update` writes config.json only when the ranking actually changed
    func refreshFonts() {
        config.update {
            $0.markup.recentFonts.refresh(candidates: $0.markup.recentFonts.usedItems,
                                          pinned: TextFonts.pinned)
        }
    }
}

extension MarkupController {
    /// replaces the selected Annotation's TextData — render() re-syncs the
    /// in-place editor's frame and face from it
    func restyleSelectedText(_ change: (inout TextData) -> Void) {
        guard var a = selected, case var .text(d) = a.kind else { return }
        change(&d)
        a.kind = .text(d)
        // a mid-edit restyle is part of the session's one undo step; a
        // committed text's restyle is its own recorded change
        if editing != nil {
            mutateUnrecorded { $0.replace(a) }
        } else {
            transformSelection { _ in a }
        }
        AppLog.line("markup: restyled text")
    }
}

/// The Text Tool's format controls: the font list (pinned, recent, every
/// installed family), size and weight sliders, and the alignment/pill tiles.
/// ToolMenuView metrics, dividers between groups.
struct TextFormatControls: View {
    let tool: Tool
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    var styles: MarkupStyles { .shared }
    @State var size: Double = 0
    @State var weightIndex: Double = 0
    /// a slider is mid-drag — re-seeding then would fight the user's thumb
    @State var editing = false

    var format: TextFormat { styles.textFormat(for: tool) }
    var weights: [TextWeight] { TextFonts.weights(of: format.font) }
    var sections: TextFonts.Sections {
        TextFonts.sections(installed: NSFontManager.shared.availableFontFamilies,
                           recent: s.config.value.markup.recentFonts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fontList
            divider()
            MenuSliderRow(icon: "textformat.size", label: "Size", text: "\(Int(size)) pt",
                          value: $size, range: 10...120, step: 1, editing: $editing) {
                styles.restyleText(tool) { $0.size = CGFloat(size) }
            }
            if weights.count > 1 {
                MenuSliderRow(icon: "bold", label: "Weight", text: weights[Int(weightIndex)].title,
                              value: $weightIndex, range: 0...Double(weights.count - 1), step: 1,
                              editing: $editing, valueWidth: 64) {
                    styles.restyleText(tool) { $0.weight = weights[Int(weightIndex)] }
                }
            }
            divider()
            formatTiles
        }
        .onAppear {
            styles.refreshFonts()
            size = Double(format.size)
            seedWeight()
        }
        // the selection can change under an open menu — follow it unless a
        // slider is mid-drag
        .onChange(of: format) { _, f in
            guard !editing else { return }
            size = Double(f.size)
            seedWeight()
        }
    }

    // MARK: font list — 5½ rows so the cut row hints it scrolls

    var fontList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sections.pinned, id: \.self) { family in
                    FontFamilyRow(family: family, on: family == format.font) { pick(family) }
                }
                hairline()
                ForEach(sections.recent, id: \.self) { family in
                    FontFamilyRow(family: family, on: family == format.font) { pick(family) }
                }
                if !sections.recent.isEmpty { hairline() }
                ForEach(sections.all, id: \.self) { family in
                    FontFamilyRow(family: family, on: family == format.font) { pick(family) }
                }
            }
        }
        .frame(height: 220)
    }

    func pick(_ family: String) {
        styles.pickFont(family: family, weight: format.weight, for: tool)
        s.openMenu = nil; ctrl.syncMenu()
    }

    // MARK: alignment and pill tiles — they keep the menu open

    var formatTiles: some View {
        HStack(spacing: 0) {
            MenuTile(icon: "text.alignleft", caption: "Left",
                     on: format.alignment == .left) {
                styles.restyleText(tool) { $0.alignment = .left }
            }
            MenuTile(icon: "text.aligncenter", caption: "Centre",
                     on: format.alignment == .centre) {
                styles.restyleText(tool) { $0.alignment = .centre }
            }
            MenuTile(icon: "text.alignright", caption: "Right",
                     on: format.alignment == .right) {
                styles.restyleText(tool) { $0.alignment = .right }
            }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 0.5, height: 36)
            MenuTile(icon: "capsule", filledIcon: "capsule.fill", caption: "Pill",
                     on: format.pill, isToggle: true) {
                styles.restyleText(tool) { $0.pill.toggle() }
            }
        }
    }

    /// the stored weight snapped to the nearest weight the family ships
    func seedWeight() {
        guard !weights.isEmpty else { return }
        let current = format.weight.trait
        weightIndex = Double(weights.enumerated().min { a, b in
            abs(a.element.trait - current) < abs(b.element.trait - current)
        }?.offset ?? 0)
    }

    func hairline() -> some View {
        Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
            .padding(.horizontal, 20)
    }
    func divider() -> some View {
        Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
            .padding(.horizontal, 20).padding(.vertical, 3)
    }
}

/// a font-list row: the family name in its own face, checkmark when current.
/// A pick closes the menu like the other radio rows.
struct FontFamilyRow: View {
    let family: String
    let on: Bool
    let action: () -> Void
    @State var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(family).font(face()).foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 22, height: 22)
                    .overlay {
                        if on {
                            Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 14)
            .background(menuHighlight(hovering))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// the family name in its own face; the menu font when that face can't
    /// render its own name or is a symbol font
    func face() -> Font {
        let font = TextFonts.font(family: family, weight: .regular, size: 15)
        guard usable(font) else { return .system(size: 15) }
        return Font(font)
    }
    func usable(_ font: CTFont) -> Bool {
        let traits = CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(font), kCTFontTraitsAttribute)
            as? [CFString: Any]
        let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        // the symbolic font class (12) sits in the top nibble of the mask trait
        if symbolic & CTFontSymbolicTraits.classMaskTrait.rawValue == 12 << 28 { return false }
        var chars = Array(family.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    }
}
