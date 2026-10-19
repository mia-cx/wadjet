import AppKit
import CoreMedia
import ScreenCaptureKit
import WadjetKit

extension Tool {
    /// whether this Tool opens on a Freeze Frame right now: during a Recording, Markup draws on the
    /// live screen so the video keeps moving. #105's Freeze Frame policy replaces this.
    @MainActor var opensFreezeFrame: Bool { kind != .markup || !AppState.shared.recActive }
}

extension OverlayController {
    /// Markup on the live screen: the toolbar comes up, or stays, with `tool` armed and no Freeze Frame
    func showLiveToolbar(armed tool: Tool) {
        let s = AppState.shared
        // stay active: the armed Tool needs the pointer's cursor, and syncArmed records whose focus we took
        let prev = prevFrontmost; prevFrontmost = nil
        dropFreezeFrame()
        prevFrontmost = prev
        s.tool = tool; s.triggerWorkflow = nil // a cancelled Freeze Frame takes its Shortcut's Workflow pick with it
        AppLog.line("markup: live toolbar with \(tool.title)")
    }
}

/// Record Window's writer path: composites the Annotations onto each captured frame, and
/// recomposites the last frame when they change, since a still window sends no new frames.
/// Its state lives on the recording queue.
final class WindowAnnotationOverlay: @unchecked Sendable {
    let windowID: CGWindowID
    private let writer: MP4Writer
    private let queue: DispatchQueue
    private let interval: CMTime
    private let compositor = WindowFrameCompositor()
    private var pending = false
    private var lastWrite = CMTime.zero
    private var lastMapping: WindowFrameAnnotator?
    // the captured frame's own placement values, kept for refresh-time compositing
    private var contentRect: CGRect = .zero
    private var scaleFactor: CGFloat = 0
    private var frameSize: CGSize = .zero

    init(windowID: CGWindowID, writer: MP4Writer, queue: DispatchQueue, fps: Int) {
        self.windowID = windowID
        self.writer = writer
        self.queue = queue
        interval = CMTime(value: 1, timescale: CMTimeScale(fps))
    }

    /// a complete captured frame (called on `queue` from RecOutput): remember it, write it composited
    func write(_ sb: CMSampleBuffer, pixels pb: CVPixelBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
              let contentDict = attachments.first?[.contentRect] as? [String: Any],
              let contentRect = CGRect(dictionaryRepresentation: contentDict as CFDictionary),
              let scaleFactor = (attachments.first?[.scaleFactor] as? NSNumber)?.doubleValue
        else { writer.append(pb, at: pts); return }
        compositor.capture(pb, contentRect: contentRect, scaleFactor: CGFloat(scaleFactor))
        self.contentRect = contentRect
        self.scaleFactor = CGFloat(scaleFactor)
        frameSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        writer.append(compose() ?? pb, at: pts)
        lastWrite = pts
    }

    /// the Annotations changed, or the Recording resumed: rewrite the last frame with them,
    /// at most once per frame interval. Safe from any thread.
    func refresh() {
        queue.async { [self] in
            guard !pending else { return }
            pending = true
            let wait = max(0, CMTimeGetSeconds(lastWrite + interval - CMClockGetTime(CMClockGetHostTimeClock())))
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                pending = false
                guard let out = compose() else { return }
                let t = CMClockGetTime(CMClockGetHostTimeClock())
                writer.append(out, at: t)
                lastWrite = t
            }
        }
    }

    /// the frame to write now: the clean base, or a copy of it with the Annotations on
    private func compose() -> CVPixelBuffer? {
        let annotations = MarkupController.onScreen.annotations
        var window = CGRect.zero
        if !annotations.isEmpty {
            if let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
               let bounds = list.first?[kCGWindowBounds as String] as? [String: Any],
               let w = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                window = w
                let annotator = WindowFrameAnnotator(window: w, primaryHeight: primaryHeight,
                                                     contentRect: contentRect,
                                                     scaleFactor: scaleFactor, frame: frameSize)
                if annotator != lastMapping {
                    lastMapping = annotator
                    if let annotator {
                        Task { @MainActor in
                            AppLog.line("record window: annotations at transform=\(annotator.transform) clip=\(annotator.clip)")
                        }
                    }
                }
            }
        }
        return compositor.compose(window: window, primaryHeight: primaryHeight, annotations: annotations)
    }
    private var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }
}
