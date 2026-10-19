import CoreMedia

/// Stamps Record Window writes so captured and recomposited frames interleave: each write lands at
/// least one frame interval after the previous one, so the timeline never drops a late captured frame.
public struct FrameClock: Sendable {
    public let interval: CMTime
    private var last: CMTime?
    public init(interval: CMTime) { self.interval = interval }

    /// the time to write a frame offered at `t` (a captured frame's PTS, or now for a refresh): `t`,
    /// or one interval after the last write if that's later; records it as the last write
    public mutating func stamp(_ t: CMTime) -> CMTime {
        let s = last.map { max(t, $0 + interval) } ?? t
        last = s
        return s
    }

    /// how long a refresh requested at `now` waits so its write lands one interval after the last; zero before any write
    public func wait(from now: CMTime) -> CMTime {
        last.map { max(.zero, $0 + interval - now) } ?? .zero
    }
}
