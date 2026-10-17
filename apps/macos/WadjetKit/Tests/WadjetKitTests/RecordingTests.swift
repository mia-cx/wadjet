import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import WadjetKit

/// An event list: pause p, resume r, or a sample at t (all seconds).
enum Ev {
    case pause(Double), resume(Double), sample(Double)
}

private func run(_ events: [Ev]) -> [Double?] {
    var tl = RecordingTimeline()
    var out: [Double?] = []
    for e in events {
        switch e {
        case .pause(let t): tl.pause(at: CMTime(seconds: t, preferredTimescale: 600))
        case .resume(let t): tl.resume(at: CMTime(seconds: t, preferredTimescale: 600))
        case .sample(let t):
            out.append(tl.outputTime(for: CMTime(seconds: t, preferredTimescale: 600)).map { $0.seconds })
        }
    }
    return out
}

@Test("timeline maps samples to continuous output", arguments: [
    // straight pass-through, rebased to the first sample
    ([Ev.sample(10), .sample(10 + 1.0 / 30), .sample(10.5)], [0.0, 1.0 / 30, 0.5] as [Double?]),
    // a paused stretch is gone from the output
    ([.sample(0), .sample(0.4), .pause(0.5), .sample(0.6), .resume(1.5), .sample(1.6)],
     [0.0, 0.4, nil, 0.6] as [Double?]),
    // a pause straddling no samples still shifts later ones
    ([.sample(0), .pause(0.5), .resume(2.5), .sample(2.6)], [0.0, 0.6] as [Double?]),
    // several pauses accumulate
    ([.sample(0), .pause(1), .resume(2), .sample(2.1), .pause(3), .resume(5), .sample(5.2)],
     [0.0, 1.1, 2.2] as [Double?]),
    // pause before the first sample just delays the epoch
    ([.pause(0), .resume(10), .sample(20)], [0.0] as [Double?]),
    // double pause / resume without pause / samples at the boundary drop
    ([.sample(0), .pause(1), .pause(1.5), .resume(2), .resume(2.1), .sample(2.1), .sample(2.1), .sample(2.2)],
     [0.0, 1.1, nil, 1.2] as [Double?]),
    // a late or duplicated sample is dropped, never emitted backwards
    ([.sample(5), .sample(4), .sample(5), .sample(6)], [0.0, nil, nil, 1.0] as [Double?]),
])
func timeline(_ events: [Ev], _ expected: [Double?]) {
    let got = run(events)
    #expect(got.count == expected.count)
    for (g, e) in zip(got, expected) {
        if let g, let e { #expect(abs(g - e) < 0.001) } else { #expect(g == nil && e == nil) }
    }
}

// MARK: - MP4Writer

private func makePixelBuffer(_ w: Int, _ h: Int, seed: UInt8) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let pb else { throw NSError(domain: "test", code: 1) }
    CVPixelBufferLockBaseAddress(pb, [])
    let bytes = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(CVPixelBufferGetBytesPerRow(pb) * h) { bytes[i] = seed &+ UInt8(truncatingIfNeeded: i) }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

@Test func writerDropsThePausedStretch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("r.mp4")

    let writer = try MP4Writer(url: url, width: 320, height: 240, fps: 30)
    // Two seconds of 30 fps host clock; paused 0.5s→1.5s.
    var seed: UInt8 = 0
    for frame in 0..<60 {
        let t = Double(frame) / 30
        if frame == 15 { writer.pause(at: CMTime(seconds: 0.5, preferredTimescale: 600)) }
        if frame == 45 { writer.resume(at: CMTime(seconds: 1.5, preferredTimescale: 600)) }
        writer.append(try makePixelBuffer(320, 240, seed: seed), at: CMTime(seconds: t, preferredTimescale: 600))
        seed &+= 7
    }
    let out = try await writer.finish()

    let asset = AVURLAsset(url: out)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 1.0) < 1.0 / 15) // one second of output, ±2 frames

    // Every emitted sample's PTS: contiguous, no jump across the pause.
    let reader = try AVAssetReader(asset: asset)
    let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(ro)
    #expect(reader.startReading())
    var pts: [Double] = []
    while let sb = ro.copyNextSampleBuffer() {
        pts.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }
    let maxGap = zip(pts, pts.dropFirst()).map { $1 - $0 }.max() ?? 0
    #expect(pts.count >= 29 && pts.count <= 31)
    #expect(maxGap <= 1.5 / 30)
}
