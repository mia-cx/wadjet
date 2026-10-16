// Wadjet — a ShareX-style screenshot and screen-recording utility for macOS.

import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon
import Vision
import UniformTypeIdentifiers
import ObjectiveC
import WadjetKit

// MARK: - Model

enum Tool: String, CaseIterable {
    case capRegion, capWindow, capScreen, recRegion, recWindow, recScreen, pickColour, copyText, measure
    var title: String {
        switch self {
        case .capRegion: "Capture Region"; case .capWindow: "Capture Window"; case .capScreen: "Capture Screen"
        case .recRegion: "Record Region"; case .recWindow: "Record Window"; case .recScreen: "Record Screen"
        case .pickColour: "Pick Colour"; case .copyText: "Copy Text"; case .measure: "Measure"
        }
    }
    var kind: Kind { switch self { case .capRegion, .capWindow, .capScreen: .shot; case .recRegion, .recWindow, .recScreen: .rec; default: .util } }
    var symbol: String {
        switch self {
        case .capRegion: "viewfinder"; case .capWindow: "macwindow"; case .capScreen: "display"
        case .recRegion: "viewfinder.circle"; case .recWindow: "macwindow.badge.plus"; case .recScreen: "record.circle"
        case .pickColour: "eyedropper"; case .copyText: "text.viewfinder"; case .measure: "ruler"
        }
    }
    var shortcut: String? { switch self { case .capRegion: "⌘⇧4"; case .capScreen: "⌘⇧3"; case .recRegion: "⌘⇧5"; default: nil } }
    enum Kind { case shot, rec, util }
    var hasMenu: Bool { self != .copyText }
    init?(named s: String) { self = Tool.allCases.first { $0.title.lowercased().contains(s.lowercased()) } ?? Tool(rawValue: s)! }
}

enum Phase { case desktop, frozen, countdown, recording }

extension Color {
    // Wadjet means "the green one": a malachite green, used instead of the system accent
    static let wadjetAccent = Color(red: 0.20, green: 0.84, blue: 0.58)
}

let lensZoom: CGFloat = 1.12 // how much the pressed lens magnifies what's under it
let dimAlpha: CGFloat = 0.4  // Freeze Frame dim outside the capture target

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var phase: Phase = .desktop
    @Published var tool: Tool? = nil
    @Published var workflowByTool: [Tool: String] = [:]
    @Published var colourFmt = "Hex" // Hex, rgb(), hsl(), oklch(), lab(), SwiftUI
    @Published var measureMode = "Spacing" // Bounds, Spacing, Horizontal, Vertical
    @Published var countdown = "Off" // Off 3 5 10
    @Published var sysAudio = false
    @Published var mic = false
    @Published var cursor = true
    @Published var clickCircles = false
    @Published var showIslandWhileRecording = true
    @Published var expandedDisplay: Int? = nil // which display's toolbar is expanded, if any
    @Published var openMenu: Tool? = nil // which Tool's dropdown is open, if any
    @Published var recordingElapsed: TimeInterval = 0
    @Published var recordingPaused = false
    @Published var lastClipboard = ""
    @Published var latencyText = "none"
    @Published var islandMode = false        // island even with a notch
    @Published var uploadMode = 0            // 0 succeed, 1 fail, 2 offline
    @Published var stepErrorNext = false
    @Published var showStateHUD = false
    func workflows(for t: Tool?) -> [String] {
        switch t?.kind {
        case .shot: return ["Screenshot", "Upload to w.mia.cx", "Pin"]
        case .rec: return ["MP4", "GIF", "GIF to w.mia.cx"]
        default: return []
        }
    }
    // the Workflow a capture runs with: the per-Tool choice, defaulting to the
    // first compatible one (Screenshot for Capture, MP4 for Record)
    func workflowFor(_ t: Tool?) -> String? { workflows(for: t).isEmpty ? nil : (workflowByTool[t ?? .capRegion] ?? workflows(for: t).first) }
}

// MARK: - Frozen frame store

struct FrozenDisplay {
    let screen: NSScreen
    let image: CGImage          // SDR image, pixel resolution
    var hdrImage: CGImage?      // extended-sRGB variant when the display is HDR
    var bitmap: UnsafePointer<UInt8>? // sRGB, premultiplied ARGB, pixel coords
    var bitmapWidth = 0, bitmapHeight = 0
    var pixels: PixelBuffer? { bitmap.map { PixelBuffer(base: $0, width: bitmapWidth, height: bitmapHeight) } }
    var windowFrames: [WinEntry] = [] // front-to-back, view coords
}

struct WinEntry {
    let id: CGWindowID
    let frame: CGRect
}
@MainActor
final class Freeze {
    static let shared = Freeze()
    var displays: [FrozenDisplay] = []
    var panels: [NSPanel] = []
    var capturedAt = Date()
    // the bitmap pixel under a view point — shared by the colour readout, the
    // loupe and the ruler so they always agree (y is top-down)
    func pointerPixel(_ pt: CGPoint, on d: Int) -> (x: Int, y: Int) {
        let f = displays[d]
        let sx = CGFloat(f.bitmapWidth) / f.screen.frame.width
        let sy = CGFloat(f.bitmapHeight) / f.screen.frame.height
        // pt is in view coords (bottom-left origin); image rows are top-left origin
        return (min(max(0, Int((pt.x * sx).rounded(.down))), f.bitmapWidth - 1),
                min(max(0, Int(((f.screen.frame.height - pt.y) * sy).rounded(.down))), f.bitmapHeight - 1))
    }
    func pixel(at pt: CGPoint, on d: Int) -> RGB8 {
        guard d < displays.count else { return (0, 0, 0) }
        let p = pointerPixel(pt, on: d)
        return displays[d].pixels?[p.x, p.y] ?? (0, 0, 0)
    }
    func crop(rect: CGRect, on d: Int, hdr: Bool = false) -> CGImage? {
        guard d < displays.count else { return nil }
        let f = displays[d]
        let src = (hdr ? f.hdrImage : nil) ?? f.image
        let sx = CGFloat(src.width) / f.screen.frame.width
        let sy = CGFloat(src.height) / f.screen.frame.height
        let r = CGRect(x: rect.origin.x * sx, y: (f.screen.frame.height - rect.origin.y - rect.height) * sy,
                       width: rect.width * sx, height: rect.height * sy).integral
        return src.cropping(to: r)
    }
}

#if CLEAR_GLASS_PATCH
// SwiftUI `Glass` has no knob for "refraction only" — `.clear` still carries a
// blur fill and a tinted face. SwiftUI drives glass via a private `CAFilter`
// (type "glassBackground") re-set through `CABackdropLayer.setFilters:` every
// animation frame, so hooking that setter zeroes blur/fill/face on every frame,
// including transitions, and pins the layer's `scale` to 1 (native-res
// sampling; the default 0.5 looks soft once the blur is gone).
// Private API, so only CLEAR_GLASS_PATCH builds (run.sh) compile it; store builds leave it out.
enum ClearGlassPatch {
    static let identityFill = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    static func install() {
        guard let cls = NSClassFromString("CABackdropLayer") else { return }
        let sel = NSSelectorFromString("setFilters:")
        guard let orig = class_getInstanceMethod(CALayer.self, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, NSArray?) -> Void
        let origFn = unsafeBitCast(method_getImplementation(orig), to: Fn.self)
        let block: @convention(block) (AnyObject, NSArray?) -> Void = { me, arr in
            for f0 in arr ?? [] {
                guard let f = f0 as? NSObject,
                      (f.value(forKey: "type") as? String) == "glassBackground",
                      // clear-glass signature; a regular glass only reaches
                      // bfd == 0 on the first identity->glass frame, where the
                      // values below already are identity's — a no-op
                      (f.value(forKey: "inputBlurFillDarkenOpacity") as? NSNumber)?.doubleValue == 0
                else { continue }
                for k in ["inputBlurRadius", "inputBlurOpacity0", "inputBlurOpacity1",
                          "inputBlurOpacity2", "inputBlurOpacity3",
                          "inputBlurFillNormalOpacity", "inputBlurFillLightenOpacity",
                          "inputBlurFillDarkenOpacity"] { f.setValue(0, forKey: k) }
                f.setValue(1, forKey: "inputFaceColorMatrixWhite")
                f.setValue(0, forKey: "inputFaceColorMatrixBlack")
                f.setValue(1, forKey: "inputFaceColorMatrixSaturation")
                f.setValue(1, forKey: "inputFaceColorMatrixMaxLuma")
                f.setValue(1, forKey: "inputFaceColorMatrixMaxLumaSDR")
                f.setValue(identityFill, forKey: "inputFaceColorMatrixFillColor")
                // rim chromatic aberration, tuned for the ~74 pt lens (Apple's own
                // 600 pt loading blob uses 4 / 300 / 50; offset 0 turns it off).
                // Scaled by the materialize progress, read off clear glass's -48.1 refraction.
                let refraction = (f.value(forKey: "inputInnerRefractionAmount") as? NSNumber)?.doubleValue ?? 0
                f.setValue(4 * min(1, abs(refraction) / 48.1), forKey: "inputAberrationAmount")
                f.setValue(37, forKey: "inputAberrationHeight")
                f.setValue(3, forKey: "inputAberrationOffset")
                me.setValue(1, forKey: "scale") // native-res backdrop sampling
            }
            origFn(me, sel, arr)
        }
        if !class_addMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(orig)),
           let m = class_getInstanceMethod(cls, sel) {
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
}
#endif

@MainActor
func clipboard(_ s: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    AppState.shared.lastClipboard = s
}

// MARK: - Log file

enum AppLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("wadjet/app.log")
    @MainActor
    static func line(_ s: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(stamp)] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayCtrl: OverlayController!
    var toastCtrl: ToastController!
    var hudPanel: NSPanel!
    var recTimer: Timer?
    var pauseStart: Date?
    var pauseAcc: TimeInterval = 0
    var recStart: Date?
    var recordingRect: CGRect = .zero
    var recordingDisplay = 0
    var recordingThumb: NSImage?
    var recordingWindowID: CGWindowID?
    var recordingPanel: NSPanel?

    func applicationDidFinishLaunching(_ n: Notification) {
        #if CLEAR_GLASS_PATCH
        ClearGlassPatch.install()
        #endif
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "wadjet")
        rebuildMenu()
        overlayCtrl = OverlayController(app: self)
        toastCtrl = ToastController()
        Hotkeys.register()
        AppLog.line("launch; preflight screen capture = \(CGPreflightScreenCaptureAccess()); statusItem frame = \(statusItem.button?.window?.frame.debugDescription ?? "?")")
        buildStateHUD()
        _ = try? FileManager.default.createDirectory(at: Self.capturesDir, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in self.recTick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppLog.line("statusItem frame = \(self.statusItem.button?.window?.frame.debugDescription ?? "?")")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("cx.mia.wadjet.cmd"), object: nil, queue: .main
        ) { [weak self] n in
            if let cmd = n.object as? String { Task { @MainActor in self?.handleCmd(cmd) } }
        }
    }

    // debug command channel, driven by tools/cmd.sh
    func handleCmd(_ cmd: String) {
        AppLog.line("cmd: \(cmd)")
        let parts = cmd.split(separator: " ").map(String.init)
        let s = AppState.shared
        switch parts.first {
        case "open" where parts.count > 1:
            if let t = Tool(named: parts.dropFirst().joined(separator: " ")) { trigger(t) }
        case "tool" where parts.count > 1:
            if let t = Tool(named: parts.dropFirst().joined(separator: " ")) { trigger(t) }
        case "workflow":
            s.workflowByTool[s.tool ?? .capRegion] = parts.dropFirst().joined(separator: " ")
        case "menu" where parts.count > 1:
            if let t = Tool(named: parts.dropFirst().joined(separator: " ")), t.hasMenu {
                s.expandedDisplay = overlayCtrl.mouseDisplay(); s.openMenu = t; overlayCtrl.syncMenu()
            }
        case "closemenu":
            s.openMenu = nil; overlayCtrl.syncMenu()
        case "option" where parts.count > 2:
            let key = parts[1], val = parts.dropFirst(2).joined(separator: " ")
            switch key {
            case "countdown": s.countdown = val
            case "audio": s.sysAudio = val == "on"
            case "mic": s.mic = val == "on"
            case "cursor": s.cursor = val == "on"
            case "clicks": s.clickCircles = val == "on"
            case "island": s.showIslandWhileRecording = val == "on"
            case "colourFormat": s.colourFmt = val
            case "measureMode": s.measureMode = val
            default: AppLog.line("cmd option: unknown key \(key)")
            }
        case "expand": s.expandedDisplay = overlayCtrl.mouseDisplay()
        case "collapse": s.expandedDisplay = nil
        case "upload" where parts.count > 1:
            s.uploadMode = ["succeed": 0, "fail": 1, "offline": 2][parts[1]] ?? s.uploadMode
            rebuildMenu()
        case "steperror" where parts.count > 1:
            s.stepErrorNext = parts[1] == "on"
        case "stop": if s.phase == .recording { stopRecording() }
        case "pause": if s.phase == .recording { togglePause() }
        case "esc": handleEsc()
        default: AppLog.line("cmd: unhandled \(cmd)")
        }
    }

    static var capturesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wadjet/Captures")
    }

    // MARK: status menu
    func rebuildMenu() {
        let m = NSMenu()
        let tools: [Tool] = [.capRegion, .capWindow, .capScreen, .recRegion, .recWindow, .recScreen, .pickColour, .copyText, .measure]
        for (i, t) in tools.enumerated() {
            let it = NSMenuItem(title: t.title + (t.shortcut.map { "\t" + $0 } ?? ""),
                                action: #selector(toolItem(_:)), keyEquivalent: "")
            it.representedObject = t.rawValue; it.target = self
            m.addItem(it)
            if i == 2 || i == 5 { m.addItem(.separator()) }
        }
        m.addItem(.separator())
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let rsub = NSMenu()
        let noCap = NSMenuItem(title: "No Captures", action: nil, keyEquivalent: ""); noCap.isEnabled = false
        rsub.addItem(noCap)
        recent.submenu = rsub; m.addItem(recent)
        for t in ["Destinations", "History…", "Settings…"] {
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: ""); it.isEnabled = false
            m.addItem(it)
        }
        let proto = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        psub.addItem(mi("Island Mode Even With Notch", #selector(toggleIsland), on: AppState.shared.islandMode))
        psub.addItem(.separator())
        psub.addItem(mi("Next Upload: Succeed", #selector(upl0), on: AppState.shared.uploadMode == 0))
        psub.addItem(mi("Next Upload: Fail", #selector(upl1), on: AppState.shared.uploadMode == 1))
        psub.addItem(mi("Next Upload: Offline", #selector(upl2), on: AppState.shared.uploadMode == 2))
        psub.addItem(.separator())
        psub.addItem(mi("Step Error on Next Capture", #selector(toggleStepErr), on: AppState.shared.stepErrorNext))
        psub.addItem(mi("Show State HUD", #selector(toggleHUD), on: AppState.shared.showStateHUD))
        psub.addItem(.separator())
        psub.addItem(mi("Open Screen Recording Settings", #selector(openScreenRecordingSettings), on: false))
        proto.submenu = psub; m.addItem(proto)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit wadjet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = m
    }
    func mi(_ t: String, _ a: Selector, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: "")
        i.target = self; i.state = on ? .on : .off; return i
    }
    @objc func toolItem(_ s: NSMenuItem) { if let r = s.representedObject as? String, let t = Tool(rawValue: r) { trigger(t) } }
    @objc func toggleIsland(_ s: NSMenuItem) { AppState.shared.islandMode.toggle(); s.state = AppState.shared.islandMode ? .on : .off }
    @objc func upl0(_ s: NSMenuItem) { setUpl(0) }; @objc func upl1(_ s: NSMenuItem) { setUpl(1) }; @objc func upl2(_ s: NSMenuItem) { setUpl(2) }
    func setUpl(_ v: Int) { AppState.shared.uploadMode = v; rebuildMenu() }
    @objc func toggleStepErr(_ s: NSMenuItem) { AppState.shared.stepErrorNext.toggle(); s.state = AppState.shared.stepErrorNext ? .on : .off }
    @objc func toggleHUD(_ s: NSMenuItem) { AppState.shared.showStateHUD.toggle(); s.state = AppState.shared.showStateHUD ? .on : .off
        hudPanel.setIsVisible(AppState.shared.showStateHUD) }
    @objc func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: trigger
    func trigger(_ tool: Tool) {
        let s = AppState.shared
        if s.phase == .recording && tool.kind == .rec { stopRecording(); return }
        // switching Tools while frozen keeps the same Freeze Frame
        if s.phase == .frozen { if s.tool != tool { s.tool = tool; s.openMenu = nil; overlayCtrl.syncMenu(); AppLog.line("tool switched to \(tool.title)") }; return }
        if s.phase != .desktop { AppLog.line("trigger ignored: busy (\(s.phase))"); return }
        if !CGPreflightScreenCaptureAccess() { permissionNeeded(); AppLog.line("screen capture preflight denied for \(tool.title)"); return }
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { await overlayCtrl.freezeAndShow(tool: tool, t0: t0) }
    }
    func permissionNeeded() {
        _ = CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "Screen Recording Permission Needed"
        a.informativeText = "Wadjet needs Screen Recording access to take a Freeze Frame. Grant it in System Settings, then relaunch."
        a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: selection -> capture or recording
    // a live shot of one window, "through" the Freeze Frame; nil if SCK can't
    // find it anymore — callers fall back to cropping the frozen image
    func captureWindow(id: CGWindowID, display: Int) async -> CGImage? {
        guard let scw = overlayCtrl.scWindows[id] else { return nil }
        let screen = Freeze.shared.displays[display].screen
        let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        let sc = screen.backingScaleFactor
        let cfg = SCScreenshotConfiguration()
        cfg.width = Int((scw.frame.width * sc).rounded())
        cfg.height = Int((scw.frame.height * sc).rounded())
        cfg.showsCursor = false
        cfg.dynamicRange = hdr ? .bothSDRAndHDR : .sdr
        do {
            let out = try await SCScreenshotManager.captureScreenshot(
                contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg)
            return out.hdrImage ?? out.sdrImage
        } catch {
            AppLog.line("window capture \(id) failed: \(error.localizedDescription)")
            return nil
        }
    }
    func didSelectWindow(id: CGWindowID, frame: CGRect, on display: Int) {
        let s = AppState.shared
        guard let tool = s.tool else { return }
        if tool.kind == .shot {
            overlayCtrl.closeAll()
            Task { @MainActor in
                var thumb = await captureWindow(id: id, display: display)
                if thumb == nil {
                    AppLog.line("window \(id) not capturable; falling back to frozen crop")
                    thumb = Freeze.shared.crop(rect: frame, on: display, hdr: true)
                }
                runCapture(thumb: thumb, label: "\(tool.title) \(Int(frame.width))×\(Int(frame.height))")
            }
        } else {
            recordingWindowID = id // kept for the real SCStream later
            Task { @MainActor in
                startRecording(rect: frame, display: display, thumb: await captureWindow(id: id, display: display))
            }
        }
    }
    func didSelect(_ rect: CGRect, on display: Int) {
        let s = AppState.shared
        guard let tool = s.tool else { return }
        if tool.kind == .shot {
            // screenshots keep HDR pixels when the display provides them
            let thumb = Freeze.shared.crop(rect: rect, on: display, hdr: true)
            overlayCtrl.closeAll()
            runCapture(thumb: thumb, label: "\(tool.title) \(Int(rect.width))×\(Int(rect.height))")
        } else {
            startRecording(rect: rect, display: display)
        }
    }
    func runCapture(thumb: CGImage?, label: String, duration: TimeInterval? = nil) {
        let wf = AppState.shared.workflowFor(AppState.shared.tool) ?? "Screenshot"
        var path: URL? = nil
        var heic: Data? = nil
        if let img = thumb {
            if duration == nil, let d = heicData(img) {
                // HDR screenshot -> HEIC with an ISO gain map
                heic = d
                path = Self.capturesDir.appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970)).heic")
                try? d.write(to: path!)
            } else {
                path = Self.capturesDir.appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970)).png")
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: path!)
            }
            AppLog.line("saved \(path!.lastPathComponent) workflow=\(wf)")
        }
        toastCtrl.start(cap: Capture(thumb: thumb, label: label, url: path, duration: duration), workflow: wf)
        if wf == "Pin", let img = thumb { openPin(image: img) }
        if wf == "Screenshot", let img = thumb {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let heic {
                let heicT = NSPasteboard.PasteboardType(UTType.heic.identifier)
                pb.declareTypes([heicT, .png], owner: nil)
                pb.setData(heic, forType: heicT)
                pb.setData(NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]), forType: .png)
                AppState.shared.lastClipboard = "<heic+png \(img.width)×\(img.height)>"
            } else {
                pb.writeObjects([NSImage(cgImage: img, size: .zero) as NSPasteboardWriting])
                AppState.shared.lastClipboard = "<image \(img.width)×\(img.height)>"
            }
        }
    }
    // HEIC with an ISO gain map from an extended-sRGB CGImage; nil for SDR input
    func heicData(_ img: CGImage) -> Data? {
        guard img.colorSpace?.name == CGColorSpace.extendedSRGB
           || img.colorSpace?.name == CGColorSpace.extendedLinearSRGB else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    // MARK: recording (simulated)
    func startRecording(rect: CGRect, display: Int, thumb: CGImage? = nil) {
        let s = AppState.shared
        let thumb = thumb ?? Freeze.shared.crop(rect: rect, on: display)
        overlayCtrl.closeAllPanelsOnly() // live screen returns
        recordingRect = rect; recordingDisplay = display; recordingThumb = thumb.map { NSImage(cgImage: $0, size: .zero) }
        pauseAcc = 0; s.recordingElapsed = 0; s.recordingPaused = false
        let n = s.countdown == "Off" ? 0 : Int(s.countdown) ?? 0
        let begin = {
            s.phase = .recording; self.recStart = Date()
            AppLog.line("phase=recording")
            self.updateEscHotkey()
            self.showRecBorder(rect: rect, display: display)
            self.updateRecChrome()
        }
        if n > 0 {
            s.phase = .countdown
            AppLog.line("phase=countdown (\(n))")
            updateEscHotkey()
            CountdownHUD.show(n)
            Task { @MainActor in
                for i in stride(from: n - 1, through: 0, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    guard s.phase == .countdown else { CountdownHUD.hide(); return }
                    CountdownHUD.show(i)
                }
                CountdownHUD.hide()
                begin()
            }
        } else { begin() }
    }
    func showRecBorder(rect: CGRect, display: Int) {
        let f = Freeze.shared.displays[display]
        // rect is in view coords (bottom-left origin), same as AppKit global coords
        let global = rect.offsetBy(dx: f.screen.frame.origin.x, dy: f.screen.frame.origin.y)
        let p = NSPanel(contentRect: global, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(origin: .zero, size: global.size))
        v.wantsLayer = true; v.layer?.borderColor = NSColor.systemRed.cgColor; v.layer?.borderWidth = 2; v.layer?.cornerRadius = 3
        p.contentView = v; p.orderFront(nil); recordingPanel = p
    }
    // Recording is always stoppable from the status item AND the island; the
    // "Show Island While Recording" option only toggles the island part.
    func updateRecChrome() {
        let s = AppState.shared
        statusItem.button?.title = "● " + fmtT(s.recordingElapsed)
        statusItem.button?.image = nil
        let m = NSMenu()
        m.addItem(mi(s.recordingPaused ? "Resume" : "Pause", #selector(recPause), on: false))
        m.addItem(mi("Stop Recording", #selector(recStop), on: false))
        statusItem.menu = m
        overlayCtrl.refreshToolbars()
    }
    @objc func recPause() { togglePause() }
    @objc func recStop() { stopRecording() }
    func togglePause() {
        let s = AppState.shared
        if s.recordingPaused { pauseAcc += Date().timeIntervalSince(pauseStart!); s.recordingPaused = false }
        else { s.recordingPaused = true; pauseStart = Date() }
        updateRecChrome()
    }
    func recTick() {
        let s = AppState.shared
        guard s.phase == .recording, !s.recordingPaused, let st = recStart else { return }
        s.recordingElapsed = Date().timeIntervalSince(st) - pauseAcc
        statusItem.button?.title = "● " + fmtT(s.recordingElapsed)
    }
    // Esc during countdown cancels before the Recording starts.
    func cancelCountdown() {
        let s = AppState.shared
        guard s.phase == .countdown else { return }
        CountdownHUD.hide()
        s.phase = .desktop; recStart = nil
        overlayCtrl.closeAllPanelsOnly()
        AppLog.line("esc: cancelled countdown")
        rebuildMenu(); updateEscHotkey()
    }
    func stopRecording() {
        let s = AppState.shared
        s.recordingElapsed = recStart.map { Date().timeIntervalSince($0) - pauseAcc } ?? s.recordingElapsed
        let dur = s.recordingElapsed
        let label = "\(s.tool?.title ?? "Recording") \(fmtT(dur))"
        recordingPanel?.close(); recordingPanel = nil
        s.phase = .desktop; recStart = nil
        updateEscHotkey()
        AppLog.line("phase=desktop (recording stopped, \(String(format: "%.1f", dur))s)")
        statusItem.button?.title = ""; statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "wadjet")
        rebuildMenu()
        overlayCtrl.closeAllPanelsOnly()
        let thumbCG = recordingThumb.map { cgimg(from: $0) }
        runCapture(thumb: thumbCG, label: label, duration: dur)
    }
    func cgimg(from img: NSImage) -> CGImage {
        var r = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil) ?? NSImage(size: img.size).cgImage(forProposedRect: &r, context: nil, hints: nil)!
    }
    func fmtT(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    // MARK: Esc hotkey (registered only while something cancellable is active;
    // a Recording never counts, so Esc reaches the app being recorded)
    var escRef: EventHotKeyRef?
    var measureRefs: [EventHotKeyRef?] = []
    var spaceRef: EventHotKeyRef?
    var spaceRegistered = false
    var escRegistered = false
    var escHandlerInstalled = false
    // Space toggles Region <-> Window within the current kind, like macOS
    func toggleRegionWindow() {
        let s = AppState.shared
        guard s.phase == .frozen, let t = s.tool else { return }
        // not while a drag is in progress
        for p in overlayCtrl.panels {
            if p.contentView?.subviews.compactMap({ $0 as? OverlayNSView }).contains(where: { $0.dragStart != nil }) == true { return }
        }
        let next: Tool? = switch t {
        case .capRegion, .capScreen: .capWindow
        case .capWindow: .capRegion
        case .recRegion, .recScreen: .recWindow
        case .recWindow: .recRegion
        default: nil
        }
        guard let n = next else { return }
        trigger(n)
        for p in overlayCtrl.panels { p.contentView?.subviews.compactMap { $0 as? OverlayNSView }.forEach { $0.setFlash(n.title) } }
    }
    func setMeasureMode(_ i: Int) {
        let modes = ["Bounds", "Spacing", "Horizontal", "Vertical"]
        guard AppState.shared.tool == .measure, modes.indices.contains(i) else { return }
        AppState.shared.measureMode = modes[i]
        AppLog.line("measure mode -> \(modes[i])")
        for p in overlayCtrl.panels { p.contentView?.subviews.compactMap { $0 as? OverlayNSView }.forEach { $0.rescanRuler() } }
    }
    func updateEscHotkey() {
        let s = AppState.shared
        let active = s.phase == .frozen || s.phase == .countdown
            || !toastCtrl.items.isEmpty || !pins.isEmpty
        if active && !escRegistered {
            if !escHandlerInstalled {
                escHandlerInstalled = true
                var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ -> OSStatus in
                    var id = EventHotKeyID()
                    GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                    if id.id == 10 { DispatchQueue.main.async { AppDelegate.shared?.handleEsc() }; return noErr }
                    if (20...23).contains(id.id) { // Ctrl+1..4 = Measure modes
                        DispatchQueue.main.async { AppDelegate.shared?.setMeasureMode(Int(id.id) - 20) }
                        return noErr
                    }
                    if id.id == 30 { // Space = Region <-> Window
                        DispatchQueue.main.async { AppDelegate.shared?.toggleRegionWindow() }
                        return noErr
                    }
                    return OSStatus(eventNotHandledErr)
                }, 1, &type, nil, nil)
            }
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x77646A74), id: 10),
                                          GetApplicationEventTarget(), 0, &ref)
            escRef = ref; escRegistered = (err == noErr && ref != nil)
            AppLog.line("esc hotkey registered (err=\(err))")
            // Ctrl+1..4 while anything is up (cheap to keep registered; only the
            // Measure tool acts on them)
            for (i, vk) in [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4].enumerated() {
                var r: EventHotKeyRef?
                RegisterEventHotKey(UInt32(vk), UInt32(controlKey), EventHotKeyID(signature: OSType(0x77646A74), id: UInt32(20 + i)),
                                    GetApplicationEventTarget(), 0, &r)
                measureRefs.append(r)
            }
        } else if !active && escRegistered {
            if let r = escRef { UnregisterEventHotKey(r) }
            for r in measureRefs { if let r { UnregisterEventHotKey(r) } }
            measureRefs = []
            escRef = nil; escRegistered = false
            AppLog.line("esc hotkey unregistered")
        }
        // Space is claimed only while the overlay is actually frozen — it must
        // drop as soon as we leave .frozen (e.g. a countdown starts)
        if s.phase == .frozen && !spaceRegistered {
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(kVK_Space), 0, EventHotKeyID(signature: OSType(0x77646A74), id: 30),
                                          GetApplicationEventTarget(), 0, &ref)
            spaceRef = ref; spaceRegistered = (err == noErr && ref != nil)
        } else if s.phase != .frozen && spaceRegistered {
            if let r = spaceRef { UnregisterEventHotKey(r) }
            spaceRef = nil; spaceRegistered = false
        }
    }
    // priority: overlay > countdown > in-flight toast > idle toast > pin.
    // (Recording is never here; Esc is not registered on its account.)
    func handleEsc() {
        let s = AppState.shared
        if s.openMenu != nil { s.openMenu = nil; overlayCtrl.syncMenu(); AppLog.line("esc: closed tool menu"); return }
        if s.phase == .frozen { AppLog.line("esc: cancelled overlay"); overlayCtrl.closeAll(); return }
        if s.phase == .countdown { cancelCountdown(); return }
        if let t = toastCtrl.items.first(where: { $0.showBar || $0.showRing }) {
            t.showBar = false; t.showRing = false; t.showCancel = false
            t.title = "Cancelled"; toastCtrl.startTimer(t)
            AppLog.line("esc: cancelled in-flight \(t.sub.isEmpty ? t.title : t.sub)")
            updateEscHotkey(); return
        }
        if let t = toastCtrl.items.first {
            toastCtrl.dismiss(t); AppLog.line("esc: dismissed idle toast")
            updateEscHotkey(); return
        }
        if let p = pins.last {
            p.close(); pins.removeLast(); AppLog.line("esc: closed pin")
            updateEscHotkey(); return
        }
        updateEscHotkey()
    }

    // MARK: pins
    var pins: [NSPanel] = []
    func openPin(image: CGImage) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, 400 / max(w, 1))
        let size = NSSize(width: w * scale, height: h * scale)
        let f = NSScreen.main!.frame
        let p = NSPanel(contentRect: NSRect(x: f.midX - size.width / 2 + CGFloat(pins.count) * 30,
                                            y: f.midY - size.height / 2 + CGFloat(pins.count) * 30,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces]
        p.hasShadow = true; p.isOpaque = false; p.backgroundColor = .clear
        p.isMovableByWindowBackground = true
        let v = PinView(frame: NSRect(origin: .zero, size: size), image: image)
        p.contentView = v; p.orderFront(nil)
        pins.append(p)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pins.removeAll { $0 === p }
                self?.updateEscHotkey()
            }
        }
        updateEscHotkey()
    }

    // MARK: state HUD
    func buildStateHUD() {
        let h = NSHostingView(rootView: StateHUDView())
        h.frame = NSRect(x: 0, y: 0, width: 320, height: 210)
        let p = NSPanel(contentRect: NSRect(x: 10, y: 10, width: 320, height: 210),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces]; p.ignoresMouseEvents = true
        h.frame.origin = .zero; p.contentView = h; if AppState.shared.showStateHUD { p.orderFront(nil) }
        hudPanel = p
    }
}

func fmtT(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

// MARK: - Pin view

final class PinView: NSView {
    let image: CGImage
    var zoom: CGFloat = 1, offset = CGPoint.zero
    init(frame f: NSRect, image: CGImage) { self.image = image; super.init(frame: f); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        NSColor.windowBackgroundColor.setFill(); r.fill()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState(); ctx.translateBy(x: offset.x, y: offset.y); ctx.scaleBy(x: zoom, y: zoom)
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size)); ctx.restoreGState()
    }
    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { return } // ctrl+wheel handled by magnify on trackpads; also zoom here
        offset.x += e.deltaX * (e.hasPreciseScrollingDeltas ? 1 : 10)
        offset.y -= e.deltaY * (e.hasPreciseScrollingDeltas ? 1 : 10)
        needsDisplay = true
    }
    override func magnify(with e: NSEvent) {
        let z0 = zoom; zoom = min(8, max(0.2, zoom * (1 + e.magnification)))
        let m = convert(e.locationInWindow, from: nil)
        offset.x = m.x - (m.x - offset.x) * zoom / z0
        offset.y = m.y - (m.y - offset.y) * zoom / z0
        needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.close(); return }
        super.mouseDown(with: e)
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { window?.close() } }
}

// MARK: - Overlay controller

@MainActor
final class OverlayController {
    weak var app: AppDelegate?
    var panels: [NSPanel] = []
    var toolbarPanels: [Int: NSPanel] = [:] // one per Freeze display index
    var scWindows: [CGWindowID: SCWindow] = [:] // windowID -> SCWindow, from freeze time
    var menuPanel: NSPanel?
    var menuMonitor: Any?
    var keyMonitor: Any?
    init(app: AppDelegate) { self.app = app }

    // the Freeze display under the mouse, fallback 0
    func mouseDisplay() -> Int {
        let m = NSEvent.mouseLocation
        return Freeze.shared.displays.firstIndex { NSMouseInRect(m, $0.screen.frame, false) } ?? 0
    }
    // the *visible* toolbar shape in screen coords — the click-through panel is
    // much bigger, so hit-testing must use this, not the panel frame
    func toolbarShapeScreenRect(on di: Int) -> CGRect? {
        guard let p = toolbarPanels[di], let cv = p.contentView, let r = ToolbarHit.rects[di] else { return nil }
        return p.convertToScreen(cv.convert(r, to: nil))
    }
    var pointerOverUI: Bool {
        let m = NSEvent.mouseLocation
        for (di, _) in toolbarPanels {
            if toolbarShapeScreenRect(on: di)?.contains(m) == true { return true }
        }
        if let mp = menuPanel, mp.frame.contains(m) { return true }
        if let tp = TipPanel.panel, tp.frame.contains(m) { return true }
        return false
    }
    // a Tool button's frame in screen coords (from measured panel-space frames)
    func buttonScreenRect(_ t: Tool, on di: Int) -> CGRect? {
        guard let fr = ToolbarBtnFrames.rects[di]?[t], let p = toolbarPanels[di], let cv = p.contentView else { return nil }
        return p.convertToScreen(cv.convert(fr, to: nil))
    }

    func syncMenu() {
        if let t = AppState.shared.openMenu { TipPanel.hide(); showMenu(t) } else { hideMenu() }
    }
    func showMenu(_ t: Tool) {
        // anchor to the panel of the expanded display (or the pointer's)
        let di = AppState.shared.expandedDisplay ?? mouseDisplay()
        guard let tp = toolbarPanels[di], t.hasMenu else { return }
        hideMenu()
        let h = NSHostingView(rootView: ToolMenuView(tool: t, ctrl: self))
        h.frame.size = h.fittingSize
        var f = NSRect(origin: .zero, size: h.fittingSize)
        let scr = tp.screen?.frame ?? NSScreen.main!.frame
        let anchor = buttonScreenRect(t, on: di) ?? toolbarShapeScreenRect(on: di) ?? CGRect(x: scr.midX, y: scr.maxY - 40, width: 0, height: 0)
        f.origin = CGPoint(x: min(max(scr.minX + 8, anchor.midX - f.width / 2), scr.maxX - f.width - 8),
                           y: max(scr.minY + 8, anchor.minY - f.height - 6))
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver + 2; p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = h; p.orderFront(nil)
        menuPanel = p
        AppLog.line("menu \(t.title) @ \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))")
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, let mp = self.menuPanel else { return e }
            if !mp.frame.contains(NSEvent.mouseLocation) {
                AppState.shared.openMenu = nil; self.syncMenu()
                AppLog.line("menu closed (outside click)")
            }
            return e
        }
    }
    func hideMenu() {
        menuPanel?.close(); menuPanel = nil
        if let m = menuMonitor { NSEvent.removeMonitor(m); menuMonitor = nil }
    }

    func freezeAndShow(tool: Tool, t0: CFAbsoluteTime) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            Freeze.shared.displays = []
            for screen in NSScreen.screens {
                guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      let disp = content.displays.first(where: { $0.displayID == num }) else { continue }
                let cfg = SCScreenshotConfiguration()
                // native pixels, not SCDisplay's point size — a 2x display freezes sharp
                cfg.width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
                cfg.height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
                cfg.showsCursor = true; cfg.displayIntent = .local
                let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
                cfg.dynamicRange = hdr ? .bothSDRAndHDR : .sdr
                let out = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: SCContentFilter(display: disp, excludingWindows: []), configuration: cfg)
                guard let img = out.sdrImage ?? out.hdrImage else { continue }
                var fd = FrozenDisplay(screen: screen, image: img)
                fd.hdrImage = out.hdrImage
                // CGWindowList is front-to-back, so first-hit is the frontmost
                // window — SCShareableContent's windows list isn't ordered
                let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let sy = screen.frame
                let primaryH = NSScreen.screens[0].frame.height
                fd.windowFrames = infos.compactMap { w in
                    guard (w[kCGWindowLayer as String] as? Int) == 0,
                          (w[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                          (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                          let wn = w[kCGWindowNumber as String] as? Int else { return nil }
                    let f = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                    guard f.width > 40, f.height > 40 else { return nil }
                    // top-left global coords -> this display's bottom-left view coords
                    return WinEntry(id: CGWindowID(wn),
                                    frame: CGRect(x: f.minX - sy.minX,
                                                  y: primaryH - sy.minY - f.minY - f.height,
                                                  width: f.width, height: f.height))
                }
                scWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
                // bitmap for pixel reads — real sRGB so colour math is honest
                let w = img.width, h = img.height
                var data = [UInt8](repeating: 0, count: w * h * 4)
                let ok = data.withUnsafeMutableBytes { ptr -> Bool in
                    guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
                }
                if ok { fd.bitmap = UnsafePointer(data.withUnsafeBufferPointer { $0.baseAddress }); fd.bitmapWidth = w; fd.bitmapHeight = h
                    bitmapStore.append(data) }
                Freeze.shared.displays.append(fd)
            }
            let latency = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            await MainActor.run {
                AppState.shared.latencyText = String(format: "%.0f ms (%d displays)", latency, Freeze.shared.displays.count)
                let perDisplay = Freeze.shared.displays.map { "\($0.image.width)x\($0.image.height)\($0.hdrImage != nil ? " HDR" : "")" }.joined(separator: ", ")
                AppLog.line("freeze latency \(Int(latency)) ms across \(Freeze.shared.displays.count) displays: \(perDisplay)")
                self.showPanels(tool: tool)
                AppLog.line("phase=frozen tool=\(tool.title)")
            }
        } catch {
            await MainActor.run {
                AppState.shared.latencyText = "capture failed: \(error.localizedDescription)"
                AppLog.line("freeze failed: \(error.localizedDescription)")
            }
        }
    }
    var bitmapStore: [[UInt8]] = []

    func showPanels(tool: Tool) {
        let s = AppState.shared
        s.phase = .frozen; s.tool = tool
        closeAllPanelsOnly()
        for (i, fd) in Freeze.shared.displays.enumerated() {
            let p = NSPanel(contentRect: fd.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver; p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.ignoresMouseEvents = false; p.acceptsMouseMovedEvents = true
            p.hidesOnDeactivate = false
            // the frozen frame lives in its own layer under the overlay drawing so
            // HDR captures can render with extended dynamic range
            let img = fd.hdrImage ?? fd.image
            let imageView = NSView(frame: NSRect(origin: .zero, size: fd.screen.frame.size))
            imageView.wantsLayer = true
            imageView.layer?.contents = img
            imageView.layer?.contentsGravity = .resize
            if fd.hdrImage != nil { imageView.layer?.preferredDynamicRange = .high }
            let ov = OverlayNSView(frame: NSRect(origin: .zero, size: fd.screen.frame.size), displayIndex: i, controller: self)
            let container = NSView(frame: NSRect(origin: .zero, size: fd.screen.frame.size))
            container.addSubview(imageView); container.addSubview(ov)
            p.contentView = container
            p.orderFront(nil)
            p.makeFirstResponder(ov)
            panels.append(p)
        }
        // borderless nonactivating panels can't be key windows, so keyDown on
        // the view never fires — route keys through a local monitor instead
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            for p in self.panels {
                if let ov = p.contentView?.subviews.compactMap({ $0 as? OverlayNSView }).first,
                   ov.handleKey(e) { return nil }
            }
            return e
        }
        showToolbars()
        app?.updateEscHotkey()
    }
    // one toolbar panel per Freeze display — the island/notch form is chosen
    // inside ToolbarView from its own screen
    func showToolbars() {
        for (idx, fd) in Freeze.shared.displays.enumerated() {
            let tv = ToolbarView(displayIndex: idx, ctrl: self)
            let hosting = PassthroughHostingView(rootView: tv)
            hosting.displayIndex = idx
            let size = NSSize(width: tv.panelW, height: tv.panelH)
            hosting.frame = NSRect(origin: .zero, size: size)
            let p = NSPanel(contentRect: NSRect(x: fd.screen.frame.midX - size.width / 2,
                                                y: fd.screen.frame.maxY - size.height,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver + 1; p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.acceptsMouseMovedEvents = true; p.hidesOnDeactivate = false
            p.contentView = hosting; p.orderFront(nil)
            toolbarPanels[idx] = p
            AppLog.line("toolbar panel d\(idx) \(p.frame.debugDescription) shape=\(tv.shapeRectInView.debugDescription)")
        }
    }
    // the expanded row's true size lands after the panel is created; resize to
    // fit it, staying centred on the display
    func resizeToolbar(_ w: CGFloat, _ h: CGFloat, on di: Int) {
        guard let p = toolbarPanels[di], abs(p.frame.width - w) > 1 else { return }
        var f = p.frame; f.size = NSSize(width: w, height: h)
        if let scr = p.screen { f.origin.x = scr.frame.midX - w / 2; f.origin.y = scr.frame.maxY - h }
        p.contentView?.frame.size = f.size
        p.setFrame(f, display: true)
    }
    func refreshToolbars() {
        toolbarPanels.values.forEach { $0.close() }
        toolbarPanels = [:]
        let p = AppState.shared.phase
        if p == .frozen || (p == .recording && AppState.shared.showIslandWhileRecording) { showToolbars() }
    }
    func closeAllPanelsOnly() {
        panels.forEach { $0.close() }
        panels = []
        hideMenu()
        if AppState.shared.openMenu != nil { AppState.shared.openMenu = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        TipPanel.hide()
        toolbarPanels.values.forEach { $0.close() }; toolbarPanels = [:]
        ToolbarHit.rects = [:]; ToolbarBtnFrames.rects = [:]; ToolbarBtnFrames.blobRect = [:]
    }
    func closeAll() {
        closeAllPanelsOnly()
        if AppState.shared.phase != .desktop { AppLog.line("phase=desktop (overlay closed)") }
        AppState.shared.phase = .desktop
        AppState.shared.expandedDisplay = nil
        Freeze.shared.displays = []; bitmapStore = []
        AppDelegate.shared?.updateEscHotkey()
    }
}

// MARK: - Overlay NSView (per display)

@MainActor
final class OverlayNSView: NSView {
    let di: Int
    weak var ctrl: OverlayController?
    var dragStart: CGPoint?, sel: CGRect?
    var hoverWin: WinEntry?, hoverPt = CGPoint.zero
    nonisolated(unsafe) static var pointerDisplay: Int? // display that last saw the pointer
    // Screen Ruler state: found edges in view points around the pointer
    var rulerX: (lo: CGFloat, hi: CGFloat)?
    var rulerY: (lo: CGFloat, hi: CGFloat)?
    var tolerance = 30
    var flash: (text: String, until: Date)? // transient badge near the pointer
    var scrollAcc: CGFloat = 0
    var boundsBoxes: [CGRect] = [] // Bounds boxes kept on screen via Shift
    init(frame f: NSRect, displayIndex: Int, controller: OverlayController) {
        di = displayIndex; ctrl = controller
        super.init(frame: f)
        wantsLayer = true
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
    }
    required init?(coder: NSCoder) { fatalError() }
    var fd: FrozenDisplay { Freeze.shared.displays[di] }
    var tool: Tool { AppState.shared.tool ?? .capRegion }
    var measureMode: String { AppState.shared.measureMode }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override var isOpaque: Bool { false }
    override func draw(_ r: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.clear(bounds) // the frozen frame is drawn by the layer beneath
        let t = tool
        let overToolbar = ctrl?.pointerOverUI ?? false
        // dim the frame except the capture target, which stays at full brightness;
        // Screen Tools, Measure and Pick Colour get no dim
        var target: NSBezierPath?, alpha: CGFloat?
        switch t {
        case .capRegion, .recRegion, .copyText:
            target = sel.map { NSBezierPath(rect: $0) }
            alpha = t != .copyText ? dimAlpha : sel == nil ? 0.15 : 0.35
        case .capWindow, .recWindow:
            if !overToolbar, let w = hoverWin { target = NSBezierPath(roundedRect: w.frame, xRadius: 12, yRadius: 12) }
            alpha = dimAlpha
        default: break
        }
        if let alpha {
            let p = NSBezierPath(rect: bounds)
            if let target { p.append(target); p.windingRule = .evenOdd }
            NSColor.black.withAlphaComponent(alpha).setFill(); p.fill()
        }
        if let s = sel, t == .capRegion || t == .recRegion || t == .copyText {
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let p = NSBezierPath(rect: s); p.lineWidth = 0.5; p.stroke()
        }
        if t == .measure { drawMeasure() }
        if !overToolbar && t != .measure { drawLoupe(ctx) }
        if let s = sel, t == .capRegion || t == .recRegion {
            let str = "\(Int(s.width)) × \(Int(s.height))"
            let at = CGPoint(x: min(bounds.width - 90, s.maxX + 8), y: min(bounds.height - 26, s.maxY + 8))
            drawBadge(str, at: at)
        }
        // the ruler label carries the flash itself, so it never draws twice
        if let f = flash, Date() < f.until, !(t == .measure && measureMode != "Bounds") {
            drawBadge(f.text, at: CGPoint(x: min(bounds.width - 160, hoverPt.x + 18), y: min(bounds.height - 30, hoverPt.y + 18)))
        }
    }
    func setFlash(_ text: String) {
        flash = (text, Date().addingTimeInterval(1.2))
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in self?.needsDisplay = true }
    }
    var rulerOrange: NSColor { NSColor(srgbRed: 1, green: 69.0 / 255, blue: 0, alpha: 1) } // #FF4500
    func drawMeasure() {
        let pt = hoverPt
        rulerOrange.setStroke()
        // Bounds: dashed outline boxes; pill at the box's bottom-right outside corner
        for box in boundsBoxes + (measureMode == "Bounds" ? [sel].compactMap { $0 } : []) {
            let p = NSBezierPath(rect: box); p.lineWidth = 1; p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
            drawBadge(fmtDim(box.width) + " × " + fmtDim(box.height),
                      at: CGPoint(x: min(bounds.width - 90, box.maxX + 6), y: max(4, box.minY - 26)))
        }
        guard measureMode != "Bounds" else { return }
        // crisp 1-pt lines with ~8pt perpendicular feet at each edge
        if let x = rulerX {
            let p = NSBezierPath(); p.lineWidth = 1
            p.move(to: CGPoint(x: x.lo, y: pt.y)); p.line(to: CGPoint(x: x.hi, y: pt.y))
            for e in [x.lo, x.hi] { p.move(to: CGPoint(x: e, y: pt.y - 4)); p.line(to: CGPoint(x: e, y: pt.y + 4)) }
            p.stroke()
        }
        if let y = rulerY {
            let p = NSBezierPath(); p.lineWidth = 1
            p.move(to: CGPoint(x: pt.x, y: y.lo)); p.line(to: CGPoint(x: pt.x, y: y.hi))
            for e in [y.lo, y.hi] { p.move(to: CGPoint(x: pt.x - 4, y: e)); p.line(to: CGPoint(x: pt.x + 4, y: e)) }
            p.stroke()
        }
        var label = ""
        if let x = rulerX, let y = rulerY { label = "\(fmtDim(x.hi - x.lo)) × \(fmtDim(y.hi - y.lo))" }
        else if let x = rulerX { label = fmtDim(x.hi - x.lo) }
        else if let y = rulerY { label = fmtDim(y.hi - y.lo) }
        if let f = flash, Date() < f.until { label += "   \(f.text)" }
        if !label.isEmpty {
            drawBadge(label, at: CGPoint(x: min(bounds.width - 130, pt.x + 18), y: min(bounds.height - 30, pt.y + 18)))
        }
    }
    func fmtDim(_ v: CGFloat) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
    func drawBadge(_ s: String, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let size = (s as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: p.x, y: p.y, width: size.width + 14, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (s as NSString).draw(at: CGPoint(x: p.x + 7, y: p.y + 4), withAttributes: attrs)
    }
    func drawLoupe(_ ctx: CGContext) {
        guard tool != .capScreen && tool != .recScreen else { return }
        guard NSEvent.mouseLocation.x != 0 || hoverPt != .zero else { return }
        let pt = mouseInView()
        guard bounds.contains(pt) else { return } // one loupe, on the pointer's display
        let n = tool == .pickColour ? 15 : 11, px = 11
        let sz = CGFloat(n * px)
        let c = Freeze.shared.pixel(at: pt, on: di)
        // colour info block under the grid (Pick Colour only) — counts towards
        // the loupe's total height for edge flipping
        let rows: [(String, Bool)] = tool == .pickColour
            ? [ColourFormat.hex, .rgb, .hsl, .oklch, .lab].map { ($0.format(c), AppState.shared.colourFmt == $0.rawValue) }
            : []
        let infoH: CGFloat = rows.isEmpty ? 20 : CGFloat(rows.count) * 14 + 12
        let totalH = sz + 6 + infoH
        // default above-right of the pointer; flip below if it crosses the top,
        // left if it crosses the right edge; then clamp inside the screen
        var lx = pt.x + 26, ly = pt.y + 20
        if ly + totalH > bounds.height - 4 { ly = pt.y - 20 - totalH }
        if lx + sz > bounds.width - 4 { lx = pt.x - 26 - sz }
        lx = min(max(4, lx), bounds.width - sz - 4)
        ly = min(max(4, ly), bounds.height - totalH - 4)
        // exactly n×n bitmap pixels centred on the pointer's pixel; at image
        // edges the crop is drawn at its matching cell offset so the centre
        // cell always shows the pointer's pixel
        let f = fd
        let pp = Freeze.shared.pointerPixel(pt, on: di)
        let n2 = n / 2
        let x0 = pp.x - n2, y0 = pp.y - n2
        let ix0 = max(0, x0), iy0 = max(0, y0)
        let ix1 = min(f.image.width - 1, x0 + n - 1), iy1 = min(f.image.height - 1, y0 + n - 1)
        let cell = CGFloat(px), gridY = ly + infoH + 6
        if ix1 >= ix0, iy1 >= iy0,
           let crop = f.image.cropping(to: CGRect(x: ix0, y: iy0, width: ix1 - ix0 + 1, height: iy1 - iy0 + 1)) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: lx + CGFloat(ix0 - x0) * cell,
                                     y: gridY + sz - CGFloat(iy1 - y0 + 1) * cell,
                                     width: CGFloat(ix1 - ix0 + 1) * cell,
                                     height: CGFloat(iy1 - iy0 + 1) * cell))
            ctx.restoreGState()
        }
        // centre pixel outline + border — stroke inset so it stays inside the cell
        let mid = CGFloat(n / 2 * px)
        NSColor.white.setStroke()
        let cc = NSBezierPath(rect: NSRect(x: lx + mid + 0.5, y: gridY + mid + 0.5, width: cell - 1, height: cell - 1))
        cc.lineWidth = 1; cc.stroke()
        NSColor.black.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: NSRect(x: lx, y: ly, width: sz, height: totalH), xRadius: 8, yRadius: 8).stroke()
        if rows.isEmpty {
            // display-relative, top-left origin like the system screenshot tool
            drawBadge("\(Int(pt.x)), \(Int(bounds.height - pt.y))  \(ColourFormat.hex.format(c))", at: CGPoint(x: lx, y: ly + 2))
            return
        }
        // info block: swatch + hex on row 0, then rgb/hsl/oklch/lab; the row of
        // the active copy format is drawn brighter
        let block = NSRect(x: lx, y: ly, width: sz, height: infoH)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: block, xRadius: 7, yRadius: 7).fill()
        for (i, row) in rows.enumerated() {
            let ry = ly + infoH - 16 - CGFloat(i) * 14
            if i == 0 {
                let sw = NSRect(x: lx + 8, y: ry - 1, width: 10, height: 10)
                NSColor(calibratedRed: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255, alpha: 1).setFill()
                NSBezierPath(roundedRect: sw, xRadius: 2, yRadius: 2).fill()
            }
            let bright = row.1 ? 1.0 : 0.55
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(bright)]
            (row.0 as NSString).draw(at: CGPoint(x: lx + 22, y: ry - 1), withAttributes: attrs)
        }
    }
    // the pointer in this display's view coords (screen -> window -> view)
    func mouseInView() -> CGPoint {
        convert(window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero, from: nil)
    }

    override func mouseMoved(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil); hoverPt = pt
        // the pointer moved here from another display: clear that one's loupe
        if OverlayNSView.pointerDisplay != di {
            OverlayNSView.pointerDisplay = di
            ctrl?.panels.forEach { $0.contentView?.subviews.compactMap { $0 as? OverlayNSView }.forEach { $0.needsDisplay = true } }
        }
        if tool == .capWindow || tool == .recWindow {
            hoverWin = fd.windowFrames.first { $0.frame.contains(pt) } // front-to-back: frontmost wins
        } else {
            hoverWin = nil
        }
        if tool == .measure {
            NSCursor.crosshair.set()
            if measureMode != "Bounds" { scanRuler(at: pt) }
        } else {
            NSCursor.arrow.set()
        }
        needsDisplay = true
    }
    // one scroll tick per wheel notch; trackpads accumulate 24 pt per tick and
    // momentum is ignored. Returns +1 for down (next) / -1 for up (previous)
    func scrollStep(_ e: NSEvent) -> Int {
        guard e.momentumPhase.isEmpty, e.scrollingDeltaY != 0 else { return 0 }
        if !e.hasPreciseScrollingDeltas { return e.scrollingDeltaY > 0 ? -1 : 1 }
        if e.phase == .began { scrollAcc = 0 }
        scrollAcc += e.scrollingDeltaY
        var n = 0
        while scrollAcc >= 24 { scrollAcc -= 24; n += 1 }
        while scrollAcc <= -24 { scrollAcc += 24; n -= 1 }
        return n
    }
    override func scrollWheel(with e: NSEvent) {
        let step = scrollStep(e)
        guard step != 0 else { return }
        if e.modifierFlags.contains(.option) {
            // Option+scroll = the Tool's value: edge tolerance on the ruler
            guard tool == .measure, measureMode != "Bounds" else { return }
            tolerance = min(255, max(0, tolerance - 15 * step))
            setFlash("tolerance \(tolerance)")
            scanRuler(at: hoverPt)
            needsDisplay = true
            return
        }
        cycleVariant(step)
    }
    // plain scroll cycles the selected Tool's variants, wrapping at both ends
    func cycleVariant(_ step: Int) {
        let s = AppState.shared
        guard let t = s.tool else { return }
        func wrap(_ i: Int, _ n: Int) -> Int { ((i + step) % n + n) % n }
        switch t {
        case .capRegion, .capWindow, .capScreen:
            let l: [Tool] = [.capRegion, .capWindow, .capScreen]
            let n = l[wrap(l.firstIndex(of: t)!, l.count)]
            AppDelegate.shared?.trigger(n); setFlash(n.title)
        case .recRegion, .recWindow, .recScreen:
            let l: [Tool] = [.recRegion, .recWindow, .recScreen]
            let n = l[wrap(l.firstIndex(of: t)!, l.count)]
            AppDelegate.shared?.trigger(n); setFlash(n.title)
        case .measure:
            let modes = ["Bounds", "Spacing", "Horizontal", "Vertical"]
            let i = wrap(modes.firstIndex(of: measureMode) ?? 1, modes.count)
            AppDelegate.shared?.setMeasureMode(i); setFlash(modes[i])
        case .pickColour:
            let fmts = ColourFormat.allCases.map(\.rawValue)
            let i = wrap(fmts.firstIndex(of: s.colourFmt) ?? 0, fmts.count)
            s.colourFmt = fmts[i]; setFlash(fmts[i])
        case .copyText: break
        }
    }
    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        AppLog.line("mouseDown \(tool.title) d\(di) @\(Int(pt.x)),\(Int(pt.y))")
        switch tool {
        case .capScreen, .recScreen:
            app?.didSelect(bounds, on: di)
        case .capWindow, .recWindow:
            if let w = hoverWin { app?.didSelectWindow(id: w.id, frame: w.frame, on: di) }
        case .pickColour:
            let c = Freeze.shared.pixel(at: pt, on: di)
            let s = (ColourFormat(rawValue: AppState.shared.colourFmt) ?? .hex).format(c)
            clipboard(s); showHUD("Copied \(s)", swatch: ColourFormat.hex.format(c))
            ctrl?.closeAll()
        case .measure where measureMode != "Bounds":
            if let v = rulerLabel() { copyMeasureAndClose(v) }
        default:
            dragStart = pt; sel = CGRect(origin: pt, size: .zero)
        }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        guard let st = dragStart else { return }
        let pt = convert(e.locationInWindow, from: nil)
        // Bounds ignores Option/Shift: Shift means "keep this box" at mouseUp
        if tool == .measure && measureMode == "Bounds" {
            sel = rectNorm(st, pt)
        } else if e.modifierFlags.contains(.option) {
            sel = CGRect(x: st.x - abs(pt.x - st.x), y: st.y - abs(pt.y - st.y), width: 2 * abs(pt.x - st.x), height: 2 * abs(pt.y - st.y))
        } else if e.modifierFlags.contains(.shift) {
            let w = pt.x - st.x, h = pt.y - st.y, m = max(abs(w), abs(h))
            sel = rectNorm(st, CGPoint(x: st.x + (w >= 0 ? m : -m), y: st.y + (h >= 0 ? m : -m)))
        } else {
            sel = rectNorm(st, pt)
        }
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        defer { needsDisplay = true }
        AppLog.line("mouseUp \(tool.title) sel=\(sel.debugDescription)")
        if tool == .measure, measureMode == "Bounds", let s = sel, dragStart != nil, s.width > 4 && s.height > 4 {
            dragStart = nil
            copyMeasure(fmtDim(s.width) + " × " + fmtDim(s.height))
            if e.modifierFlags.contains(.shift) { boundsBoxes.append(s); sel = nil } // keep the box, stay open
            else { ctrl?.closeAll() }
            return
        }
        guard let s = sel, dragStart != nil else { return }
        dragStart = nil
        if tool == .copyText { copyText(in: s); ctrl?.closeAll(); return }
        if (tool == .capRegion || tool == .recRegion) && s.width > 4 && s.height > 4 { app?.didSelect(s, on: di); return }
        sel = nil
    }
    // called from the local key monitor (nonactivating panels don't get keyDown)
    @discardableResult
    func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { ctrl?.closeAll(); return true }
        if e.keyCode == 49 { app?.toggleRegionWindow(); return true } // Space
        // Ctrl+1..4 switch Measure modes while the overlay is open
        if tool == .measure, e.modifierFlags.contains(.control),
           let i = [18, 19, 20, 21].firstIndex(of: Int(e.keyCode)) {
            app?.setMeasureMode(i)
            return true
        }
        return false
    }
    override func keyDown(with e: NSEvent) { _ = handleKey(e) }
    func rectNorm(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    var app: AppDelegate? { ctrl?.app }

    // OCR — recognition runs off the main actor; the overlay closes at once and a
    // "Recognising text…" toast stays up until the text lands on the pasteboard.
    func copyText(in rect: CGRect) {
        let crop = Freeze.shared.crop(rect: rect, on: di)
        ctrl?.closeAll()
        guard let crop, let tc = app?.toastCtrl else { return }
        let item = tc.pending("Recognising text…")
        Task.detached { [crop] in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate; req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: crop).perform([req])
            let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            await MainActor.run {
                AppLog.line("ocr: \(lines.count) lines -> \(lines.joined(separator: " | "))")
                clipboard(lines.joined(separator: "\n"))
                item.title = "Copied \(lines.count) line\(lines.count == 1 ? "" : "s")"
                tc.startTimer(item)
            }
        }
    }

    // Screen Ruler: walk the Freeze Frame bitmap outward from the pointer pixel
    // until a pixel differs from it by more than `tolerance` (sum of |ΔRGB|)
    func scanRuler(at pt: CGPoint) {
        rulerX = nil; rulerY = nil
        guard let pixels = fd.pixels else { return }
        let sx = CGFloat(pixels.width) / bounds.width, sy = CGFloat(pixels.height) / bounds.height
        let (px, py) = Freeze.shared.pointerPixel(pt, on: di)
        if measureMode != "Vertical" { // Spacing + Horizontal
            let r = pixels.run(through: px, py, along: .horizontal, tolerance: tolerance)
            rulerX = (CGFloat(r.lowerBound) / sx, CGFloat(r.upperBound) / sx)
        }
        if measureMode != "Horizontal" { // Spacing + Vertical
            let r = pixels.run(through: px, py, along: .vertical, tolerance: tolerance)
            // bitmap y is top-down; view y is bottom-up
            rulerY = (bounds.height - CGFloat(r.upperBound) / sy, bounds.height - CGFloat(r.lowerBound) / sy)
        }
    }
    func rescanRuler() {
        if measureMode != "Bounds" { scanRuler(at: hoverPt) }
        needsDisplay = true
    }
    // the label a click would copy, matching what drawMeasure shows
    func rulerLabel() -> String? {
        if let x = rulerX, let y = rulerY { return "\(fmtDim(x.hi - x.lo)) × \(fmtDim(y.hi - y.lo))" }
        if let x = rulerX { return fmtDim(x.hi - x.lo) }
        if let y = rulerY { return fmtDim(y.hi - y.lo) }
        return nil
    }
    func copyMeasure(_ c: String) {
        clipboard(c); showHUD("Copied \(c)", swatch: nil)
    }
    func copyMeasureAndClose(_ c: String) {
        copyMeasure(c); ctrl?.closeAll()
    }
    func showHUD(_ text: String, swatch: String?) {
        ToastController.shared?.flash(text, swatch: swatch)
    }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
}

// MARK: - Toolbar SwiftUI

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    // Everything outside the current island/toolbar shape is click-through, so
    // the panel never shadows the selection layer underneath it.
    var displayIndex = 0
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let rect = ToolbarHit.rects[displayIndex] ?? .zero
        let hit = rect.contains(point)
        if hit != ToolbarHit.lastHit[displayIndex] { ToolbarHit.lastHit[displayIndex] = hit; AppLog.line("hitTest d\(displayIndex) \(hit ? "in" : "out") @\(Int(point.x)),\(Int(point.y)) rect=\(rect.debugDescription)") }
        return hit ? super.hitTest(point) : nil
    }
}

enum ToolbarHit {
    nonisolated(unsafe) static var rects: [Int: CGRect] = [:] // per display index
    nonisolated(unsafe) static var lastHit: [Int: Bool] = [:]
}
// measured button frames in each toolbar panel's coordinate space, reported by
// onGeometryChange — used for hover mapping, menu anchors and CGEvent driving
enum ToolbarBtnFrames {
    nonisolated(unsafe) static var rects: [Int: [Tool: CGRect]] = [:]
    nonisolated(unsafe) static var blobRect: [Int: CGRect] = [:] // menu droplet per display
}

struct ToolbarView: View {
    let displayIndex: Int
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    var expanded: Bool { s.expandedDisplay == displayIndex }
    @Namespace var ns
    var screen: NSScreen? {
        displayIndex < Freeze.shared.displays.count ? Freeze.shared.displays[displayIndex].screen : NSScreen.main
    }
    var hasNotch: Bool { (screen?.safeAreaInsets.top ?? 0) > 0 && !s.islandMode }
    // menu bar band height on this display (the island lives inside it)
    var barH: CGFloat {
        guard let sc = screen else { return 24 }
        return max(0, sc.frame.maxY - sc.visibleFrame.maxY)
    }
    var notchW: CGFloat {
        guard hasNotch, let sc = screen else { return 0 }
        let l = sc.auxiliaryTopLeftArea?.width ?? 0, r = sc.auxiliaryTopRightArea?.width ?? 0
        return max(0, sc.frame.width - l - r)
    }
    var recording: Bool { s.phase == .recording && s.showIslandWhileRecording }

    // Notched display: black, flush with the top edge, rounded bottom corners,
    // centred on (and slightly wider than) the notch.
    // Other displays: a fake Dynamic Island, a black capsule floating inside the
    // menu bar band with a small gap above it. Both show the current Tool's icon
    // and an expand chevron (or the recording dot and time) in ears either side
    // of the notch, so the toolbar is visible while collapsed.
    var earW: CGFloat { recording ? 48 : 28 }
    var islandW: CGFloat { hasNotch ? max(126, notchW + 2 * earW) : (recording ? 120 : 100) }
    var islandH: CGFloat { max(22, barH) }
    var gap: CGFloat { hasNotch ? 0 : 3 }
    var pillH: CGFloat { islandH - 2 * gap }
    // expanded toolbar: 9 big circular glass buttons in three groups. The shape
    // is sized from the *measured* row — never a hand-coded width — so the
    // buttons can never be clipped.
    @State var rowSize = CGSize(width: 520, height: 66)
    // The row sits rowGap below the menu bar on every display. Notched display:
    // the shape hangs from the top edge and its top band holds the notch.
    // Island: the expanded shape drops below the menu bar, covering none of it.
    var rowInset: CGFloat { 10 }
    var rowGap: CGFloat { 6 }
    var shapeTop: CGFloat { expanded && !hasNotch ? islandH : gap }
    var contentTop: CGFloat { (hasNotch ? islandH : 0) + rowGap }
    var recExpandedW: CGFloat { 260 }
    var expW: CGFloat { min(limit, rowSize.width + 2 * rowInset) }
    var expH: CGFloat { contentTop + rowSize.height + rowInset }
    var shapeW: CGFloat { expanded ? (recording ? recExpandedW : expW) : islandW }
    var shapeH: CGFloat { expanded ? expH : pillH }
    var panelW: CGFloat { min(limit, expW) + 48 }
    // menus and tooltips are their own panels
    var panelH: CGFloat { (hasNotch ? 0 : islandH) + expH + 12 }
    var shapeRectInView: CGRect {
        CGRect(x: (panelW - shapeW) / 2, y: panelH - shapeTop - shapeH, width: shapeW, height: shapeH)
    }
    // one rect drives both click-through and the expand decision. Expanded on
    // an island display: shape ∪ collapsed island ∪ a bridge strip, so resting
    // on the island or sliding down into the toolbar doesn't collapse it.
    var hoverRect: CGRect {
        let sh = shapeRectInView
        if hasNotch || !expanded { return sh }
        let isl = CGRect(x: (panelW - islandW) / 2, y: panelH - gap - pillH, width: islandW, height: pillH)
        return sh.union(isl).union(CGRect(x: isl.minX, y: sh.maxY, width: isl.width, height: max(0, isl.minY - sh.maxY)))
    }

    var limit: CGFloat { (screen?.frame.width ?? 1280) - 40 }

    // the pointer in the panel view's coords, against hoverRect
    func pointerInside() -> Bool {
        guard let p = ctrl.toolbarPanels[displayIndex] else { return false }
        // the content view fills the panel, so view coords = screen - origin
        let q = CGPoint(x: NSEvent.mouseLocation.x - p.frame.minX,
                        y: NSEvent.mouseLocation.y - p.frame.minY)
        return hoverRect.contains(q)
    }
    func syncExpanded() {
        let h = hoverInside || s.openMenu != nil || lensActive
        if h != expanded { AppLog.line("hover d\(displayIndex) -> \(h)") }
        if h { s.expandedDisplay = displayIndex }
        else if s.expandedDisplay == displayIndex { s.expandedDisplay = nil }
    }

    func syncHit() {
        ToolbarHit.rects[displayIndex] = hoverRect
        if expanded {
            let xs = [Tool.capRegion, .capWindow, .capScreen, .recRegion, .recWindow, .recScreen, .pickColour, .copyText, .measure]
                .compactMap { t -> String? in
                    guard let f = ctrl.buttonScreenRect(t, on: displayIndex) else { return nil }
                    return "\(t.title):\(Int(f.midX))"
                }.joined(separator: " ")
            AppLog.line("toolbar icons d\(displayIndex) @ \(xs)")
        }
    }

    var body: some View {
        morph
            .frame(width: panelW, height: panelH, alignment: .top)
            .coordinateSpace(name: "panel")
            // hoverInside tracks the pointer; the bar stays expanded while it
            // is inside, a menu is open, or the selection lens is pressed
            .onContinuousHover(coordinateSpace: .named("panel")) { phase in
                switch phase {
                case .active(let p):
                    // p is in SwiftUI coords (top-left); hoverRect is in the
                    // view's coords — convert
                    hoverInside = hoverRect.contains(CGPoint(x: p.x, y: panelH - p.y))
                case .ended:
                    // hover events can stop during a drag — recompute from the
                    // live pointer position, in the view's coords
                    hoverInside = pointerInside()
                }
            }
            .onChange(of: hoverInside) { syncExpanded() }
            .onChange(of: lensActive) { syncExpanded() }
            .onAppear { syncHit() }
            .onChange(of: rowSize) { syncHit() }
            .onChange(of: expanded) {
                syncHit()
                if !expanded { s.openMenu = nil; ctrl.hideMenu(); TipPanel.hide() }
            }
            .onChange(of: s.openMenu) { ctrl.syncMenu(); syncExpanded() }
            .onChange(of: s.tool) { s.openMenu = nil; ctrl.hideMenu(); TipPanel.hide(); ToolbarBtnFrames.blobRect[displayIndex] = nil; syncHit() }
    }

    var shape: UnevenRoundedRectangle {
        // expanded: fully rounded ends (radius = half the shape's height) —
        // all four corners on the island, bottom two under a notch
        let bottom: CGFloat = expanded ? shapeH / 2 : (hasNotch ? 13 : pillH / 2)
        let top: CGFloat = hasNotch ? 0 : bottom
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top)
    }

    var morph: some View {
        ZStack(alignment: .top) {
            // collapsed fill sits under the island icons, not over them
            shape.fill(Color.black).opacity(expanded ? 0 : 1).allowsHitTesting(false)
            expandedContent
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.7, anchor: .top)
                .frame(width: shapeW, height: shapeH, alignment: .top)
            islandContent
                .opacity(expanded ? 0 : 1)
                .frame(width: shapeW, height: shapeH)
        }
        .frame(width: shapeW, height: shapeH)
        .clipShape(shape) // nothing may draw outside the island/toolbar shape
        .glassEffect(.regular.tint(.black.opacity(0.4)).interactive(), in: shape)
        .glassEffectID("pill", in: ns)
        .contentShape(shape)
        .padding(.top, shapeTop)
        .animation(.spring(duration: 0.35), value: expanded)
    }

    // island contents, Dynamic-Island-style: one leading item concentric with
    // the rounded end cap (its centre pillH/2 from the edge). Frozen: the
    // current Tool's icon only. Recording: red dot leading, elapsed trailing.
    // island: items sit concentric with the end caps; notch: centred in the ears
    var islandSlot: CGFloat { hasNotch ? earW : pillH + 6 }
    var islandContent: some View {
        HStack(spacing: 0) {
            if recording {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .frame(width: islandSlot, height: pillH)
            } else {
                Image(systemName: (s.tool ?? .capRegion).symbol)
                    .font(.system(size: min(pillH * 0.45, islandSlot - 14)))
                    .frame(width: islandSlot, height: pillH)
            }
            Spacer(minLength: 0)
            if recording {
                Text(fmtT(s.recordingElapsed)).font(.system(size: 12)).monospacedDigit()
                    .frame(width: islandSlot, height: pillH)
            }
        }
        .foregroundStyle(.white)
        .frame(width: islandW, height: pillH)
    }

    @ViewBuilder var expandedContent: some View {
        if recording { recControls } else { toolRow }
    }

    var recControls: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(fmtT(s.recordingElapsed)).font(.system(size: 12)).monospacedDigit()
            Button(s.recordingPaused ? "Resume" : "Pause") { AppDelegate.shared?.togglePause() }
            Button("Stop") { AppDelegate.shared?.stopRecording() }
        }
        .font(.system(size: 12))
        .padding(.top, contentTop)
    }

    let toolD: CGFloat = 72
    let selW: CGFloat = 92, selH: CGFloat = 64 // rest capsule size; lens = ×1.15
    // tab-bar state: cell centres measured in row space, capsule centre same
    @State var cellCentres: [Tool: CGPoint] = [:]
    @State var blobX: CGFloat = 0
    @State var blobY: CGFloat = 0
    @State var pressing = false   // finger down, before/without the drag threshold
    @State var dragging = false
    @State var pressX: CGFloat = 0
    @State var pressTool: Tool?
    @State var pressActive = false
    @State var menuByHold = false
    @State var holdTask: Task<Void, Never>?
    @State var hoverInside = false
    var lensActive: Bool { pressing || dragging }

    func openToolMenu(_ t: Tool) {
        guard t.hasMenu else { return }
        TipPanel.hide()
        if s.tool != t { AppDelegate.shared?.trigger(t) }
        s.openMenu = s.openMenu == t ? nil : t
        ctrl.syncMenu()
    }
    func nearestTool(to x: CGFloat) -> Tool? { cellCentres.min { abs($0.value.x - x) < abs($1.value.x - x) }?.key }
    var rowEnds: (CGFloat, CGFloat) {
        let xs = cellCentres.values.map(\.x)
        return (xs.min() ?? 0, xs.max() ?? 0)
    }
    // the icon strip once, for the accent-tint mask — same layout as the row
    func iconCell(_ t: Tool) -> some View {
        Image(systemName: t.symbol).font(.system(size: 22))
            .frame(width: toolD, height: toolD)
    }

    var selShape: some View {
        Capsule().frame(width: lensActive ? selW * 1.15 : selW, height: lensActive ? selH * 1.15 : selH)
    }

    func lens(_ glass: Glass) -> some View {
        Capsule().fill(.clear)
            .frame(width: lensActive ? selW * 1.15 : selW, height: lensActive ? selH * 1.15 : selH)
            .glassEffect(lensActive ? glass : .identity, in: .capsule)
            .glassEffectTransition(.materialize)
            .position(x: blobX, y: blobY) // after the glass, or the capsule spans the whole row
            .allowsHitTesting(false)
    }

    // one cell of the tab bar: plain white icon, cut out wherever the
    // capsule/lens covers it — the accent overlay row draws that part
    func cell(_ t: Tool) -> some View {
        let selected = s.tool == t
        let c = cellCentres[t] ?? .zero
        return Image(systemName: t.symbol).font(.system(size: 22))
            .foregroundStyle(.white)
            .frame(width: toolD, height: toolD)
            .contentShape(Rectangle()) // whole cell, not just the glyph
            .mask {
                ZStack {
                    Rectangle()
                    selShape.offset(x: blobX - c.x, y: blobY - c.y).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                // the menu droplet budding off the rest capsule's corner —
                // hidden while pressing/dragging; high-priority tap so the
                // row's drag can't take it
                if t.hasMenu && selected && !lensActive {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID("menu-\(t)", in: ns)
                        .contentShape(Circle())
                        .highPriorityGesture(TapGesture().onEnded { openToolMenu(t) })
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { ToolbarBtnFrames.blobRect[displayIndex] = $0 }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .offset(x: 6, y: -8) // ~4 pt inside the capsule's corner
                }
            }
            .overlay(RightClickCatcher { openToolMenu(t) })
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named("row")).origin } action: {
                // keep the whole frame's centre in row space
                cellCentres[t] = CGPoint(x: $0.x + toolD / 2, y: $0.y + toolD / 2)
                if !lensActive, s.tool == t { blobX = $0.x + toolD / 2; blobY = $0.y + toolD / 2 }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: {
                ToolbarBtnFrames.rects[displayIndex, default: [:]][t] = $0
            }
    }

    var toolRow: some View {
        // rest highlight sits below the icons in .background; the glass lens
        // goes on top with the clear-glass patch (it must refract the icons)
        // and behind them without it
        HStack(spacing: 8) {
            ForEach([Tool.capRegion, .capWindow, .capScreen], id: \.self, content: cell)
            Spacer().frame(width: 8) // +8 in-group spacing = 16 between groups
            ForEach([Tool.recRegion, .recWindow, .recScreen], id: \.self, content: cell)
            Spacer().frame(width: 8)
            ForEach([Tool.pickColour, .copyText, .measure], id: \.self, content: cell)
        }
        // 20 pt horizontal inset so the lens can't poke through the rounded ends
        .padding(.horizontal, 20).padding(.vertical, 10)
        .coordinateSpace(name: "row")
        .background {
            // rest: subtle translucent highlight (no glass)
            Capsule().fill(.white.opacity(lensActive ? 0 : 0.10))
                .frame(width: lensActive ? selW * 1.15 : selW, height: lensActive ? selH * 1.15 : selH)
                .position(x: blobX, y: blobY)
        }
        // the accent tint follows the lens, clipped to its shape — the icon row
        // is drawn a second time in accent, masked to a capsule at blobX
        .overlay {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([Tool.capRegion, .capWindow, .capScreen], id: \.self, content: iconCell)
                    Spacer().frame(width: 8)
                    ForEach([Tool.recRegion, .recWindow, .recScreen], id: \.self, content: iconCell)
                    Spacer().frame(width: 8)
                    ForEach([Tool.pickColour, .copyText, .measure], id: \.self, content: iconCell)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                // magnified about the lens centre, so only what's inside the lens looks bigger
                .scaleEffect(lensActive ? lensZoom : 1, anchor: rowSize.width > 0
                             ? UnitPoint(x: blobX / rowSize.width, y: blobY / rowSize.height) : .center)
            }
            .mask(selShape.position(x: blobX, y: blobY))
            .foregroundStyle(Color.wadjetAccent)
            .allowsHitTesting(false)
        }
        // the glass lens: identity glass at rest, glass while pressing —
        // animating the effect, never inserted. With the clear-glass patch it
        // sits on top and refracts the icons; without it, glass would blur and
        // tint them, so regular glass sits behind the icons instead
        #if CLEAR_GLASS_PATCH
        .overlay { lens(.clear) }
        #else
        .background { lens(.regular) }
        #endif
        .fixedSize()
        .contentShape(Rectangle()) // press anywhere in the row, gaps included
        .animation(.smooth(duration: 0.15), value: lensActive) // lens on/off
        .onGeometryChange(for: CGSize.self) { $0.size } action: { if rowSize != $0 { rowSize = $0; ctrl.resizeToolbar(panelW, panelH, on: displayIndex); AppLog.line("rowSize d\(displayIndex) -> \($0.debugDescription)") } }
        // press = lens pops in under the finger, flick = drag it, hold = menu
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("row"))
            .onChanged { v in
                if !pressActive { // first event of the press: lens in at once
                    pressActive = true; pressing = true
                    pressX = v.startLocation.x
                    pressTool = nearestTool(to: v.startLocation.x) // gaps pick the nearest cell
                    // it slides to the pressed cell with the click spring
                    if let t = pressTool, let c = cellCentres[t], c.x != blobX {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { blobX = c.x }
                    }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled, let t = pressTool, !dragging {
                            menuByHold = true; pressing = false // lens back to rest
                            openToolMenu(t)
                        }
                    }
                }
                if !dragging, abs(v.location.x - pressX) > 4 {
                    dragging = true; holdTask?.cancel(); TipPanel.hide()
                }
                if dragging {
                    let (lo, hi) = rowEnds
                    blobX = min(hi, max(lo, v.location.x))
                }
            }
            .onEnded { v in
                holdTask?.cancel()
                let wasDragging = dragging
                pressing = false; dragging = false
                // hover events may not have arrived during the drag — refresh
                // before lensActive falls, so releasing outside collapses
                hoverInside = pointerInside()
                if wasDragging {
                    if let n = nearestTool(to: v.location.x) {
                        if n != s.tool { AppDelegate.shared?.trigger(n) }
                        // shrink back to the rest capsule on the chosen cell
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { blobX = cellCentres[n]?.x ?? blobX }
                    }
                } else if !menuByHold, let t = nearestTool(to: v.location.x), t != s.tool {
                    AppDelegate.shared?.trigger(t)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { blobX = cellCentres[t]?.x ?? blobX }
                }
                pressTool = nil; pressActive = false; menuByHold = false
            })
        // map the pointer to a Tool cell using measured frames
        .onContinuousHover(coordinateSpace: .named("panel")) { phase in
            switch phase {
            case .active(let p):
                if dragging { TipPanel.hide() }
                else if let b = ToolbarBtnFrames.blobRect[displayIndex], b.contains(p) { TipPanel.hide() }
                else if let t = (ToolbarBtnFrames.rects[displayIndex] ?? [:]).first(where: { $0.value.contains(p) })?.key {
                    if TipPanel.tool != t { AppLog.line("hover map -> \(t.title) p=\(Int(p.x)),\(Int(p.y)) frames=\(ToolbarBtnFrames.rects[displayIndex]?.count ?? 0)") }
                    TipPanel.hover(t, anchor: ctrl.buttonScreenRect(t, on: displayIndex) ?? .zero)
                } else { if TipPanel.tool != nil { AppLog.line("hover map -> none p=\(Int(p.x)),\(Int(p.y))") }; TipPanel.hide() }
            case .ended: TipPanel.hide()
            }
        }
        .onChange(of: s.tool) {
            if !dragging, let t = s.tool, let c = cellCentres[t] {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { blobX = c.x; blobY = c.y }
            }
        }
        .padding(.top, contentTop)
    }
}

// catches right-clicks without blocking left ones — the view only claims the
// hit while a rightMouseDown is being dispatched
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> RCView { let v = RCView(); v.onRight = action; return v }
    func updateNSView(_ v: RCView, context: Context) { v.onRight = action }
}
final class RCView: NSView {
    var onRight: () -> Void = {}
    override func hitTest(_ p: NSPoint) -> NSView? { NSApp.currentEvent?.type == .rightMouseDown ? self : nil }
    override func rightMouseDown(with e: NSEvent) { onRight() }
}

// the hover tooltip is its own borderless panel below-right of the pointer —
// .help doesn't work in a nonactivating panel and an in-panel label can't
// reach outside the toolbar's shape
@MainActor
enum TipPanel {
    static var panel: NSPanel?
    static var task: Task<Void, Never>?
    static var tool: Tool? // button currently hovered, so the tip doesn't chase
    static func hover(_ t: Tool, anchor: CGRect) {
        tool = t
        task?.cancel()
        let a = anchor
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, AppState.shared.openMenu == nil else { return }
            show(t, anchor: a)
        }
    }
    static func show(_ t: Tool, anchor: CGRect) {
        panel?.close()
        let label = t.title + (t.shortcut.map { "  " + $0 } ?? "")
        let h = NSHostingView(rootView: Text(label).font(.system(size: 11)).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.black.opacity(0.85), in: .rect(cornerRadius: 6)))
        h.frame.size = h.fittingSize
        var f = NSRect(origin: CGPoint(x: anchor.maxX - 32 + 12, y: anchor.minY - 28 - h.fittingSize.height),
                       size: h.fittingSize)
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) {
            f.origin.x = min(max(scr.frame.minX + 4, f.origin.x), scr.frame.maxX - f.width - 4)
            f.origin.y = max(scr.frame.minY + 4, f.origin.y)
        }
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver + 3; p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces]; p.ignoresMouseEvents = true
        p.contentView = h; p.orderFront(nil); panel = p
        AppLog.line("tip \(label) anchor=\(Int(anchor.midX)),\(Int(anchor.midY)) at \(Int(f.origin.x)),\(Int(f.origin.y))")
    }
    static func hide() { task?.cancel(); task = nil; tool = nil; panel?.close(); panel = nil }
}

// a Tool's dropdown menu: its own dark panel under the button. Radio rows
// close it; toggles leave it open.
struct ToolMenuView: View {
    let tool: Tool
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch tool.kind {
            case .shot:
                section("Workflow", picks: s.workflows(for: tool), current: s.workflowFor(tool)) { s.workflowByTool[tool] = $0 }
            case .rec:
                section("Workflow", picks: s.workflows(for: tool), current: s.workflowFor(tool)) { s.workflowByTool[tool] = $0 }
                Text("Options").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                section("Countdown", picks: ["Off", "3 s", "5 s", "10 s"], current: s.countdown == "Off" ? "Off" : s.countdown + " s") { v in s.countdown = v.replacingOccurrences(of: " s", with: "") }
                toggles()
            case .util where tool == .pickColour:
                section("Copy as", picks: ColourFormat.allCases.map(\.rawValue), current: s.colourFmt) { s.colourFmt = $0 }
            case .util where tool == .measure:
                section("", picks: ["Bounds", "Spacing", "Horizontal", "Vertical"], current: s.measureMode) { s.measureMode = $0 }
            default: EmptyView()
            }
        }
        .padding(6)
        .fixedSize()
        .background(Color.black.opacity(0.9), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }
    @ViewBuilder func section(_ title: String, picks: [String], current: String?, pick: @escaping (String) -> Void) -> some View {
        if !title.isEmpty {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
        }
        ForEach(picks, id: \.self) { w in
            Button {
                pick(w); s.openMenu = nil; ctrl.syncMenu()
            } label: {
                HStack {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .opacity(w == current ? 1 : 0)
                    Text(w).font(.system(size: 13)).foregroundStyle(.white)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    @ViewBuilder func toggles() -> some View {
        let rows: [(String, Binding<Bool>)] = [
            ("System audio", $s.sysAudio), ("Microphone", $s.mic), ("Show cursor", $s.cursor),
            ("Click circles", $s.clickCircles), ("Show island while recording", $s.showIslandWhileRecording)]
        ForEach(rows, id: \.0) { label, on in
            Toggle(isOn: on) {
                Text(label).font(.system(size: 13)).foregroundStyle(.white)
            }
            .toggleStyle(.checkbox)
            .frame(minHeight: 26)
            .padding(.horizontal, 10)
        }
    }
}


// MARK: - Toasts

struct Capture {
    let thumb: CGImage?; let label: String; let url: URL?; let duration: TimeInterval?
    var kindShot: Bool { duration == nil }
}

@MainActor
final class ToastItem: ObservableObject, Identifiable {
    let id = UUID(); let cap: Capture
    @Published var title = ""; @Published var sub = ""; @Published var err: String? = nil
    @Published var showRing = false
    @Published var showBar = false
    @Published var showRetry = false
    @Published var showCancel = false
    @Published var progress: Double = 0
    var remaining: TimeInterval = 5; var timer: Timer?; var t0 = Date()
    init(cap: Capture) { self.cap = cap }
}

@MainActor
final class ToastController: ObservableObject {
    static var shared: ToastController?
    @Published var items: [ToastItem] = []
    var panel: NSPanel!
    init() {
        ToastController.shared = self
        let h = NSHostingView(rootView: ToastStackView().environmentObject(self))
        hosting = h
        h.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let f = NSScreen.main!.frame
        let p = NSPanel(contentRect: NSRect(x: f.maxX - 312, y: f.maxY - 26 - 10 - 420, width: 300, height: 420),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces]
        p.contentView = h; p.orderFront(nil)
        panel = p
    }
    var hosting: NSView!
    // keep the window fitted to whatever the stack currently holds; generous
    // transparent margin so card shadows never clip on the panel edge
    func relayout() {
        guard let panel, let hosting else { return }
        let n = items.count
        let h = max(1, min(3, n))
        let fh = CGFloat(h) * 190 + (n > 3 ? 30 : 0) + 56
        var f = panel.frame
        f.size = NSSize(width: 320, height: fh)
        f.origin.x = (NSScreen.main?.frame.maxX ?? 0) - 12 - f.width
        f.origin.y = (NSScreen.main?.frame.maxY ?? 0) - 26 - 10 - fh
        hosting.frame.size = f.size
        panel.setFrame(f, display: true)
    }
    func start(cap: Capture, workflow wf: String) {
        let t = ToastItem(cap: cap)
        items.insert(t, at: 0)
        relayout()
        AppDelegate.shared?.updateEscHotkey()
        let s = AppState.shared
        let stepErr = s.stepErrorNext ? "Open in app failed" : nil
        s.stepErrorNext = false
        Task { @MainActor in
            if wf.hasPrefix("GIF") { await phase(t, "Converting", "GIF", ring: true, ms: 3000) }
            if wf == "Pin" { t.title = "Pinned" }
            else if !wf.contains("w.mia.cx") { t.title = "Saved" }
            if wf.contains("w.mia.cx") {
                if s.uploadMode == 2 { t.title = "You're offline"; t.sub = "Couldn't upload"; t.showRetry = true; finish(t, stepErr); return }
                t.title = "Uploading"; t.sub = "w.mia.cx"; t.showBar = true; t.showCancel = true
                await animateProgress(t, ms: 4000)
                t.showBar = false; t.showCancel = false
                if s.uploadMode == 1 { t.title = "Couldn't upload"; t.sub = "Server returned 500"; t.showRetry = true }
                else { let link = "w.mia.cx/aB3xK9.png"; clipboard(link); t.title = "Link copied"; t.sub = link }
            }
            finish(t, stepErr)
        }
    }
    func finish(_ t: ToastItem, _ err: String?) {
        t.err = err; t.showRing = false; startTimer(t)
    }
    func phase(_ t: ToastItem, _ title: String, _ sub: String, ring: Bool, ms: Int) async {
        t.title = title; t.sub = sub; t.showRing = ring
        await animateProgress(t, ms: ms)
        t.showRing = false
    }
    func animateProgress(_ t: ToastItem, ms: Int) async {
        let steps = 40
        for i in 0...steps {
            t.progress = Double(i) / Double(steps)
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000 / UInt64(steps))
            guard items.contains(where: { $0 === t }) else { return }
        }
    }
    func startTimer(_ t: ToastItem) {
        t.timer?.invalidate(); t.t0 = Date()
        t.timer = Timer.scheduledTimer(withTimeInterval: t.remaining, repeats: false) { _ in
            Task { @MainActor in self.dismiss(t) }
        }
    }
    func pauseTimer(_ t: ToastItem) {
        t.timer?.invalidate(); t.timer = nil
        t.remaining -= Date().timeIntervalSince(t.t0)
    }
    func dismiss(_ t: ToastItem) { items.removeAll { $0 === t }; relayout(); AppDelegate.shared?.updateEscHotkey() }
    // a toast that stays up until the caller ends it with finish/startTimer
    func pending(_ text: String) -> ToastItem {
        let t = ToastItem(cap: Capture(thumb: nil, label: text, url: nil, duration: nil))
        t.title = text
        items.insert(t, at: 0); relayout(); AppDelegate.shared?.updateEscHotkey()
        return t
    }
    func flash(_ text: String, swatch: String?) {
        let t = pending(text)
        if let sw = swatch { t.sub = sw }
        startTimer(t)
    }
}

struct ToastStackView: View {
    @EnvironmentObject var ctrl: ToastController
    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(ctrl.items.prefix(3))) { t in ToastView(item: t) }
            if ctrl.items.count > 3 { Text("+\(ctrl.items.count - 3)").font(.caption2).padding(4).background(.regularMaterial).clipShape(.capsule) }
            Spacer()
        }.padding(24)
    }
}
struct ToastView: View {
    @ObservedObject var item: ToastItem
    @EnvironmentObject var ctrl: ToastController
    @State var offset: CGFloat = 0
    var body: some View {
        VStack(spacing: 4) {
            card
            detail
        }
        .offset(x: offset)
        .gesture(DragGesture().onChanged { offset = max(0, $0.translation.width) }
            .onEnded { if $0.translation.width > 80 { ctrl.dismiss(item) } else { offset = 0 } })
        .onTapGesture { open() }
        .onHover { h in h ? ctrl.pauseTimer(item) : ctrl.startTimer(item) }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .animation(.smooth(duration: 0.35), value: offset)
    }
    var card: some View {
        ZStack(alignment: .bottom) {
            if let cg = item.cap.thumb {
                Image(cg, scale: 1, label: Text(""))
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.9), lineWidth: 2))
                    .shadow(radius: 10, y: 4)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder").font(.system(size: 11))
                    Text(item.title).font(.system(size: 11)).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.85), in: .capsule)
                .overlay(Capsule().stroke(.white.opacity(0.9), lineWidth: 2))
                .shadow(radius: 10, y: 4)
            }
            if let d = item.cap.duration {
                Text(fmtT(d)).font(.system(size: 9)).foregroundStyle(.white)
                    .padding(3).background(.black.opacity(0.7), in: .rect(cornerRadius: 4))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            VStack(spacing: 3) {
                if item.cap.thumb != nil { chip }
                if let e = item.err {
                    Text(e).font(.system(size: 9)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.red.opacity(0.85), in: .capsule)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: 216)
            .padding(.bottom, 7)
        }
        .fixedSize()
    }
    var statusText: String {
        var t = item.title
        if item.showRing || item.showBar { t += " \(Int(item.progress * 100))%" }
        return t
    }
    var chip: some View {
        HStack(spacing: 6) {
            if item.showRing { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
            if item.showBar { ProgressView(value: item.progress).frame(width: 60, height: 3) }
            Text(statusText).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.tail)
            if item.showCancel { Button("✕") { cancel() }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.white) }
            if item.showRetry { Button("Retry") { retry() }.buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.black.opacity(0.8), in: .capsule)
        .frame(maxWidth: 200)
    }
    var detail: some View {
        Group {
            if !item.sub.isEmpty {
                Text(item.sub).font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: 216)
            }
        }
    }
    func open() { if let u = item.cap.url { NSWorkspace.shared.open(u) } }
    func retry() {
        let s = AppState.shared
        item.showRetry = false; item.err = nil
        item.title = "Uploading"; item.sub = "w.mia.cx"; item.showBar = true
        Task { @MainActor in
            await ctrl.animateProgress(item, ms: 4000)
            item.showBar = false
            if s.uploadMode == 0 { let link = "w.mia.cx/aB3xK9.png"; clipboard(link); item.title = "Uploaded"; item.sub = link + " — link copied" }
            else if s.uploadMode == 1 { item.title = "Upload failed"; item.sub = "Couldn't upload — server returned 500"; item.showRetry = true }
            else { item.title = "Offline"; item.sub = "You're offline"; item.showRetry = true }
            ctrl.startTimer(item)
        }
    }
    func cancel() { item.showBar = false; item.showCancel = false; item.title = "Cancelled"; item.sub = "Upload cancelled"; ctrl.startTimer(item) }
}

// MARK: - Countdown HUD + flash

@MainActor
struct CountdownHUD {
    static var panel: NSPanel?
    static func show(_ n: Int) {
        if panel == nil {
            let f = NSScreen.main!.frame
            let p = NSPanel(contentRect: NSRect(x: f.midX - 150, y: f.midY - 100, width: 300, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver + 2; p.isOpaque = false; p.backgroundColor = .clear
            p.collectionBehavior = [.canJoinAllSpaces]; p.ignoresMouseEvents = true
            panel = p
        }
        panel!.contentView = NSHostingView(rootView: Text("\(n)").font(.system(size: 140, weight: .ultraLight)).foregroundStyle(.white).shadow(radius: 20))
        panel!.orderFront(nil)
    }
    static func hide() { panel?.close() }
}

// MARK: - State HUD view

struct StateHUDView: View {
    @ObservedObject var s = AppState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WADJET").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
            Text("phase: \(String(describing: s.phase))  tool: \(s.tool?.title ?? "-")")
            Text("workflow: \(s.workflowFor(s.tool) ?? "-")")
            Text("colour=\(s.colourFmt) measure=\(s.measureMode) countdown=\(s.countdown)")
            Text("audio=\(s.sysAudio ? "on" : "off")/\(s.mic ? "on" : "off") cursor=\(s.cursor ? "on" : "off") island=\(s.showIslandWhileRecording ? "on" : "off")")
            Text("rec: \(s.phase == .recording ? fmtT(s.recordingElapsed) + (s.recordingPaused ? " (paused)" : "") : "-")")
            Text("clip: \(String(s.lastClipboard.prefix(80)))").lineLimit(2)
            Text("freeze latency: \(s.latencyText)").foregroundStyle(.secondary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange, style: StrokeStyle(lineWidth: 1, dash: [4])))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Hotkeys (Carbon)

enum Hotkeys {
    nonisolated(unsafe) static var refs: [EventHotKeyRef?] = []
    @MainActor
    static func register() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let defs: [(UInt32, UInt32, Tool)] = [
            (UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey), .capRegion),
            (UInt32(kVK_ANSI_3), UInt32(cmdKey | shiftKey), .capScreen),
            (UInt32(kVK_ANSI_5), UInt32(cmdKey | shiftKey), .recRegion),
        ]
        for (i, (key, mods, tool)) in defs.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x77646A74), id: UInt32(i + 1)) // 'wdjt'
            let err = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
            AppLog.line("hotkey \(tool.title): \(err == noErr ? "registered" : "FAILED (\(err))")")
        }
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.id >= 1 && id.id <= 3 else { return OSStatus(eventNotHandledErr) }
            let tools = [Tool.capRegion, .capScreen, .recRegion]
            let t = tools[Int(id.id) - 1]
            DispatchQueue.main.async { AppDelegate.shared?.trigger(t) }
            return noErr
        }, 1, &type, nil, nil)
    }
}

// MARK: - Entry point

extension AppDelegate { static var shared: AppDelegate? { NSApp.delegate as? AppDelegate } }

if CommandLine.arguments.contains("--probe-preflight") {
    print("preflight:", CGPreflightScreenCaptureAccess())
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
