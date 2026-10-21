import Foundation

/// Layer operations on several Annotations at once — a multi-selection's
/// restack and delete
extension LayerStack {
    /// Bring Forward / Send Backward move each Annotation in `ids` one step
    /// past its unselected neighbour, so a selection that already leads stays
    /// put; to the front or back moves them all there. Either way the moved
    /// Annotations keep their order among themselves, as Illustrator does.
    public mutating func restack(_ ids: Set<Annotation.ID>, _ move: Restack) {
        let picked = { (a: Annotation) in ids.contains(a.id) }
        switch move {
        case .front:
            annotations = annotations.filter { !picked($0) } + annotations.filter(picked)
        case .back:
            annotations = annotations.filter(picked) + annotations.filter { !picked($0) }
        case .up:
            for i in stride(from: annotations.count - 2, through: 0, by: -1)
            where picked(annotations[i]) && !picked(annotations[i + 1]) {
                annotations.swapAt(i, i + 1)
            }
        case .down:
            for i in stride(from: 1, to: annotations.count, by: 1)
            where picked(annotations[i]) && !picked(annotations[i - 1]) {
                annotations.swapAt(i, i - 1)
            }
        }
    }

    /// removes every Annotation in `ids`; counter sequences close each gap
    public mutating func remove(ids: some Sequence<Annotation.ID>) {
        for id in ids { remove(id: id) }
    }
}
