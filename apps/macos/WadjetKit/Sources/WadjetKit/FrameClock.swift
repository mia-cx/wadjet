import CoreMedia

/// Spaces Record Window writes at least one frame interval apart, each at the moment it's offered,
/// so captured and recomposited frames interleave and no write ever runs ahead of real time.
public struct FrameClock: Sendable {
    public let interval: CMTime
    private var last: CMTime?
    public init(interval: CMTime) { self.interval = interval }

    /// whether a write offered at `t` (a captured frame's PTS, or now for a refresh) may go out at `t`:
    /// false while it's within one interval of the last admitted write; records it when true
    public mutating func admit(_ t: CMTime) -> Bool {
        guard last.map({ t >= $0 + interval }) ?? true else { return false }
        last = t
        return true
    }

    /// how long until a write may go out; zero before any write
    public func wait(from now: CMTime) -> CMTime {
        last.map { max(.zero, $0 + interval - now) } ?? .zero
    }
}
