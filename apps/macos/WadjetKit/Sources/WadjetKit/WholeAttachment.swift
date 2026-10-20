import Foundation

extension LayerStack {
    /// replaces `a` after an edit of the Annotation itself — a resize, a
    /// rotation, a recrop — keeping it attached whole where it is now: the
    /// attachment takes the new offset and turn, so the edit holds instead
    /// of being solved back. Without a whole attachment it's `replace`.
    public mutating func replaceRebasing(_ a: Annotation) {
        guard let whole = a.attachments.first(where: { $0.point == .whole }),
              annotations.contains(where: { $0.id == whole.target }) else { return replace(a) }
        var free = a
        free.attachments = []
        replace(free)
        attach(a.id, .whole, to: whole.target, at: whole.anchor)
    }
}
