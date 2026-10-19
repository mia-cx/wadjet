import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import WadjetKit

/// one frame of a LiveSampler's area-scoped stream
struct LiveSample {
    let image: CIImage
    let rect: CGRect // global points
    let displayTime: UInt64 // mach
}

/// One low-frame-rate ScreenCaptureKit stream of part of one display, with
/// every wadjet window left out so whatever draws from it (Censor's Blur and
/// Pixelate, later Magnify) never samples itself. It runs only while something
/// watches a rect.
@MainActor final class LiveSampler {
    static let framesPerSecond: Int32 = 12
    private let screen: NSScreen
    /// wired at init, replaceable — CensorLayers binds itself after the fact
    var onSample: @MainActor (LiveSample) -> Void
    private let queue = DispatchQueue(label: "wadjet.livesampler")
    private var stream: SCStream?
    private var output: Output?
    private let delegate = StreamDelegate()
    /// the rect to stream; `applied` is the rect the running stream is really
    /// configured for — a frame lands only when its size matches it
    private var wanted: CGRect?
    private var applied: (rect: CGRect, pixels: CGSize)?
    private var busy = false
    private var warnedPermission = false
    private var latencies: [Double] = []
    /// mach ticks -> ms
    private static let tickMs: Double = {
        var i = mach_timebase_info_data_t()
        mach_timebase_info(&i)
        return Double(i.numer) / Double(i.denom) / 1e6
    }()

    init(screen: NSScreen, onSample: @escaping @MainActor (LiveSample) -> Void) {
        self.screen = screen
        self.onSample = onSample
        delegate.onStop = { [weak self] id, reason in
            Task { @MainActor in self?.streamStopped(id, reason: reason) }
        }
    }

    /// the global-point rect to stream; nil stops the stream
    func watch(_ rect: CGRect?) {
        wanted = rect.flatMap { LiveSampling.union(of: [$0], on: screen.frame) }
        // the applied stream already shows exactly this; a dropped stream
        // (applied nil) retries on this very call
        guard wanted != applied?.rect || (wanted != nil && stream == nil) else { return }
        apply()
    }

    /// at most one start/update/stop in flight; when it finishes, apply the latest wanted rect
    private func apply() {
        guard !busy else { return }
        busy = true
        let target = wanted
        Task { [weak self] in
            guard let self else { return }
            await applyNow()
            busy = false
            // re-apply only a rect that changed mid-flight — a failed attempt
            // retries on the next watch call instead of spinning
            if wanted != target { apply() }
        }
    }

    private func applyNow() async {
        guard let wanted else {
            if let stream {
                try? await stream.stopCapture()
                AppLog.line("live sampler \(screen.localizedName): stopped")
            }
            stream = nil; output = nil; applied = nil
            return
        }
        let scale = screen.backingScaleFactor
        let pixels = CGSize(width: (wanted.width * scale).rounded(),
                            height: (wanted.height * scale).rounded())
        if let stream {
            do {
                try await stream.updateConfiguration(configuration(rect: wanted, pixels: pixels))
                applied = (wanted, pixels)
                AppLog.line("live sampler \(screen.localizedName): rect \(wanted.debugDescription)")
            } catch {
                AppLog.line("live sampler: update failed: \(error.localizedDescription)")
                dropStream()
            }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            if !warnedPermission {
                warnedPermission = true
                AppLog.line("live sampler: no Screen Recording permission; Censor draws Black out")
            }
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let disp = content.displays.first(where: { $0.displayID == num }) else {
                AppLog.line("live sampler: no shareable display for \(screen.localizedName)")
                return
            }
            let wadjet = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: disp, excludingApplications: wadjet, exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration(rect: wanted, pixels: pixels),
                                  delegate: delegate)
            let output = Output { [weak self] image, time, size in
                Task { @MainActor in self?.frame(image, at: time, size: size) }
            }
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream; self.output = output
            applied = (wanted, pixels)
            AppLog.line("live sampler \(screen.localizedName): started \(wanted.debugDescription)")
        } catch {
            AppLog.line("live sampler: stream failed to start: \(error.localizedDescription)")
            dropStream()
        }
    }

    private func configuration(rect: CGRect, pixels: CGSize) -> SCStreamConfiguration {
        let conf = SCStreamConfiguration()
        conf.sourceRect = LiveSampling.sourceRect(rect, on: screen.frame)
        conf.width = Int(pixels.width); conf.height = Int(pixels.height)
        conf.pixelFormat = kCVPixelFormatType_32BGRA
        conf.showsCursor = false
        conf.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        conf.queueDepth = 3
        return conf
    }

    /// a frame on the output queue: late frames from an old rect never land
    /// — only ones matching the applied pixel size become samples
    private func frame(_ image: CIImage, at displayTime: UInt64, size: CGSize) {
        guard let applied, size == applied.pixels else { return }
        onSample(LiveSample(image: image, rect: applied.rect, displayTime: displayTime))
    }

    /// called once a sample is on screen: logs capture→present latency
    func presented(_ sample: LiveSample) {
        latencies.append(Double(mach_absolute_time() &- sample.displayTime) * Self.tickMs)
        guard latencies.count >= 120 else { return }
        let p50 = latencies.percentile(50) ?? 0, p95 = latencies.percentile(95) ?? 0
        let r = applied?.rect ?? .zero
        AppLog.line("live sampler \(screen.localizedName): p50 \(Int(p50))ms p95 \(Int(p95))ms, "
            + "\(Int(r.width))×\(Int(r.height)) pt at \(Self.framesPerSecond) fps")
        latencies = []
    }

    private func streamStopped(_ id: ObjectIdentifier, reason: String) {
        guard stream.map({ ObjectIdentifier($0) }) == id else { return }
        AppLog.line("live sampler: stream stopped: \(reason)")
        dropStream()
    }

    private func dropStream() {
        stream = nil; output = nil; applied = nil
    }

    /// The system can kill the stream; the sampler drops it and the next
    /// watch starts a fresh one.
    private final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
        var onStop: (@Sendable (ObjectIdentifier, String) -> Void)?
        func stream(_ stream: SCStream, didStopWithError error: Error) {
            onStop?(ObjectIdentifier(stream), error.localizedDescription)
        }
    }

    /// frames arrive on `queue`; everything else is on the main actor
    private final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
        let onFrame: @Sendable (CIImage, UInt64, CGSize) -> Void
        init(onFrame: @escaping @Sendable (CIImage, UInt64, CGSize) -> Void) { self.onFrame = onFrame }
        nonisolated func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                                of type: SCStreamOutputType) {
            guard type == .screen, isCompleteScreenFrame(sb),
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]]
            let t = (attachments?.first?[.displayTime] as? NSNumber)?.uint64Value ?? 0
            onFrame(CIImage(cvPixelBuffer: pb), t,
                    CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
        }
    }
}
