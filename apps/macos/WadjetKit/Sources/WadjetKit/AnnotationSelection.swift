import CoreGraphics
import Foundation

/// Which Annotations are selected, in the order they joined the selection.
/// A value, so a controller can compare the old and new selection and tell
/// its observers. The rules for what a press, a marquee, or Select All does
/// follow Adobe Illustrator's Selection tool.
public struct AnnotationSelection: Equatable, Sendable, Sequence {
    public private(set) var ids: [Annotation.ID]

    /// duplicates keep their first place
    public init(_ ids: some Sequence<Annotation.ID> = [Annotation.ID]()) {
        var seen = Set<Annotation.ID>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public var set: Set<Annotation.ID> { Set(ids) }
    /// the one selected Annotation, nil when none or several are
    public var single: Annotation.ID? { ids.count == 1 ? ids[0] : nil }
    public func contains(_ id: Annotation.ID) -> Bool { ids.contains(id) }
    public func makeIterator() -> IndexingIterator<[Annotation.ID]> { ids.makeIterator() }

    public func adding(_ more: some Sequence<Annotation.ID>) -> AnnotationSelection {
        AnnotationSelection(ids + Array(more))
    }
    public func removing(_ id: Annotation.ID) -> AnnotationSelection {
        AnnotationSelection(ids.filter { $0 != id })
    }
    /// in if it was out, out if it was in
    public func toggling(_ id: Annotation.ID) -> AnnotationSelection {
        contains(id) ? removing(id) : adding([id])
    }
    /// only the ids still in `annotations` that can be selected — undo or the
    /// Layers window can delete, hide, or lock a selected Annotation
    public func pruned(to annotations: [Annotation]) -> AnnotationSelection {
        let selectable = Set(annotations.filter(\.isSelectable).map(\.id))
        return AnnotationSelection(ids.filter(selectable.contains))
    }

    /// a Select press, given the topmost Annotation under the pointer: Shift
    /// toggles it in or out; a plain press on a selected Annotation keeps the
    /// whole selection, so the drag that follows moves all of it; a plain press
    /// on another Annotation selects it alone; on empty canvas a plain press
    /// deselects and a Shift press changes nothing
    public func clicking(_ hit: Annotation.ID?, shift: Bool) -> AnnotationSelection {
        switch (hit, shift) {
        case let (hit?, true): toggling(hit)
        case (nil, true): self
        case let (hit?, false): contains(hit) ? self : AnnotationSelection([hit])
        case (nil, false): AnnotationSelection()
        }
    }

    /// a marquee drag released over `rect`: every selectable Annotation it
    /// touches, back to front, added to this selection when `adding` (Shift)
    public func marquee(_ rect: CGRect, in annotations: [Annotation], adding: Bool) -> AnnotationSelection {
        let touched = Self.touched(by: rect, in: annotations)
        return adding ? self.adding(touched) : AnnotationSelection(touched)
    }

    /// every Annotation a marquee over `rect` touches: its painted area (fill,
    /// stroke, ends) overlaps the rect, so a hollow shape's empty middle doesn't count
    public static func touched(by rect: CGRect, in annotations: [Annotation]) -> [Annotation.ID] {
        let r = CGPath(rect: rect.standardized, transform: nil)
        return annotations.filter { a in
            guard a.isSelectable else { return false }
            let area = PathGeometry.coverage(for: a)
            // a hairline with nothing painted (no stroke colour) still has a path to touch
            return area.isEmpty ? PathGeometry.path(for: a).intersects(r) : area.intersects(r)
        }.map(\.id)
    }

    /// Select All: every Annotation that isn't locked or hidden, back to front
    public static func all(in annotations: [Annotation]) -> AnnotationSelection {
        AnnotationSelection(annotations.filter(\.isSelectable).map(\.id))
    }
}

extension Annotation {
    /// neither hidden nor locked — what a click, marquee, or Select All can pick
    public var isSelectable: Bool { !hidden && !locked }
}
