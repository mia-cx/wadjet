import AppKit
import WadjetKit

/// Delete under the Draw Tool with an active anchor, after Illustrator:
/// only that point goes, and its neighbours join, as Affinity keeps the path
/// whole. The geometry lives in WadjetKit's AnchorDelete.swift, shared with
/// Direct Select's `deleteAnchors`.
extension MarkupController {
    /// Delete on the Draw Tool's active anchor: the point goes as one undo
    /// step and its neighbour goes active, so the next Delete takes that one;
    /// a Line, or a path left under two points, goes whole. False with no
    /// active anchor.
    func deleteDrawAnchor() -> Bool {
        guard let i = drawAnchor, let a = single else { return false }
        var next: Int?
        edit { next = $0.deleteActiveAnchor(i, of: a.id) }
        if let next { drawAnchor = next } else { setSelection([]) }
        render()
        AppLog.line("markup: deleted the active anchor")
        return true
    }
}
