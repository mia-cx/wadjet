import Foundation

/// How Clear Annotations answers a tap. With Annotations on screen they fade
/// out, then the clear lands; with none, the Clear cell gives a small
/// "nothing to clear" cue and nothing else happens.
public enum ClearFeedback {
    /// the Annotations' exit: opacity to 0 over `duration` with an ease-out,
    /// scaling to `endScale` about their own centre. The clear itself lands
    /// `settle` seconds after the tap, so the toolbar's lens has reached the
    /// Clear cell when the island goes.
    public struct Fade: Equatable, Sendable {
        public let duration: TimeInterval
        public let endScale: Double
        public let settle: TimeInterval
    }
    public enum Response: Equatable, Sendable {
        case nothingToClear
        case fadeOut(Fade)
    }
    /// Reduce Motion keeps a short cross-fade and drops the scale
    public static func response(annotationCount: Int, reduceMotion: Bool) -> Response {
        guard annotationCount > 0 else { return .nothingToClear }
        return .fadeOut(reduceMotion ? Fade(duration: 0.12, endScale: 1, settle: 0.16)
                                     : Fade(duration: 0.22, endScale: 0.96, settle: 0.32))
    }
    /// the "nothing to clear" shake: a horizontal offset for progress 0...1 —
    /// three swings of at most `distance` points that die out, 0 at both ends
    public static func shakeOffset(progress p: Double, distance: Double = 4) -> Double {
        guard p > 0, p < 1 else { return 0 }
        return distance * sin(p * 3 * 2 * .pi) * (1 - p)
    }
}

/// What stays undoable after a Clear lands, and for how long. ⌘Z restores it
/// for `shortcut` seconds (a global hot key, so it then goes back to the front
/// app); the toolbar's Clear cell reads Undo for `offer` seconds; and a Clear
/// that leaves no toolbar open keeps the collapsed island for `ring` seconds
/// with a ring draining to empty, then lets it go. Hovering the island pauses
/// the ring, and the Undo offer lasts at least until the ring empties. Undo,
/// or any later edit, ends it all at once. Pass the time in: the caller's
/// clock drives every answer.
public struct ClearUndo: Equatable, Sendable {
    public static let shortcut: TimeInterval = 3
    public static let ring: TimeInterval = 3
    public static let offer: TimeInterval = 6

    private var clearedAt: Date?
    private var hasRing = false
    /// time the ring spent paused before the current pause
    private var pausedFor: TimeInterval = 0
    private var pausedAt: Date?

    public init() {}

    /// a Clear is still undoable (until `end()`; ask the `at:` answers for the timing)
    public var isActive: Bool { clearedAt != nil }

    /// a Clear landed; `ring` when it left no toolbar open, so the island holds on
    public mutating func cleared(at now: Date, ring: Bool) {
        self = ClearUndo()
        clearedAt = now; hasRing = ring
    }
    /// Undo restored the Annotations, a later edit made "Undo Clear" untrue, or time ran out
    public mutating func end() { self = ClearUndo() }
    /// the pointer entered (true) or left (false) the island: the ring stops draining while it's in
    public mutating func hover(_ inside: Bool, at now: Date) {
        guard clearedAt != nil, hasRing else { return }
        if inside, pausedAt == nil, ringLeft(at: now) != nil { pausedAt = now }
        else if !inside, let p = pausedAt { pausedFor += now.timeIntervalSince(p); pausedAt = nil }
    }

    /// ⌘Z still restores the Clear
    public func takesShortcut(at now: Date) -> Bool {
        guard let c = clearedAt else { return false }
        return now.timeIntervalSince(c) < Self.shortcut
    }
    /// the Clear cell reads Undo, and the undo step outlives a closed toolbar
    public func offersUndo(at now: Date) -> Bool {
        guard let c = clearedAt else { return false }
        return now.timeIntervalSince(c) < Self.offer || ringLeft(at: now) != nil
    }
    /// the ring's share left, 1 at the Clear down to 0; nil without a ring or once it's empty
    public func ringLeft(at now: Date) -> Double? {
        guard let c = clearedAt, hasRing else { return nil }
        let drained = now.timeIntervalSince(c) - pausedFor - (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        let left = 1 - drained / Self.ring
        return left > 0 ? min(1, left) : nil
    }
    /// the ring keeps the collapsed island up
    public func holdsIsland(at now: Date) -> Bool { ringLeft(at: now) != nil }
    /// whole seconds left on the ring, counting down 3, 2, 1: Reduce Motion's text
    public func ringSeconds(at now: Date) -> Int? {
        ringLeft(at: now).map { Int(($0 * Self.ring).rounded(.up)) }
    }
    /// the next moment an answer above changes, so the caller can wake then;
    /// nil when nothing is pending or a paused ring waits on the pointer
    public func nextChange(after now: Date) -> Date? {
        guard let c = clearedAt else { return nil }
        var marks = [c.addingTimeInterval(Self.shortcut), c.addingTimeInterval(Self.offer)]
        if hasRing, pausedAt == nil { marks.append(c.addingTimeInterval(Self.ring + pausedFor)) }
        if let next = marks.filter({ $0 > now }).min() { return next }
        // past every mark, with a paused ring still holding the offer
        return nil
    }
}
