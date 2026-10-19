import CoreMedia

/// Puts Record Window writes on the recording's frame grid: one write per frame slot, stamped at its
/// slot's start, so captured and recomposited frames interleave without adding time to the video.
public struct FrameClock: Sendable {
    public let interval: CMTime
    private var origin: CMTime?
    private var lastSlot: Int64 = 0
    public init(interval: CMTime) { self.interval = interval }

    /// the slot start for a write offered at `t` (a captured frame's PTS, or now for a refresh), or nil
    /// to skip it because a write already took that slot; the first write starts the grid
    public mutating func stamp(_ t: CMTime) -> CMTime? {
        guard let origin else { origin = t; lastSlot = 0; return t }
        let slot = Int64(floor(CMTimeGetSeconds(t - origin) / CMTimeGetSeconds(interval) + 1e-6))
        guard slot > lastSlot else { return nil }
        lastSlot = slot
        return origin + Self.offset(slot, of: interval, in: origin.timescale)
    }

    /// how long until the next free slot starts; zero before any write
    public func wait(from now: CMTime) -> CMTime {
        guard let origin else { return .zero }
        return max(.zero, origin + Self.offset(lastSlot + 1, of: interval, in: origin.timescale) - now)
    }

    /// `slot` intervals in `timescale` ticks — the slot's start on the grid
    private static func offset(_ slot: Int64, of interval: CMTime, in timescale: CMTimeScale) -> CMTime {
        CMTime(value: CMTimeValue((Double(slot) * CMTimeGetSeconds(interval) * Double(timescale)).rounded()),
               timescale: timescale)
    }
}
