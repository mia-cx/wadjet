import AppKit
import ScreenCaptureKit
import SwiftUI
import WadjetKit

/// Keep Windows as Layers: a Screenshot can keep every on-screen app window
/// as its own Canvas layer, so the Editor can hide, move and restack them.
extension OverlayController {
    /// Every on-screen app window over `screens`, front first, captured whole
    /// (unobscured, like Capture Window) with `desktopIndependentWindow`.
    /// A floating window is kept only when it covers a kept window behind it,
    /// so the flat screen's occlusion survives; a window whose capture fails —
    /// or that ScreenCaptureKit doesn't list — keeps its flat-screen pixels
    /// through `fallback` (nil return drops it).
    func captureWindowLayers(over screens: [NSScreen], cursor: Bool, wadjet: Bool,
                             fallback: @escaping (CGRect, CGFloat) -> CGImage?) async -> [(id: CGWindowID, window: CapturedWindow)] {
        let started = Date()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            AppLog.line("window layers: \(error.localizedDescription)")
            return []
        }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let primaryH = NSScreen.screens[0].frame.height
        // CGWindowList is front-to-back; SCShareableContent's windows aren't
        // ordered, so the list supplies both the order and the frontmost hit
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
        let listed = infos.compactMap { w -> ListedWindow? in
            guard (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let level = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let wn = w[kCGWindowNumber as String] as? Int else { return nil }
            // top-left global -> AppKit global (bottom-left of the primary display)
            let frame = CGRect(x: b["X"] ?? 0, y: primaryH - (b["Y"] ?? 0) - (b["Height"] ?? 0),
                               width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return ListedWindow(id: UInt32(truncatingIfNeeded: wn), level: level, frame: frame,
                                ownedByWadjet: (w[kCGWindowOwnerPID as String] as? Int32) == getpid())
        }
        let candidates = windowLayerCandidates(listed, includeWadjet: wadjet,
                                               over: screens.map(\.frame))
            .map { (id: CGWindowID(truncatingIfNeeded: $0.id), scw: byID[CGWindowID(truncatingIfNeeded: $0.id)], frame: $0.frame) }
        // MainActor-inheriting tasks created on the actor: the SCK calls suspend
        // off-actor so the captures overlap while SCWindow never crosses a region
        let tasks = candidates.map { c in
            Task { @MainActor () -> (id: CGWindowID, window: CapturedWindow?, hdr: Bool, flat: Bool) in
                let frame = c.scw.map { CGRect(x: $0.frame.minX, y: primaryH - $0.frame.maxY,
                                               width: $0.frame.width, height: $0.frame.height) } ?? c.frame
                let hit = screens.filter { $0.frame.intersects(frame) }
                let scale = hit.map(\.backingScaleFactor).max() ?? 2
                let app = c.scw?.owningApplication?.applicationName
                let title = c.scw?.title.flatMap { $0.isEmpty ? nil : $0 }
                do {
                    guard let scw = c.scw else { throw CaptureError("not in shareable content") }
                    let hdr = hit.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
                    let cfg = SCScreenshotConfiguration()
                    cfg.width = Int((scw.frame.width * scale).rounded())
                    cfg.height = Int((scw.frame.height * scale).rounded())
                    cfg.ignoreShadows = true
                    cfg.showsCursor = cursor
                    cfg.dynamicRange = hdr ? .bothSDRAndHDR : .sdr
                    let out = try await SCScreenshotManager.captureScreenshot(
                        contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg)
                    guard let image = out.hdrImage ?? out.sdrImage else {
                        throw CaptureError("window capture returned no image")
                    }
                    return (c.id, CapturedWindow(frame: frame, image: image, app: app, title: title),
                            image.hasExtendedRange, false)
                } catch {
                    let name = app ?? "window \(c.id)"
                    guard let flat = fallback(frame, scale) else {
                        AppLog.line("window layers: \(name) failed: \(error.localizedDescription); dropped")
                        return (c.id, nil, false, false)
                    }
                    AppLog.line("window layers: \(name) failed: \(error.localizedDescription); kept its flat pixels")
                    return (c.id, CapturedWindow(frame: frame, image: flat, app: app, title: title), false, true)
                }
            }
        }
        var windows: [(id: CGWindowID, window: CapturedWindow)] = []
        var hdrCount = 0, fallbacks = 0
        for task in tasks {
            let r = await task.value
            if let w = r.window { windows.append((r.id, w)) }
            if r.hdr { hdrCount += 1 }
            if r.flat { fallbacks += 1 }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        AppLog.line("window layers: captured \(windows.count - fallbacks) of \(candidates.count) windows in \(ms) ms (\(hdrCount) HDR, \(fallbacks) from the flat screen)")
        return windows
    }
}

extension CGImage {
    /// extended colour space or real headroom: an HDR capture
    var hasExtendedRange: Bool {
        colorSpace?.name == CGColorSpace.extendedSRGB
            || colorSpace?.name == CGColorSpace.extendedLinearSRGB
            || max(contentHeadroom, calculatedContentHeadroom) > 1
    }
}

extension ToolMenuView {
    /// the Screenshot Tools' Keep Windows as Layers toggle — it follows
    /// autoRedactRow, whose divider covers both
    @ViewBuilder func keepWindowsRow() -> some View {
        if let key = tool.captureSettings {
            row("Keep Windows as Layers", icon: "square.3.layers.3d",
                on: s.config.value.tools[keyPath: key].windowLayers, isToggle: true) {
                s.config.update { $0.tools[keyPath: key].windowLayers.toggle() }
            }
        }
    }
}

/// bytes a Canvas package occupies on disk, summed over every file inside
func packageSizeOnDisk(_ url: URL) -> Int {
    guard let e = FileManager.default.enumerator(at: url,
                                                 includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
    var total = 0
    for case let f as URL in e {
        total += (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
    }
    return total
}

/// the process's physical memory footprint in bytes
func processFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}
