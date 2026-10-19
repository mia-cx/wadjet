import AppKit
import SwiftUI
import WadjetKit

/// The Eraser Tool's settings: the variant at `markup.tools.eraser.variant`,
/// the eraser's diameter at `markup.tools.eraser.size`.
@MainActor enum MarkupEraser {
    static let defaultWidth: CGFloat = 12
    /// Annotations an Eraser drag has marked dim to this until release
    static let dimOpacity: CGFloat = 0.3
    /// the Knife's preview line — Wadjet malachite, like MarkupView.accent
    static let cutLineColour = RGBAColour(red: 0.20, green: 0.84, blue: 0.58, alpha: 1)
    private static var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    static var variant: EraserVariant {
        get { EraserVariant(rawValue: config.value.markup.tools[Tool.eraser.rawValue]?.variant ?? "")
            ?? .eraser }
        set { config.update {
            $0.markup.tools[Tool.eraser.rawValue, default: WadjetConfig.MarkupTool()].variant = newValue.rawValue } }
    }

    /// the eraser's diameter in points
    static var width: CGFloat {
        config.value.markup.tools[Tool.eraser.rawValue]?.size ?? defaultWidth
    }
    static func setWidth(_ d: CGFloat) {
        config.update { $0.markup.tools[Tool.eraser.rawValue, default: WadjetConfig.MarkupTool()].size = d }
    }

    /// the Tool's cursor: the Knife is a crosshair; the Eraser a thin ring of
    /// diameter `width × zoom` — a 1 pt white ring over a black halo so it
    /// reads on any backdrop — cached by rounded diameter
    static func cursor(zoom: CGFloat) -> NSCursor {
        guard variant == .eraser else { return .crosshair }
        let d = max(4, (width * zoom).rounded())
        if let c = cursorCache[d] { return c }
        let S = d + 8
        let img = NSImage(size: CGSize(width: S, height: S), flipped: false) { r in
            let ring = CGRect(x: (r.width - d) / 2, y: (r.height - d) / 2, width: d, height: d)
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let halo = NSBezierPath(ovalIn: ring); halo.lineWidth = 2.5; halo.stroke()
            NSColor.white.setStroke()
            let inner = NSBezierPath(ovalIn: ring); inner.lineWidth = 1; inner.stroke()
            return true
        }
        // handler-backed images rasterize lazily — force it
        _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let c = NSCursor(image: img, hotSpot: NSPoint(x: S / 2, y: S / 2))
        cursorCache[d] = c
        return c
    }
    private static var cursorCache: [CGFloat: NSCursor] = [:]
}

extension ToolMenuView {
    /// the Eraser menu's head: the two variants, then a Size slider while the
    /// round eraser is picked — no colour or style controls
    @ViewBuilder func eraserRows() -> some View {
        tileRow([ToolID.eraser.variants.map { v in
            MenuTile(icon: v.symbol, caption: v.title,
                     on: AppState.shared.config.value.markup.armedVariant(of: .eraser) == v) {
                MarkupEraser.variant = EraserVariant(rawValue: v.id) ?? .eraser
                s.openMenu = nil; ctrl.syncMenu()
            }
        }])
        if MarkupEraser.variant == .eraser { EraserSizeRow() }
    }
}

/// the Eraser's Size slider — commits on release, seeded while no drag is in
/// flight and following the setting otherwise, like CounterControls
private struct EraserSizeRow: View {
    @State var size: Double = Double(MarkupEraser.defaultWidth)
    @State var editing = false
    var body: some View {
        MenuSliderRow(icon: "circle.dashed", label: "Size", text: "\(Int(size)) pt",
                      value: $size, range: 4...64, step: 2, editing: $editing) {
            MarkupEraser.setWidth(CGFloat(size))
        }
        .onAppear { size = MarkupEraser.width }
        .onChange(of: MarkupEraser.width) { _, d in
            guard !editing else { return }
            size = d
        }
    }
}
