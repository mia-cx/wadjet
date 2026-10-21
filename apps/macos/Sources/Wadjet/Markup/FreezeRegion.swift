import AppKit
import SwiftUI
import WadjetKit

extension Tool {
    /// the Capture Tool whose pick the Freeze Frame runs for this Tool: Freeze
    /// region borrows Capture Region's selection or Capture Window's window
    /// pick by its armed variant; every other Tool picks as itself
    @MainActor var pick: Tool {
        guard self == .freezeRegion else { return self }
        return AppState.shared.config.value.markup.armedVariant(of: .freezeRegion)?.id
            == FreezeVariant.window.rawValue ? .capWindow : .capRegion
    }
}

extension FrozenDisplay {
    /// the display as a frozen Canvas's source: frame, scale, and the HDR-preferred pixels
    @MainActor var canvasDisplay: CapturedCanvasDisplay? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return CapturedCanvasDisplay(
            display: .init(id: id, frame: screen.frame, scaleFactor: screen.backingScaleFactor),
            image: output(hdr: true))
    }
}

extension ToolMenuView {
    /// Freeze region's variants, then Region's shared confirm option when armed
    @ViewBuilder func freezeRegionRows() -> some View {
        tileRow([ToolID.freezeRegion.variants.map { v in
            MenuTile(icon: v.symbol, caption: v.title,
                     on: s.config.value.markup.armedVariant(of: .freezeRegion) == v) {
                s.config.update { $0.markup.tools[ToolID.freezeRegion.rawValue, default: .init()].variant = v.id }
                s.openMenu = nil; ctrl.syncMenu()
                ctrl.markOverlaysDirty() // the overlay's pick follows the armed variant
            }
        }])
        if s.config.value.markup.armedVariant(of: .freezeRegion)?.id == FreezeVariant.region.rawValue {
            section("Start") { confirmRow() }
        }
    }
}

extension AppDelegate {
    /// Freeze region's confirm: `rect` in display `display`'s view coords (the picked
    /// window's frame for the Window variant). The pixels under it become a frozen
    /// Annotation — no History entry, no Workflow, the overlay stays up. All Freeze
    /// Frame state is read before the confirm arms Select and before any await, so
    /// a live capture can't pick up a later moment or clobber a later pick. On a
    /// Freeze Frame the Window variant embeds the frozen pixels under the window's
    /// frame at its measured radius — the shape the overlay highlights; a live pick
    /// captures the window itself, its own alpha included.
    func freezeRegion(_ rect: CGRect, on display: Int, windowID: CGWindowID? = nil) {
        let frozen = Freeze.shared.displays
        guard display < frozen.count else { return }
        let screen = frozen[display].screen
        let frame = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let touched = frozen.filter { $0.screen.frame.intersects(frame) }
        let live = !overlayCtrl.showsFrozen // no Freeze Frame shown: freeze what's on screen now
        // the frozen pixels now — arming Select below may drop the Freeze Frame mid-Recording
        let displays = live ? [] : touched.compactMap(\.canvasDisplay)
        let radius = windowID.flatMap { overlayCtrl.cornerRadii[$0] }
        overlayCtrl.clearPicks()
        // Select dims nothing, so nothing flickers; a later Tool choice wins instead
        if AppState.shared.toolbarOpen, AppState.shared.tool != .select { trigger(.select) }
        Task { @MainActor in
            do {
                var canvas = CanvasDocument(freezing: live
                    ? try await overlayCtrl.captureCanvasDisplays(touched.map(\.screen),
                        excluding: [], cursor: false, wadjet: false)
                    : displays, rect: frame)
                if let windowID {
                    if live {
                        if let image = await captureWindow(id: windowID, screen: screen, cursor: false) {
                            canvas.setCapturedWindow(image, cornerRadius: radius)
                        } else {
                            AppLog.line("freeze region: window \(windowID) not capturable; keeping display pixels")
                        }
                    } else {
                        canvas.cornerRadius = radius ?? fallbackWindowRadius
                    }
                }
                MarkupController.shared.freeze(canvas)
            } catch {
                AppLog.line("freeze region: \(error.localizedDescription)")
            }
        }
    }
}

extension OverlayController {
    /// drops a finished pick from every overlay so nothing stale draws over the frozen Annotation
    func clearPicks() {
        for p in panels {
            for ov in p.contentView?.subviews.compactMap({ $0 as? OverlayNSView }) ?? [] {
                ov.sel = nil; ov.dragStart = nil; ov.hoverWin = nil
                ov.confirming = false; ov.selOp = nil
                ov.hideConfirmChrome()
                ov.needsDisplay = true
            }
        }
    }
}
