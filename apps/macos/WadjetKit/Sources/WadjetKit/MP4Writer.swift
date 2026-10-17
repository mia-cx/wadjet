import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum MP4WriterError: LocalizedError {
    case cannotAddInput, writerFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .cannotAddInput: "the asset writer rejected the video input"
        case .writerFailed(let e): e?.localizedDescription ?? "the asset writer failed"
        }
    }
}

/// An H.264 .mp4 writer over AVAssetWriter with pause-aware timestamps.
/// SCStream calls back on its own queue, so everything funnels through a
/// private serial queue; frames the input can't take yet are dropped.
public final class MP4Writer: @unchecked Sendable {
    private let q = DispatchQueue(label: "wadjet.mp4writer")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var timeline = RecordingTimeline()
    private var started = false
    private var finished = false

    /// `width`/`height` must be even (H.264 4:2:0); `fps` sets the input's media timescale.
    public init(url: URL, width: Int, height: Int, fps: Int) throws {
        writer = try AVAssetWriter(url: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = CMTimeScale(fps)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw MP4WriterError.cannotAddInput }
        writer.add(input)
    }

    /// Offer a frame taken at `hostTime`. Paused or out-of-order frames drop;
    /// the first accepted frame starts the session at PTS zero. Safe from any queue.
    public func append(_ pixelBuffer: CVPixelBuffer, at hostTime: CMTime) {
        q.sync {
            guard !finished, let pts = timeline.outputTime(for: hostTime) else { return }
            if !started {
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
                started = true
            }
            guard input.isReadyForMoreMediaData else { return }
            adaptor.append(pixelBuffer, withPresentationTime: pts)
        }
    }

    public func pause(at t: CMTime) { q.sync { timeline.pause(at: t) } }
    public func resume(at t: CMTime) { q.sync { timeline.resume(at: t) } }

    /// Close the writer and return the finished file's URL. Runs after every
    /// queued frame; a recording that never produced one leaves an empty file.
    @discardableResult public func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                self.finished = true
                self.input.markAsFinished()
                if self.started {
                    self.writer.finishWriting {
                        if self.writer.status == .failed {
                            cont.resume(throwing: MP4WriterError.writerFailed(self.writer.error))
                        } else {
                            cont.resume(returning: self.writer.outputURL)
                        }
                    }
                } else {
                    self.writer.cancelWriting()
                    cont.resume(returning: self.writer.outputURL)
                }
            }
        }
    }
}
