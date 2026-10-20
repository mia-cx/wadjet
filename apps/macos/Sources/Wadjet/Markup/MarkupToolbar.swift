import Observation
import SwiftUI
import WadjetKit

extension Tool {
    /// The Markup group's catalogue in toolbar order: Select, Direct Select, Eraser, Shapes, Draw,
    /// Text, then the rest. A new Markup Tool joins with one entry here; where it
    /// sits sets its default rank, so the first three unpinned Tools fill the ranked
    /// slots before any use. Variants live in their Tool's menu, not here.
    static let markupCatalogue: [Tool] = [.select, .directSelect, .eraser, .shapes, .draw, .text, .censor, .counter, .magnify,
        .freezeRegion]
    /// always shown ahead of the ranked slots, by raw name: Select, Direct
    /// Select, and Eraser are the group's permanent cells
    static let markupPinned: Set<String> = ["select", "directSelect", "eraser"]
    /// the Markup Tool the menu bar's Markup item arms: the most recently armed one,
    /// across launches
    @MainActor static var lastMarkup: Tool { MarkupToolbar.shared.lastArmed }
}

/// The Markup group's layout, ranked by use. It re-ranks when a toolbar expands
/// (AppState.expandedDisplay nil → a display), never while one is open; arming
/// counts as a use, and an armed overflow Tool shows in the last slot until the
/// next open.
@MainActor @Observable
final class MarkupToolbar {
    static let shared = MarkupToolbar()
    private(set) var layout: MarkupShortlist<String>

    private var config: ConfigStore<WadjetConfig> { AppState.shared.config }

    private init() {
        layout = Self.rerank()
    }

    /// re-ranks the persisted Tool ranking over the catalogue and writes it
    /// back — the layout an `open` snapshot starts from
    private static func rerank() -> MarkupShortlist<String> {
        var ranking = AppState.shared.config.value.markup.toolRanking
        let layout = MarkupShortlist.open(Tool.markupCatalogue.map(\.rawValue),
                                          pinned: Tool.markupPinned, ranking: &ranking)
        AppState.shared.config.update { $0.markup.toolRanking = ranking }
        return layout
    }

    /// a toolbar opening re-ranks the group; an armed overflow Tool then
    /// re-claims its slot so the visible set stays true
    func open() {
        layout = Self.rerank()
        if let t = MarkupController.shared.armed { layout.show(t.rawValue) }
        AppLog.line("markup shortlist: \(layout.pinned) | \(layout.slots) | \(layout.overflow)")
    }

    /// the one recorded use — whatever path armed the Tool calls through here
    func armed(_ tool: Tool) {
        config.update { $0.markup.toolRanking.recordUse(of: tool.rawValue) }
        layout.show(tool.rawValue)
    }

    /// the cells the open Markup group shows: pinned Tools, then the ranked slots
    var visible: [Tool] { (layout.pinned + layout.slots).compactMap(Tool.init(rawValue:)) }
    /// the rest of the catalogue, rendered but taking no room — More's menu lists them
    var overflow: [Tool] { layout.overflow.compactMap(Tool.init(rawValue:)) }
    /// the most recently armed catalogue Tool, else the top ranked slot, else Select
    var lastArmed: Tool {
        let catalogue = Set(Tool.markupCatalogue)
        if let t = config.value.markup.toolRanking.usedItems
            .compactMap(Tool.init(rawValue:)).first(where: catalogue.contains) { return t }
        return layout.slots.first.flatMap(Tool.init(rawValue:)) ?? .select
    }
}

extension ToolMenuView {
    /// More's menu: the overflow Tools, each tap arming it (row() closes the menu)
    @ViewBuilder func overflowRows() -> some View {
        ForEach(MarkupToolbar.shared.overflow, id: \.self) { t in
            row(t.title, icon: t.icon, on: false) { AppDelegate.shared?.trigger(t) }
        }
    }
}
