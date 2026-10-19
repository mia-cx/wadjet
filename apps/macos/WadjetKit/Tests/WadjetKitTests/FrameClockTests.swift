import CoreMedia
import Testing
import WadjetKit

struct FrameClockTests {
    private static func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
    private static func n(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1_000_000_000) }

    // Proves a captured frame overtaken by a refresh is held back and caught up one interval later.
    @Test func lateCapturedFrameCatchesUp() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        let a = clock.admit(Self.t(10.000))
        let r = clock.admit(Self.t(10.050)) // a refresh goes out at now
        let b = clock.admit(Self.t(10.040)) // captured B lands within the interval
        #expect(a && r && !b)
        #expect(clock.wait(from: Self.t(10.040)) == Self.t(10.050 + 1.0 / 30.0) - Self.t(10.040))
        let c = clock.admit(Self.t(10.050 + 1.0 / 30.0))
        #expect(c)
    }

    // Proves interleaved refreshes never add time: the video lasts exactly the Recording's
    // unpaused time.
    @Test func interleaveKeepsRecordingDuration() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        var timeline = RecordingTimeline()
        var offers: [CMTime] = []
        for k in 0..<300 { // 10 s at 30 fps
            offers.append(Self.t(100 + Double(k) / 30.0))
            offers.append(Self.t(100 + Double(k) / 60.0 + 0.001))
        }
        offers.sort()
        var didPause = false, didResume = false
        var out: [CMTime] = []
        for offer in offers {
            let s = CMTimeGetSeconds(offer)
            if !didPause && s >= 103.0 { timeline.pause(at: Self.t(103.0)); didPause = true }
            if didPause && !didResume && s >= 104.0 { timeline.resume(at: Self.t(104.0)); didResume = true }
            guard clock.admit(offer), let o = timeline.outputTime(for: offer) else { continue }
            out.append(o)
        }
        for (a, b) in zip(out, out.dropFirst()) { #expect(b > a) }
        let end = timeline.endTime(at: Self.t(110.0))
        #expect(abs(CMTimeGetSeconds(end!) - 9.0) < 1e-4)
    }

    // Proves an Annotation edit made while paused reaches the video right after resume,
    // even off the frame grid.
    @Test func offGridResumeRefreshIsAdmitted() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        var timeline = RecordingTimeline()
        let first = clock.admit(Self.t(100.000))
        #expect(first)
        #expect(timeline.outputTime(for: Self.t(100.000)) == .zero)
        let prePause = clock.admit(Self.t(101.000))
        #expect(prePause)
        let second = timeline.outputTime(for: Self.t(101.000))
        #expect(abs(CMTimeGetSeconds(second!) - 1.0) < 1e-4)
        timeline.pause(at: Self.n(101.010))
        let midPause = clock.admit(Self.n(101.500)) // an edit mid-pause: write offered, timeline drops it
        #expect(midPause)
        #expect(timeline.outputTime(for: Self.n(101.500)) == nil)
        timeline.resume(at: Self.n(102.010))
        let atResume = clock.admit(Self.n(102.015)) // the resume refresh goes out off-grid
        #expect(atResume)
        let resumed = timeline.outputTime(for: Self.n(102.015))
        #expect(resumed != nil)
        #expect(abs(CMTimeGetSeconds(resumed!) - 1.015) < 1e-4)
    }

    // Proves nothing waits or shifts before the first write.
    @Test func clockBeforeAnyWrite() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        #expect(clock.wait(from: .zero) == .zero)
        let first = clock.admit(Self.t(42))
        #expect(first)
    }
}
