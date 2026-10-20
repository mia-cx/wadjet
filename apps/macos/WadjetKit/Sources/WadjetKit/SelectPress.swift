import CoreGraphics
import Foundation

/// What a press with Select does once it has missed the selection's grips,
/// after Adobe Illustrator's Selection tool: a press on an Annotation grabs
/// it, and only a press on empty canvas starts a marquee. "On" means the
/// hit-test `LayerStack.topmost` uses: the stroke widened by the tolerance,
/// plus the filled area (filled shapes, Text, images, counters, Censors).
/// A hollow shape's empty middle is empty canvas, and a locked or hidden
/// Annotation is never grabbed, so a press on one falls through to what lies
/// beneath it or to the canvas.
public struct SelectPress: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// the drag that follows moves every selected Annotation
        case move
        /// the drag that follows draws a marquee; `adding` (Shift) keeps the
        /// selection and adds to it
        case marquee(adding: Bool)
        /// a Shift-press that took its Annotation out of the selection: the
        /// drag that follows does nothing
        case none
    }

    /// the selection once the press lands
    public var selection: AnnotationSelection
    public var action: Action
    /// the Annotation the press landed on, nil on empty canvas
    public var hit: Annotation.ID?

    public init(selection: AnnotationSelection, action: Action, hit: Annotation.ID?) {
        self.selection = selection
        self.action = action
        self.hit = hit
    }

    /// a press at `p` over `annotations` (back to front) with `selection`
    /// already made; `shift` is Shift held at the press. A plain press on a
    /// selected Annotation keeps the whole selection, even when an unselected
    /// one lies over it there, so the drag moves what is selected; a plain
    /// press on another Annotation selects it alone. Shift toggles the
    /// topmost Annotation under the press, and the drag moves the selection
    /// when the toggle added it.
    public static func resolve(at p: CGPoint, in annotations: [Annotation],
                               selection: AnnotationSelection, shift: Bool,
                               tolerance: CGFloat) -> SelectPress {
        let under = annotations.reversed().filter {
            $0.isSelectable && PathGeometry.hitTest($0, at: p, tolerance: tolerance)
        }
        if !shift, let member = under.first(where: { selection.contains($0.id) }) {
            return SelectPress(selection: selection, action: .move, hit: member.id)
        }
        guard let hit = under.first?.id else {
            return SelectPress(selection: selection.clicking(nil, shift: shift),
                               action: .marquee(adding: shift), hit: nil)
        }
        let next = selection.clicking(hit, shift: shift)
        return SelectPress(selection: next, action: next.contains(hit) ? .move : .none, hit: hit)
    }
}
