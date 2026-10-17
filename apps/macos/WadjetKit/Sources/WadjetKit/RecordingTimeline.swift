import CoreMedia

/// Maps a recording's host-clock sample times to continuous output PTS.
/// Paused time never reaches the file: the timeline drops samples taken while
/// paused and subtracts the paused total from every later sample, so playback
/// has no gap or jump. The first accepted sample maps to zero.
public struct RecordingTimeline: Sendable {
    /// The host time of the first accepted sample — output time's epoch.
    private var origin: CMTime?
    /// Wall time spent paused so far.
    private var pausedTotal = CMTime.zero
    private var pauseStart: CMTime?
    /// Last emitted output time; anything at or before it is dropped.
    private var lastOut = CMTime.negativeInfinity

    public init() {}

    /// Begin a paused stretch at `at`. Pausing twice, or pausing before the
    /// first sample, only notes the pause — nothing is emitted yet.
    public mutating func pause(at t: CMTime) {
        guard pauseStart == nil else { return }
        pauseStart = t
    }

    /// End the current pause; the stretch gets added to the offset. A resume
    /// without a pause is a no-op.
    public mutating func resume(at t: CMTime) {
        guard let start = pauseStart else { return }
        if t > start { pausedTotal = pausedTotal + (t - start) }
        pauseStart = nil
    }

    /// The output PTS for the moment recording stops: while paused, the time
    /// the pause began (a paused tail is absent, like the rest of the pause);
    /// never earlier than the last emitted output; nil before any sample.
    /// `endSession` stamps this on the file so a still screen's tail is kept.
    public func endTime(at t: CMTime) -> CMTime? {
        guard let origin else { return nil }
        let end = (pauseStart ?? t) - origin - pausedTotal
        return max(end, lastOut)
    }

    /// The output PTS for a sample taken at host time `sample`, or nil to drop
    /// it: samples during a pause, and any sample whose output time would not
    /// increase (late or duplicated frames).
    public mutating func outputTime(for sample: CMTime) -> CMTime? {
        if pauseStart != nil { return nil }
        guard let origin else {
            origin = sample
            lastOut = .zero
            return .zero
        }
        let out = sample - origin - pausedTotal
        guard out > lastOut else { return nil }
        lastOut = out
        return out
    }
}
