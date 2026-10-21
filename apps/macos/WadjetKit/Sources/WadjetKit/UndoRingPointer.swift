import CoreGraphics

/// The pointer over a collapsed island that carries a Clear's Undo ring
/// (ClearUndo). Elsewhere on the island hover expands it as always; on the
/// ring it stays collapsed, so a click there can undo the Clear. After that
/// click the island holds collapsed until the pointer leaves, so the restored
/// count island doesn't open under a resting pointer; Undo rebuilds the
/// island's view, so the caller carries that hold into the new one with
/// `init(held:)`. Any pointer on the island still pauses the ring.
public struct UndoRingPointer: Equatable, Sendable {
    /// the pointer is on the island (its hover rect)
    public private(set) var inside = false
    /// the pointer is on the ring's click target
    public private(set) var onRing = false
    /// a ring click undid the Clear and the pointer hasn't left since
    private var spent = false

    /// `held`: a ring click's hold carried over from the view this one replaced
    public init(held: Bool = false) { spent = held }

    /// a ring click holds the island collapsed until the pointer leaves
    public var held: Bool { spent }

    /// the pointer moved; `onRing` only while the collapsed island shows a ring
    public mutating func moved(inside: Bool, onRing: Bool) {
        self.inside = inside
        self.onRing = inside && onRing
        if !inside { spent = false }
    }
    /// a click on the ring: undo the Clear (the caller does it). True when the
    /// click counts, that is the pointer is on the ring
    public mutating func clickedRing() -> Bool {
        guard onRing else { return false }
        spent = true
        return true
    }
    /// hover expands the island
    public var expands: Bool { inside && !onRing && !spent }

    /// the ring's click target: its frame grown to at least `minSide` points
    /// each way about its centre, kept inside the island
    public static func target(ring: CGRect, island: CGRect, minSide: CGFloat = 24) -> CGRect {
        guard !ring.isNull, !ring.isEmpty else { return .null }
        let dx = max(0, (minSide - ring.width) / 2), dy = max(0, (minSide - ring.height) / 2)
        return ring.insetBy(dx: -dx, dy: -dy).intersection(island)
    }
}
