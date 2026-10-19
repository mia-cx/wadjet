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

/// Record Window captures the window alone, so the Annotations are composited onto each
/// frame here; runs only on the stream's sample queue.
final class WindowAnnotationOverlay: @unchecked Sendable {
    let windowID: CGWindowID
    private var last: WindowFrameAnnotator?
    init(windowID: CGWindowID) { self.windowID = windowID }

    func draw(on sb: CMSampleBuffer, pixels pb: CVPixelBuffer) {
        let annotations = MarkupController.onScreen.annotations
        guard !annotations.isEmpty,
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: Any],
              let window = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let contentDict = attachments.first?[.contentRect] as? [String: Any],
              let contentRect = CGRect(dictionaryRepresentation: contentDict as CFDictionary),
              let scaleFactor = (attachments.first?[.scaleFactor] as? NSNumber)?.doubleValue
        else { return }
        let frame = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        guard let annotator = WindowFrameAnnotator(window: window,
                                                 primaryHeight: CGDisplayBounds(CGMainDisplayID()).height,
                                                 contentRect: contentRect,
                                                 scaleFactor: CGFloat(scaleFactor),
                                                 frame: frame) else { return }
        if annotator != last {
            last = annotator
            Task { @MainActor in
                AppLog.line("record window: annotations at transform=\(annotator.transform) clip=\(annotator.clip)")
            }
        }
        annotator.draw(annotations, on: pb)
    }
}
