import CoreMedia
import Testing
import WadjetKit

struct FrameClockTests {
    // Proves a captured frame delivered after a refresh, with an earlier PTS, still reaches the video.
    @Test func stampedWritesInterleave() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        var timeline = RecordingTimeline()
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

        let a = clock.stamp(t(10.000)) // captured A at its own PTS
        #expect(CMTimeGetSeconds(a) == 10.0)
        let r = clock.stamp(t(10.050)) // a refresh writes at now
        #expect(CMTimeGetSeconds(r) == 10.05)
        // the next write was just taken: a refresh at 10.060 waits one interval minus the elapsed 0.010
        #expect(abs(CMTimeGetSeconds(clock.wait(from: t(10.060))) - (1.0 / 30.0 - 0.010)) < 0.0001)
        let b = clock.stamp(t(10.040)) // captured B, PTS behind the refresh
        #expect(abs(CMTimeGetSeconds(b) - (10.05 + 1.0 / 30.0)) < 0.0001)

        var last: CMTime?
        for s in [a, r, b] {
            #expect(timeline.outputTime(for: s) != nil)
            if let last { #expect(s > last) }
            last = s
        }
    }

    // Proves nothing waits or shifts before the first write.
    @Test func clockBeforeAnyWrite() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        #expect(clock.wait(from: .zero) == .zero)
        #expect(clock.stamp(CMTime(seconds: 42, preferredTimescale: 600)) == CMTime(seconds: 42, preferredTimescale: 600))
    }
}
