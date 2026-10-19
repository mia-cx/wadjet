import CoreMedia
import Testing
import WadjetKit

struct FrameClockTests {
    private static func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    // Proves a captured frame overtaken by a refresh is skipped, and the catch-up write
    // lands in the next slot.
    @Test func skippedFrameCatchesUpInNextSlot() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        #expect(clock.stamp(Self.t(10.000)) == Self.t(10.000))
        let r = clock.stamp(Self.t(10.050))
        #expect(abs(CMTimeGetSeconds(r!) - (10.0 + 1.0 / 30.0)) < 1e-4) // slot 1
        #expect(clock.stamp(Self.t(10.040)) == nil) // slot 1 already taken
        #expect(clock.wait(from: Self.t(10.040)) == Self.t(10.0 + 2.0 / 30.0) - Self.t(10.040))
        let c = clock.stamp(Self.t(10.0 + 2.0 / 30.0))
        #expect(abs(CMTimeGetSeconds(c!) - (10.0 + 2.0 / 30.0)) < 1e-4) // slot 2
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
        var lastStamp: CMTime?
        var out: [CMTime] = []
        for offer in offers {
            let s = CMTimeGetSeconds(offer)
            if !didPause && s >= 103.0 { timeline.pause(at: Self.t(103.0)); didPause = true }
            if didPause && !didResume && s >= 104.0 { timeline.resume(at: Self.t(104.0)); didResume = true }
            guard let stamp = clock.stamp(offer) else { continue }
            #expect(stamp <= offer)
            if let lastStamp { #expect(stamp > lastStamp) }
            lastStamp = stamp
            if let o = timeline.outputTime(for: stamp) { out.append(o) }
        }
        for (a, b) in zip(out, out.dropFirst()) { #expect(b > a) }
        let end = timeline.endTime(at: Self.t(110.0))
        #expect(abs(CMTimeGetSeconds(end!) - 9.0) < 1e-4)
    }

    // Proves nothing waits or shifts before the first write.
    @Test func clockBeforeAnyWrite() {
        var clock = FrameClock(interval: CMTime(value: 1, timescale: 30))
        #expect(clock.wait(from: .zero) == .zero)
        #expect(clock.stamp(Self.t(42)) == Self.t(42))
    }
}
