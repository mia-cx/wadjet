import AppKit
import ScreenCaptureKit
import WadjetKit

extension AppDelegate {
    /// Snapshots capture options and Markup before closing the overlay. Full clean
    /// displays become the editable Canvas; only its flattened crop enters the Workflow.
    func captureScreenshot(rect: CGRect, on display: Int, windowID: CGWindowID? = nil) {
        let state = AppState.shared
        let frozen = Freeze.shared.displays
        guard let tool = state.tool, display < frozen.count else { return }
        let screen = frozen[display].screen
        let crop = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let radius = windowID.flatMap { overlayCtrl.cornerRadii[$0] }
        let scale = screen.backingScaleFactor
        let annotations = MarkupController.shared.stack
        let workflow = takeShotWorkflow()
        let cursor = state.shotCursor, wadjet = state.shotWadjet
        let clear = state.config.value.markup.clearAfterScreenshot
        let live = !overlayCtrl.showsFrozen
        let redact = tool.captureSettings.map { state.config.value.tools[keyPath: $0].smartRedact } ?? false
        let categories = smartRedactCategories
        let redactStyle = MarkupStyles.shared.style(for: .censor)
        let capturedAt = Date()
        let screens = frozen.map(\.screen)
        let displays = frozen.compactMap { fd -> CapturedCanvasDisplay? in
            guard let id = fd.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return CapturedCanvasDisplay(display: .init(id: id, frame: fd.screen.frame, scaleFactor: fd.screen.backingScaleFactor),
                image: fd.output(hdr: true))
        }
        var excluded = Set(overlayCtrl.panels.map(\.windowNumber))
        excluded.formUnion(overlayCtrl.toolbarPanels.values.map(\.windowNumber))
        excluded.formUnion(overlayCtrl.recBubblePanels.values.map(\.windowNumber))
        excluded.formUnion(overlayCtrl.dyingBubbles.values.map(\.windowNumber))
        excluded.formUnion(MarkupController.shared.windowNumbers)
        if let menu = overlayCtrl.menuPanel { excluded.insert(menu.windowNumber) }
        overlayCtrl.closeAll()
        Task { @MainActor in
            do {
                let displays = live
                    ? try await overlayCtrl.captureCanvasDisplays(screens, excluding: excluded, cursor: cursor, wadjet: wadjet)
                    : displays
                var canvas = CanvasDocument(capturedDisplays: displays, crop: crop, cornerRadius: radius ?? 0,
                    annotations: annotations, windowCapture: windowID != nil)
                if let windowID {
                    if let image = await captureWindow(id: windowID, screen: screen, cursor: cursor) {
                        // A window capture keeps its unobscured contents, including
                        // portions offscreen. The clean displays remain available for recropping.
                        canvas.setCapturedWindow(image, cornerRadius: radius)
                    } else {
                        AppLog.line("window \(windowID) not capturable; falling back to clean display crop")
                    }
                }
                if redact {
                    let boxes = try await SmartRedact.boxes(
                        in: [.init(image: canvas.flatten(scale: scale), frame: canvas.crop)],
                        categories: categories)
                    SmartRedact.censors(covering: boxes, style: redactStyle, existing: canvas.layerStack)
                        .forEach { canvas.layerStack.add($0) }
                }
                try writeScreenshot(canvas, scale: scale, capturedAt: capturedAt, clear: clear,
                    label: "\(tool.title) \(Int(rect.width))×\(Int(rect.height))", workflow: workflow)
            } catch {
                AppLog.line("Screenshot Canvas: \(error.localizedDescription)")
            }
        }
    }

    /// Writes both outputs before Clear after Screenshot can discard the editable layers.
    func writeScreenshot(_ canvas: CanvasDocument, scale: CGFloat, capturedAt: Date, clear: Bool,
                         label: String, workflow: String) throws {
        let shot = try canvasStore.addScreenshot(canvas, files: captureFiles, scale: scale,
            createdAt: capturedAt)
        if clear { clearAnnotations() }
        runCapture(file: shot.file, kind: .screenshot, label: label, workflow: workflow,
            runID: shot.id, capturedAt: capturedAt, canvas: shot.package)
    }
}

extension OverlayController {
    /// Live-screen Screenshots refresh every display at confirm, leaving Markup
    /// panels out even when closeAll has rebuilt the desktop chrome.
    func captureCanvasDisplays(_ screens: [NSScreen], excluding: Set<Int>, cursor: Bool,
                               wadjet: Bool) async throws -> [CapturedCanvasDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var captures: [CapturedCanvasDisplay] = []
        for screen in screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError("no shareable display for \(screen.localizedName)")
            }
            let filter: SCContentFilter
            if wadjet {
                let excluded = excluding.union(toolbarPanels.values.map(\.windowNumber))
                    .union(MarkupController.shared.windowNumbers)
                filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains(Int($0.windowID)) })
            } else {
                filter = SCContentFilter(display: display,
                    excludingApplications: content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier },
                    exceptingWindows: [])
            }
            let scale = screen.backingScaleFactor
            let output = try await screenshot(display, width: Int((screen.frame.width * scale).rounded()),
                height: Int((screen.frame.height * scale).rounded()), cursor: cursor,
                hdr: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1, filter: filter)
            guard let image = output.hdr ?? output.sdr else { throw CaptureError("display capture returned no image") }
            captures.append(.init(display: .init(id: id, frame: screen.frame, scaleFactor: scale), image: image))
        }
        return captures
    }
}
