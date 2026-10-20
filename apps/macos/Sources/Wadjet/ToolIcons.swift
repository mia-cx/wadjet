import AppKit
import SwiftUI
import WadjetKit

/// Wadjet's full-colour icons, looked up here and nowhere else. Each one is an
/// image set in Icons.xcassets, named by what it stands for:
/// - `tool.<ToolID>` for a Tool, `tool.<ToolID>.<variant id>` for a variant
/// - `group.<kind>` for a collapsed toolbar group
/// - `menu.<row>` for status menu rows that aren't Tools
/// New artwork replaces an image set under the same name, with no code change.
/// A Tool without an image set keeps its SF Symbol.
/// The current set is Microsoft Fluent Emoji 3D (MIT, see THIRD_PARTY_NOTICES.md).
enum ToolIcon {
    /// the asset for `tool` drawn with `variant` (an id from `ToolID.variants`),
    /// falling back to the Tool's own asset
    static func asset(for tool: Tool, variant: String?) -> NSImage? {
        if let variant, let img = NSImage(named: "tool.\(tool.rawValue).\(variant)") { return img }
        return NSImage(named: "tool.\(tool.rawValue)")
    }

    /// the status menu's rows that aren't Tools
    enum MenuRow: String { case markup, recent, settings, debug }

    /// an 18×18 pt full-colour copy for an NSMenuItem: not a template, so it
    /// keeps its colours in light and dark menus and on the highlighted row
    static func menuImage(_ src: NSImage?) -> NSImage? {
        guard let img = src?.copy() as? NSImage else { return nil }
        img.isTemplate = false
        img.size = NSSize(width: 18, height: 18)
        return img
    }
    static func menuImage(for tool: Tool) -> NSImage? { menuImage(asset(for: tool, variant: nil)) }
    static func menuImage(for row: MenuRow) -> NSImage? { menuImage(NSImage(named: "menu.\(row.rawValue)")) }

    /// a resizable SwiftUI image: the asset in full colour, else the SF Symbol
    static func image(_ asset: NSImage?, symbol: String) -> Image {
        guard let asset else { return Image(systemName: symbol).resizable() }
        return Image(nsImage: asset).renderingMode(.original).resizable()
    }
}

extension Tool {
    /// the Tool's toolbar, island and Editor icon, following its armed variant;
    /// resizable, so give it a frame
    @MainActor var iconImage: Image {
        let variant = toolID.flatMap { AppState.shared.config.value.markup.armedVariant(of: $0) }?.id
        return ToolIcon.image(ToolIcon.asset(for: self, variant: variant), symbol: icon)
    }
}

extension Tool.Kind {
    /// a collapsed group's icon; resizable, so give it a frame
    var iconImage: Image {
        let name: String = switch self { case .shot: "shot"; case .rec: "rec"; case .util: "util"; case .markup: "markup" }
        return ToolIcon.image(NSImage(named: "group.\(name)"), symbol: badge)
    }
}
