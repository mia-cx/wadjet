/// What the modifier keys held during a Markup drag mean. ⌘ turns snapping
/// off, Control turns attaching off, ⇧ constrains (45° rays, axis locks,
/// squares). ⇧⌘ together is one chord with its own meaning: it attaches a
/// moved Annotation whole, so ⇧ doesn't constrain under it and ⌘ doesn't stop
/// snapping.
public struct DragModifiers: Equatable, Sendable {
    public var shift: Bool
    public var command: Bool
    public var control: Bool

    public init(shift: Bool = false, command: Bool = false, control: Bool = false) {
        self.shift = shift
        self.command = command
        self.control = control
    }

    /// ⇧⌘ held together
    public var attachChord: Bool { shift && command }

    /// ⇧'s constraint: a 45° ray, an axis, a square, an aspect — not under the chord
    public var constrains: Bool { shift && !command }

    /// grip, pixel and edge snapping, and snapping to attach spots: off while
    /// ⌘ is held without ⇧
    public var snaps: Bool { !command || shift }

    /// a dragged Line or path point (an end, a node, a Line's bend) may
    /// attach. Control stops it, and so does ⇧'s 45° ray: a spot would pull
    /// the point off it.
    public var attachesPoints: Bool { !control && !constrains }

    /// a moved Annotation attaches whole: only under the chord, and never with Control
    public var attachesWhole: Bool { attachChord && !control }
}
