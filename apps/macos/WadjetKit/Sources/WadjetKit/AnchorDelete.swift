import Foundation

/// Delete on points, after Illustrator (only the chosen points go) and
/// Affinity (the path stays whole): the neighbours join with one segment
/// that keeps their handles as they were. Direct Select deletes its
/// selected anchors, the Draw Tool its active one — both through here.
extension LayerStack {
    /// removes the anchors at `indices` from `id` and joins their
    /// neighbours (`Annotation.removingAnchors`), attachments renumbered
    /// (`replaceRemovingAnchors`); an Annotation left too short to draw —
    /// a Line losing an end, a path under two nodes — goes whole. True
    /// when it's still there.
    @discardableResult
    public mutating func removeAnchors(_ indices: Set<Int>, of id: Annotation.ID) -> Bool {
        guard let a = annotations.first(where: { $0.id == id }) else { return false }
        guard let kept = a.removingAnchors(indices) else {
            remove(id: id)
            return false
        }
        replaceRemovingAnchors(kept, removed: indices)
        return true
    }

    /// the Draw Tool's Delete on its active anchor `i` of `id`: that point
    /// goes, and the anchor that goes active next is returned, so repeated
    /// Delete keeps deleting points — the previous one, or the new start
    /// when the start went (a closed path wraps to its last). nil when the
    /// Annotation went whole.
    public mutating func deleteActiveAnchor(_ i: Int, of id: Annotation.ID) -> Int? {
        guard removeAnchors([i], of: id), case let .path(d)? = annotations.first(where: { $0.id == id })?.kind,
              !d.nodes.isEmpty else { return nil }
        if i > 0 { return min(i - 1, d.nodes.count - 1) }
        return d.closed ? d.nodes.count - 1 : 0
    }
}
