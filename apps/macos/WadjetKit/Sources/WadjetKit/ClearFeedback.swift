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
    /// how long ⌘Z still restores a Clear that dismissed the island
    public static let undoGrace: TimeInterval = 6
    /// the "nothing to clear" shake: a horizontal offset for progress 0...1 —
    /// three swings of at most `distance` points that die out, 0 at both ends
    public static func shakeOffset(progress p: Double, distance: Double = 4) -> Double {
        guard p > 0, p < 1 else { return 0 }
        return distance * sin(p * 3 * 2 * .pi) * (1 - p)
    }
}

/// The window after a dismissing Clear in which its undo step survives the
/// closed toolbar. History normally ends once the toolbar is closed and the
/// stack is empty; while the grace is open it doesn't, and ⌘Z stays bound.
public struct UndoGrace: Equatable, Sendable {
    private var until: Date?
    public init() {}
    public mutating func open(at now: Date, for seconds: TimeInterval = ClearFeedback.undoGrace) {
        until = now.addingTimeInterval(seconds)
    }
    public mutating func close() { until = nil }
    public func isOpen(at now: Date) -> Bool { until.map { now < $0 } ?? false }
}
