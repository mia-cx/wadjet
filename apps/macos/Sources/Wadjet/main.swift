// Wadjet — a ShareX-style screenshot and screen-recording utility for macOS.

import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon
import Vision
import UniformTypeIdentifiers
import ObjectiveC
import AVFoundation
import CoreMedia
import KeyboardShortcuts
import WadjetKit

// MARK: - Model

enum Tool: String, CaseIterable {
    // raw values match WadjetKit's ToolID, so config shortcuts map straight through
    case capRegion = "captureRegion", capWindow = "captureWindow", capScreen = "captureScreen"
    case recRegion = "recordRegion", recWindow = "recordWindow", recScreen = "recordScreen"
    case pickColour = "pickColour", copyText = "copyText", measure = "measure"
    case select = "select", draw = "draw", shapes = "shapes", counter = "counter", censor = "censor", clearAnnotations = "clearAnnotations", moreMarkup = "moreMarkup"
    var title: String {
        switch self {
        case .capRegion: "Capture Region"; case .capWindow: "Capture Window"; case .capScreen: "Capture Screen"
        case .recRegion: "Record Region"; case .recWindow: "Record Window"; case .recScreen: "Record Screen"
        case .pickColour: "Pick Colour"; case .copyText: "Copy Text"; case .measure: "Measure"
        case .select: "Select"; case .draw: "Draw"; case .shapes: "Shapes"; case .counter: "Step Counter"; case .censor: "Censor"; case .clearAnnotations: "Clear Annotations"
        case .moreMarkup: "More Markup Tools"
        }
    }
    // the permanent label under the cell icon — as short as it can be
    var shortTitle: String {
        switch self {
        case .capRegion, .recRegion: "Region"; case .capWindow, .recWindow: "Window"; case .capScreen, .recScreen: "Screen"
        case .pickColour: "Colour"; case .copyText: "Text"; case .measure: "Measure"
        case .select: "Select"; case .draw: "Draw"; case .shapes: "Shapes"; case .counter: "Counter"; case .censor: "Censor"; case .clearAnnotations: "Clear"
        case .moreMarkup: "More"
        }
    }
    var kind: Kind { switch self {
        case .capRegion, .capWindow, .capScreen: .shot
        case .recRegion, .recWindow, .recScreen: .rec
        case .pickColour, .copyText, .measure: .util
        // Markup Tools, More and Clear — new Markup Tools need no entry here
        default: .markup
    } }
    /// Tools that can skip the pick: one obvious target (the pointer's display
    /// or the focused window) — a Shortcut can capture them without confirming
    var confirmOptional: Bool { [.capWindow, .capScreen, .recWindow, .recScreen].contains(self) }
    var symbol: String {
        switch self {
        case .capRegion: "viewfinder"; case .capWindow: "macwindow"; case .capScreen: "display"
        case .recRegion: "viewfinder.circle"; case .recWindow: "macwindow.badge.plus"; case .recScreen: "record.circle"
        case .pickColour: "eyedropper"; case .copyText: "text.viewfinder"; case .measure: "ruler"
        case .select: "cursorarrow"; case .draw: "line.diagonal"; case .shapes: "square.on.circle"; case .counter: "1.circle"; case .censor: "eye.slash"; case .clearAnnotations: "trash"
        case .moreMarkup: "ellipsis"
        }
    }
    enum Kind: CaseIterable { case shot, rec, util, markup
        var badge: String {
            switch self { case .shot: "camera.fill"; case .rec: "video.fill"; case .util: "wrench.and.screwdriver.fill"; case .markup: "pencil.and.scribble" }
        }
        var groupTitle: String {
            switch self { case .shot: "Still"; case .rec: "Video"; case .util: "Utilities"; case .markup: "Markup" }
        }
    }
    /// nil for Tools no Shortcut can name (Select, Clear, More)
    var toolID: ToolID? { ToolID(rawValue: rawValue) }
    var hasMenu: Bool { ![.copyText, .clearAnnotations].contains(self) }
    /// a toolbar button that acts at once instead of arming: Clear clears, More opens its menu
    var isAction: Bool { self == .clearAnnotations || self == .moreMarkup }
    init?(named s: String) { self = Tool.allCases.first { $0.title.lowercased().contains(s.lowercased()) } ?? Tool(rawValue: s)! }
}

// the overlay's phase only — a Recording lives in recActive. .toolbar = only
// the toolbar is up, over the live screen, no overlay panels (Escape with a
// Markup Tool armed drops the Freeze Frame but keeps the toolbar)
enum Phase { case desktop, frozen, toolbar, countdown }

extension Color {
    // Wadjet means "the green one": a malachite green, used instead of the system accent
    static let wadjetAccent = Color(red: 0.20, green: 0.84, blue: 0.58)
}

// nothing — lensZoom removed: the shader lens replaces magnification
let dimAlpha: CGFloat = 0.4  // Freeze Frame dim outside the capture target
let fallbackWindowRadius: CGFloat = 16 // a title-bar-only window's corner; used until the window's own corner is measured

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var phase: Phase = .desktop { didSet { MarkupController.shared.syncArmed(); MarkupStyles.shared.syncEyedropper() } }
    /// the toolbar is up, over an overlay or alone
    var toolbarOpen: Bool { phase == .frozen || phase == .toolbar }
    @Published var recActive = false // a Recording is running (independent of the overlay)
    // Screenshot options, toggled live on an open Freeze Frame — session state
    // like the recording toggles, not persisted. Each fresh capture starts
    // from Settings' cursor default, so these are per-capture overrides.
    @Published var shotCursor = true { didSet { AppDelegate.shared?.overlayCtrl.swapFrozenImages() } }
    @Published var shotWadjet = true { didSet { AppDelegate.shared?.overlayCtrl.swapFrozenImages() } }
    func applyCaptureDefaults() {
        shotCursor = config.value.capture.cursor
        cursor = config.value.capture.cursor
    }
    @Published var bubblesDying = false // set while a recording bubble merges back into the island
    @Published var tool: Tool? = nil { didSet { MarkupController.shared.syncArmed(); MarkupStyles.shared.syncEyedropper() } }
    @Published var workflowByTool: [Tool: String] = [:]
    /// a Shortcut's one-shot Workflow pick; cleared when the capture runs or is cancelled
    @Published var triggerWorkflow: String? = nil
    let config = ConfigStore(file: AppLog.url.deletingLastPathComponent().appendingPathComponent("config.json"), defaults: WadjetConfig(), keychain: SystemKeychain(service: "cx.mia.wadjet"), onError: reportConfigError)
    // both live in config.json; SwiftUI views track them through the store's Observation
    var colourFmt: String { // Hex, rgb(), hsl(), oklch(), lab(), SwiftUI
        get { config.value.tools.pickColour.format.rawValue }
        set { if let f = ColourFormat(rawValue: newValue) { config.update { $0.tools.pickColour.format = f } } }
    }
    var measureMode: String { // Bounds, Spacing, Horizontal, Vertical
        get { config.value.tools.measure.mode.rawValue }
        set { if let m = MeasureMode(rawValue: newValue) { config.update { $0.tools.measure.mode = m } } }
    }
    var confirmMode: String { // release, manual
        get { config.value.tools.region.confirm.rawValue }
        set { if let c = WadjetConfig.RegionConfirm(rawValue: newValue) { config.update { $0.tools.region.confirm = c } } }
    }
    @Published var countdown = "Off" // Off 3 5 10
    @Published var sysAudio = false
    @Published var mic = false
    @Published var cursor = true
    @Published var clickCircles = false
    @Published var showIslandWhileRecording = true
    // a toolbar opening re-ranks the Markup group (nil → a display)
    @Published var expandedDisplay: Int? = nil { didSet { if oldValue == nil, expandedDisplay != nil { MarkupToolbar.shared.open() } } }
    @Published var debugGroup: Tool.Kind? = nil // cmd.sh group <shot|rec|util|markup> — drives the expanded toolbar's openGroup
    @Published var debugTap: Tool? = nil // cmd.sh tap <toolRaw> — runs the tap-release lens travel
    @Published var debugHold: Tool? = nil // cmd.sh hold <toolRaw>|off — pins the pressed lens on that cell
    @Published var openMenu: Tool? = nil // which Tool's dropdown is open, if any
    /// the open menu body's height while it scrolls: set when its content
    /// outgrows the space below its top edge
    @Published var menuScrollHeight: CGFloat? = nil
    @Published var recordingElapsed: TimeInterval = 0
    @Published var recordingPaused = false
    @Published var lastClipboard = ""
    @Published var latencyText = "none"
    @Published var islandMode = false        // island even with a notch
    @Published var uploadMode = 0            // 0 succeed, 1 fail, 2 offline
    @Published var showStateHUD = false
    // the Workflow names a Tool can run: Screenshots for Capture, MP4/GIF for Record
    func workflows(for t: Tool?) -> [String] {
        let kinds: [CaptureKind] = switch t?.kind {
        case .shot: [.screenshot]
        case .rec: [.mp4, .gif]
        default: []
        }
        return config.value.workflows.filter { kinds.contains($0.takes) }.map(\.name)
    }
    // the Workflow a capture runs with: a triggering Shortcut's pick for this one
    // capture > the Tool menu's choice > the kind's configured default > first
    // compatible (Screenshot for Capture, MP4 for Record)
    func workflowFor(_ t: Tool?) -> String? {
        let list = workflows(for: t)
        if let tw = triggerWorkflow, list.contains(tw) { return tw }
        if let chosen = workflowByTool[t ?? .capRegion], list.contains(chosen) { return chosen }
        let dflt = t?.kind == .shot ? config.value.defaultWorkflows.screenshot
            : t?.kind == .rec ? config.value.defaultWorkflows.recording : nil
        if let dflt, list.contains(dflt) { return dflt }
        return list.first
    }
}

// MARK: - Frozen frame store

struct FrozenDisplay {
    let screen: NSScreen
    let image: CGImage          // SDR image, pixel resolution — what the panel shows (cursor included)
    /// cursor-free SDR frame; every pixel read — Pick Colour, the loupe, Measure — uses it so the frozen cursor never shows up in a reading
    let clean: CGImage
    var hdrImage: CGImage?      // extended-sRGB variant when the display is HDR
    var cleanHDR: CGImage?      // cursor-free HDR pair, for cursor-off Screenshots
    /// the whole-display variants with EVERY Wadjet window excluded — captured
    /// at freeze time only when we had more than the always-excluded compact
    /// chrome on this display; nil means "share the regular images"
    var bare: CGImage?, bareHDR: CGImage?, bareClean: CGImage?, bareCleanHDR: CGImage?
    var bareCaptured = false
    /// the image the overlay shows and a Screenshot saves, picked by the
    /// Cursor/Wadjet toggles — for a Utility it's always the regular scene,
    /// whose pixels `clean` reads (a Wadjet-off image would show different
    /// pixels than the loupe/Pick Colour report)
    @MainActor var outputHDR: CGImage? {
        let s = AppState.shared
        if s.tool?.kind == .util { return hdrImage }
        return s.shotWadjet
            ? (s.shotCursor ? hdrImage : cleanHDR)
            : (s.shotCursor ? bareHDR ?? hdrImage : bareCleanHDR ?? cleanHDR)
    }
    @MainActor func output(hdr: Bool) -> CGImage {
        let s = AppState.shared
        if s.tool?.kind == .util { return (hdr ? hdrImage : nil) ?? image }
        let sdr = s.shotWadjet
            ? (s.shotCursor ? image : clean)
            : (s.shotCursor ? bare ?? image : bareClean ?? clean)
        return (hdr ? outputHDR : nil) ?? sdr
    }
    var bitmap: UnsafePointer<UInt8>? // sRGB, premultiplied ARGB, pixel coords
    var bitmapWidth = 0, bitmapHeight = 0
    var pixels: PixelBuffer? { bitmap.map { PixelBuffer(base: $0, width: bitmapWidth, height: bitmapHeight) } }
    var windowFrames: [WinEntry] = [] // front-to-back, view coords
}

struct WinEntry {
    let id: CGWindowID
    let frame: CGRect
}
/// the pointer in global screen coords while an overlay is up — glass
/// shaders read it as their light position. Only views that apply the
/// effects observe it; nothing heavy re-renders on mouse move.
@MainActor
final class PointerLight: ObservableObject {
    static let shared = PointerLight()
    @Published var screen: CGPoint?
    var debugHoldUntil = Date.distantPast
    func feed(_ p: CGPoint) {
        if Date() < debugHoldUntil { return }
        screen = p
    }
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
        return Freeze.pixelCrop(of: f.output(hdr: hdr), rect: rect, in: f.screen)
    }
    /// view-rect (bottom-left) -> pixel crop of a full-display image
    static func pixelCrop(of src: CGImage, rect: CGRect, in screen: NSScreen) -> CGImage? {
        let sx = CGFloat(src.width) / screen.frame.width
        let sy = CGFloat(src.height) / screen.frame.height
        let r = CGRect(x: rect.origin.x * sx, y: (screen.frame.height - rect.origin.y - rect.height) * sy,
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
    /// does this filter's face fill still read as untinted clear glass?
    static func isIdentityFill(_ v: Any?) -> Bool {
        guard let v else { return true } // unset on the first frame: let it pass
        let cg = v as! CGColor
        guard let c = cg.components, c.count >= 4 else { return true }
        return c[0] == 1 && c[1] == 1 && c[2] == 1 && c[3] == 0
    }
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
                      (f.value(forKey: "inputBlurFillDarkenOpacity") as? NSNumber)?.doubleValue == 0,
                      // ONLY the plain .clear lens: a .clear.tint(…) bar keeps
                      // its (subtle) blur — its face fill isn't identity's
                      ClearGlassPatch.isIdentityFill(f.value(forKey: "inputFaceColorMatrixFillColor"))
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

@MainActor
func reportConfigError(_ e: ConfigError) {
    AppLog.line("config: \(e)")
    Task { @MainActor in
        // the first load runs when AppState.shared is first touched, before the
        // toast controller exists — defer until ToastController.shared is set
        guard let tc = ToastController.shared else { return }
        let t = tc.pending("Couldn't read config.json")
        t.sub = e.location.map { "\($0): \(e.message)" } ?? e.message
        tc.startTimer(t)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    var recordingWindowID: CGWindowID?
    var recordingPanel: NSPanel?
    var recStream: SCStream?
    var recWriter: MP4Writer?
    var recOutput: RecOutput?
    /// Bumped per Recording attempt, so a cancelled attempt's late setup can't
    /// publish into a newer one that has also reached `.countdown`.
    var recAttempt = 0
    let recDelegate = RecDelegate()
    /// The stream's frame queue — SCStream calls back here, the actor serializes writes.
    let recQueue = DispatchQueue(label: "wadjet.recstream")

    func applicationDidFinishLaunching(_ n: Notification) {
        #if CLEAR_GLASS_PATCH
        ClearGlassPatch.install()
        #endif
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = buildMainMenu() // accessory ignores it; it shows while .regular
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "wadjet")
        rebuildMenu()
        overlayCtrl = OverlayController(app: self)
        toastCtrl = ToastController()
        // a display plugged in while the island or live toolbar is up gets one too
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.shared?.overlayCtrl.screensChanged() }
        }
        Task { @MainActor in // live reload shows up in app.log
            var lastMode = AppState.shared.config.value.tools.measure.mode
            var lastShortcuts = AppState.shared.config.value.shortcuts
            for await c in Observations({ AppState.shared.config.value }) {
                AppLog.line("config: colourFormat=\(c.tools.pickColour.format.rawValue) measureMode=\(c.tools.measure.mode.rawValue)")
                // a config.json edit of the Measure mode rescans without a mouse move
                if c.tools.measure.mode != lastMode {
                    lastMode = c.tools.measure.mode
                    for p in overlayCtrl.panels { p.contentView?.subviews.compactMap { $0 as? OverlayNSView }.forEach { $0.rescanRuler() } }
                }
                if c.shortcuts != lastShortcuts {
                    lastShortcuts = c.shortcuts
                    registerShortcuts()
                    rebuildMenu()
                }
                resolveBookmarks()
                // the Peer Through toggle, from the menu or a config.json edit
                PeerThrough.shared.sync()
            }
        }
        registerShortcuts()
        resolveBookmarks()
        AppLog.line("launch; preflight screen capture = \(CGPreflightScreenCaptureAccess()); statusItem frame = \(statusItem.button?.window?.frame.debugDescription ?? "?")")
        buildStateHUD()
        _ = try? FileManager.default.createDirectory(at: Self.capturesDir, withIntermediateDirectories: true)
        do {
            history = try HistoryStore(url: Self.historyURL)
        } catch {
            AppLog.line("history: store failed to open, running without it: \(error.localizedDescription)")
        }
        sweepCaptures()
        // Entries stay; only the temp files age out. Re-sweep daily while running.
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in self.sweepCaptures() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in self.recTick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppLog.line("statusItem frame = \(self.statusItem.button?.window?.frame.debugDescription ?? "?")")
        }
        // deliverImmediately: AppKit suspends distributed notifications while the
        // app is inactive, and Wadjet goes inactive again after every overlay
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(distCmd(_:)), name: .init("cx.mia.wadjet.cmd"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }
    @objc func distCmd(_ n: Notification) {
        if let cmd = n.object as? String { Task { @MainActor in handleCmd(cmd) } }
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
            case "shotcursor": s.shotCursor = val == "on"
            case "shotwadjet": s.shotWadjet = val == "on"
            case "clicks": s.clickCircles = val == "on"
            case "island": s.showIslandWhileRecording = val == "on"
            case "colourFormat": s.colourFmt = val
            case "measureMode": s.measureMode = val
            case "confirm": s.confirmMode = val
            default: AppLog.line("cmd option: unknown key \(key)")
            }
        case "expand": s.expandedDisplay = overlayCtrl.mouseDisplay()
        case "group" where parts.count > 1: // debug: animated group switch on the expanded toolbar
            s.debugGroup = ["shot": .shot, "rec": .rec, "util": .util, "markup": .markup][String(parts[1])]
        case "tap" where parts.count > 1: // debug: a tap's Tool switch with lens travel
            s.debugTap = Tool(rawValue: String(parts[1]))
        case "hold" where parts.count > 1: // debug: keep the pressed lens up for inspection
            s.debugHold = Tool(rawValue: String(parts[1])) // "off" -> nil
        case "record" where parts.count > 1 && parts[1] == "screen": // debug: a Record Screen pick on the pointer's display
            if s.phase == .desktop && !s.recActive {
                let di = overlayCtrl.mouseDisplay()
                trigger(.recScreen) // the normal Freeze path; the start follows
                Task { @MainActor in
                    for _ in 0..<60 {
                        if s.phase == .frozen { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    guard s.phase == .frozen, Freeze.shared.displays.count > di else { return }
                    startRecording(rect: CGRect(origin: .zero, size: Freeze.shared.displays[di].screen.frame.size), display: di)
                }
            }
        case "collapse": s.expandedDisplay = nil
        case "upload" where parts.count > 1:
            s.uploadMode = ["succeed": 0, "fail": 1, "offline": 2][parts[1]] ?? s.uploadMode
            rebuildMenu()
        case "light" where parts.count > 2: // debug: pin the glass light for 5 s
            if let x = Double(parts[1]), let y = Double(parts[2]) {
                PointerLight.shared.screen = CGPoint(x: x, y: y)
                PointerLight.shared.debugHoldUntil = Date().addingTimeInterval(5)
            }
        case "now" where parts.count > 1: // debug: a confirm-off Shortcut press
            if let t = Tool(rawValue: parts[1]) { trigger(t, immediate: true) }
        case "capture": // debug: a full-display shot on the pointer's display
            if s.phase == .frozen, s.tool?.kind == .shot {
                AppLog.line("capture: pointer at \(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y))")
                let di = overlayCtrl.mouseDisplay()
                didSelect(CGRect(origin: .zero, size: Freeze.shared.displays[di].screen.frame.size), on: di)
            }
        case "stop": if s.recActive { stopRecording() }
        case "pause": if s.recActive { togglePause() }
        case "settings": openSettings()
        case "closesettings": settingsWindow?.close()
        case "esc": handleEsc()
        default: AppLog.line("cmd: unhandled \(cmd)")
        }
    }

    static var capturesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wadjet/Captures")
    }
    static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wadjet/History.store")
    }

    /// Every Capture's permanent record; nil if the store couldn't open —
    /// the app still works, entries just aren't kept.
    var history: HistoryStore?

    /// Deletes temp Captures older than the config's retention. Never touches
    /// history entries — that's what lets the Recent menu outlive the files.
    func sweepCaptures() {
        let retention = TimeInterval(AppState.shared.config.value.retentionDays) * 86_400
        do { try CaptureFiles(directory: Self.capturesDir, retention: retention).sweep() }
        catch { AppLog.line("capture sweep failed: \(error.localizedDescription)") }
    }

    // MARK: status menu
    func rebuildMenu() {
        let m = NSMenu()
        let s = AppState.shared
        let tools: [Tool] = [.capRegion, .capWindow, .capScreen, .recRegion, .recWindow, .recScreen, .pickColour, .copyText, .measure]
        for (i, t) in tools.enumerated() {
            let it = NSMenuItem(title: t.title, action: #selector(toolItem(_:)), keyEquivalent: "")
            it.representedObject = t.rawValue; it.target = self
            if let si = s.config.value.shortcuts.firstIndex(where: { $0.tool.rawValue == t.rawValue }) {
                it.setShortcut(for: KeyboardShortcuts.Name("shortcut.\(si)"))
            }
            m.addItem(it)
            if i == 2 || i == 5 { m.addItem(.separator()) }
        }
        m.addItem(.separator())
        // arms the last Markup Tool — a Shortcut naming it shows here too
        let markup = NSMenuItem(title: "Markup", action: #selector(armLastMarkupTool), keyEquivalent: "")
        markup.target = self
        if let si = s.config.value.shortcuts.firstIndex(where: { $0.tool.rawValue == Tool.lastMarkup.rawValue }) {
            markup.setShortcut(for: KeyboardShortcuts.Name("shortcut.\(si)"))
        }
        m.addItem(markup)
        m.addItem(.separator())
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let rsub = NSMenu()
        rsub.autoenablesItems = false // a swept entry must stay disabled, not auto-enabled
        rsub.delegate = self // filled lazily in menuNeedsUpdate
        recent.submenu = rsub; m.addItem(recent)
        m.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        m.addItem(settings)
        let proto = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        psub.addItem(mi("Island Mode Even With Notch", #selector(toggleIsland), on: AppState.shared.islandMode))
        psub.addItem(.separator())
        psub.addItem(mi("Next Upload: Succeed", #selector(upl0), on: AppState.shared.uploadMode == 0))
        psub.addItem(mi("Next Upload: Fail", #selector(upl1), on: AppState.shared.uploadMode == 1))
        psub.addItem(mi("Next Upload: Offline", #selector(upl2), on: AppState.shared.uploadMode == 2))
        psub.addItem(.separator())
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
    @objc func toggleHUD(_ s: NSMenuItem) { AppState.shared.showStateHUD.toggle(); s.state = AppState.shared.showStateHUD ? .on : .off
        hudPanel.setIsVisible(AppState.shared.showStateHUD) }
    @objc func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    /// the Dock/⌘-Tab-visible app's minimal menu, shown only while .regular
    /// — standard Edit selectors with nil targets reach the first responder
    /// (⌘C/⌘V work in Settings' text fields)
    func buildMainMenu() -> NSMenu {
        func mi(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        let main = NSMenu()
        let app = NSMenuItem(); app.submenu = NSMenu()
        app.submenu!.addItem(mi("Settings…", #selector(openSettings), ","))
        app.submenu!.addItem(.separator())
        app.submenu!.addItem(mi("Hide Wadjet", #selector(NSApplication.hide(_:)), "h"))
        app.submenu!.addItem(mi("Quit Wadjet", #selector(NSApplication.terminate(_:)), "q"))
        let editM = NSMenuItem(); editM.submenu = NSMenu(title: "Edit")
        editM.submenu!.addItem(mi("Undo", Selector(("undo:")), "z"))
        editM.submenu!.addItem(mi("Redo", Selector(("redo:")), "Z"))
        editM.submenu!.addItem(.separator())
        editM.submenu!.addItem(mi("Cut", #selector(NSText.cut(_:)), "x"))
        editM.submenu!.addItem(mi("Copy", #selector(NSText.copy(_:)), "c"))
        editM.submenu!.addItem(mi("Paste", #selector(NSText.paste(_:)), "v"))
        editM.submenu!.addItem(mi("Select All", #selector(NSText.selectAll(_:)), "a"))
        let win = NSMenuItem(); win.submenu = NSMenu(title: "Window")
        win.submenu!.addItem(mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.submenu!.addItem(mi("Close", #selector(NSWindow.performClose(_:)), "w"))
        main.items = [app, editM, win]
        installEditorMenus(into: main)
        return main
    }
    /// a Dock-icon click (or ⌘-Tab back) reopens Settings — unless Editor
    /// documents are open, which the system brings forward itself
    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows f: Bool) -> Bool {
        if !NSDocumentController.shared.documents.isEmpty { return true }
        openSettings()
        return true
    }
    /// never offer an untitled Canvas — Editors open only from packages
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    var settingsWindow: NSWindow?
    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Wadjet Settings"
            w.isReleasedWhenClosed = false
            // back to menu-bar-only when Settings closes
            NotificationCenter.default.addObserver(self, selector: #selector(settingsClosed(_:)),
                name: NSWindow.willCloseNotification, object: w)
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        AppLog.line("settings: window opened (regular)")
    }
    @objc func settingsClosed(_ n: Notification) {
        syncActivationPolicy(closing: n.object as? NSWindow)
        AppLog.line("settings: closed")
    }

    // MARK: folder bookmarks

    /// Security-scoped folder grants kept open for the app's life, by the
    /// config path they came from. Re-resolved on every config change.
    var grantedFolders: [String: URL] = [:]
    func resolveBookmarks() {
        let marks = AppState.shared.config.value.bookmarks
        for (path, url) in grantedFolders where marks[path] == nil {
            url.stopAccessingSecurityScopedResource()
            grantedFolders.removeValue(forKey: path)
        }
        for (path, data) in marks where grantedFolders[path] == nil {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     bookmarkDataIsStale: &stale) else {
                AppLog.line("bookmark \(path): resolve failed")
                continue
            }
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                AppState.shared.config.update { $0.bookmarks[path] = fresh } // will re-enter here next loop
            }
            if url.startAccessingSecurityScopedResource() {
                grantedFolders[path] = url
                AppLog.line("bookmark \(path): granted")
                // a moved folder resolves at its new location; the grant holds,
                // but the config path still points at the dead one — saves
                // there fail with their own toast error until re-picked
                if url.path != expandingTilde(path).path {
                    AppLog.line("bookmark \(path): folder moved to \(url.path); choose it again in Settings")
                }
            } else {
                AppLog.line("bookmark \(path): access denied")
            }
        }
    }

    // MARK: Recent submenu

    /// Rebuilds the Recent items each time the submenu opens — always fresh,
    /// no menu rebuild needed after each capture.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries: [HistoryEntry]
        do {
            entries = try history?.recent(limit: 10) ?? []
        } catch {
            AppLog.line("history: recent failed: \(error.localizedDescription)")
            entries = []
        }
        guard !entries.isEmpty else {
            menu.addItem(NSMenuItem(title: "No Captures Yet", action: nil, keyEquivalent: ""))
            return
        }
        let cal = Calendar.current
        for e in entries {
            let when = cal.isDateInToday(e.createdAt)
                ? e.createdAt.formatted(.dateTime.hour().minute())
                : e.createdAt.formatted(.dateTime.day().month().hour().minute())
            let it = NSMenuItem(title: "\(e.kind.title) · \(when)", action: #selector(recentItem(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.id.uuidString
            // ImageIO thumbnail at ~64px (32pt @2x); decoding the full
            // HEIC/PNG for every menu item on every open is far too heavy.
            // ImageIO thumbnail at ~64px (32pt @2x); MP4s go through
            // AVAssetImageGenerator instead — ImageIO can't read video. Async:
            // the item lands first and the image fills in when it's ready.
            if let file = e.existingFile {
                let item = it
                Task { @MainActor in
                    guard let cg = await captureThumbnail(file) else { return }
                    let scale = 32 / CGFloat(max(cg.width, cg.height, 1))
                    item.image = NSImage(cgImage: cg,
                                         size: NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale))
                }
            }
            it.isEnabled = e.existingFile != nil || e.link != nil
                || ((try? canvasStore.url(for: e.id)) ?? nil) != nil
            menu.addItem(it)
        }
    }
    @objc func recentItem(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String,
              let e = try? history?.recent(limit: 10).first(where: { $0.id.uuidString == raw }) else { return }
        if let canvas = try? canvasStore.url(for: e.id) {
            openCanvas(canvas)
        } else if let file = e.existingFile {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if let link = e.link {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
    }

    // MARK: Shortcuts

    /// KeyboardShortcuts names live across config loads; a removed Shortcut's
    /// name is reset so it stops firing.
    var shortcutNames: [KeyboardShortcuts.Name] = []

    func registerShortcuts() {
        let s = AppState.shared
        for n in shortcutNames {
            KeyboardShortcuts.reset(n)
            KeyboardShortcuts.removeHandler(for: n) // reset leaves the handler; drop it too
        }
        shortcutNames = []
        let apple = systemHotkeys()
        for (i, sc) in s.config.value.shortcuts.enumerated() {
            guard let tool = Tool(rawValue: sc.tool.rawValue) else { continue }
            let name = KeyboardShortcuts.Name("shortcut.\(i)")
            shortcutNames.append(name)
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(carbonKeyCode: sc.keys.keyCode, carbonModifiers: sc.keys.carbonModifiers),
                for: name)
            AppLog.line("shortcut \(sc.keys) -> \(tool.title) registered")
            KeyboardShortcuts.onKeyDown(for: name) {
                Task { @MainActor in AppDelegate.shared?.fireShortcut(sc, tool: tool) }
            }
            if apple.contains(where: { $0.keyCode == sc.keys.keyCode && $0.mods == sc.keys.carbonModifiers }) {
                AppLog.line("shortcut \(sc.keys) for \(tool.title) clashes with a macOS keyboard shortcut")
                let t = toastCtrl.pending("Shortcut taken by macOS")
                t.sub = "\(sc.keys) for \(tool.title) is a macOS keyboard shortcut. Turn it off in System Settings › Keyboard › Keyboard Shortcuts."
                toastCtrl.startTimer(t)
            }
        }
    }

    // enabled macOS combos from the symbolic hotkey table — the array is not
    // indexed by symbolic ID, so every enabled entry is compared. Both sides
    // are masked to cmd|shift|opt|ctrl; system entries carry extra bits.
    func systemHotkeys() -> [(keyCode: Int, mods: Int)] {
        var arr: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&arr) == noErr,
              let list = arr?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let mask = 0x100 | 0x200 | 0x800 | 0x1000 // cmdKey|shiftKey|optionKey|controlKey
        return list.compactMap { e in
            guard (e["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let kc = e["kHISymbolicHotKeyCode"] as? Int,
                  let mods = e["kHISymbolicHotKeyModifiers"] as? Int else { return nil }
            return (kc, mods & mask)
        }
    }

    // a Shortcut press: apply its options, hold its Workflow for this capture,
    // trigger. Only an accepted press touches state — during a countdown a press
    // is ignored, and a Record shortcut during a recording just stops it.
    func fireShortcut(_ sc: Shortcut, tool: Tool) {
        let s = AppState.shared
        if s.phase == .countdown { return }
        // a Record Shortcut always stops the Recording, Freeze Frame or not —
        // and must not touch the Recording's options or its stored Workflow
        if s.recActive && tool.kind == .rec { stopRecording(); return }
        // a fresh capture starts from Settings' defaults; the Shortcut's own
        // options and any menu toggles then override on top. Toolbar triggers
        // do the same in trigger() — never mid-capture (the Recording reads
        // cursor after the overlay closes).
        if s.phase == .desktop || s.phase == .toolbar { s.applyCaptureDefaults() }
        if let c = sc.options.countdown { s.countdown = c == 0 ? "Off" : String(c) }
        if let v = sc.options.systemAudio { s.sysAudio = v }
        if let v = sc.options.microphone { s.mic = v }
        if let v = sc.options.cursor { if tool.kind == .shot { s.shotCursor = v } else { s.cursor = v } }
        if let v = sc.options.clickCircles { s.clickCircles = v }
        s.triggerWorkflow = sc.workflow
        trigger(tool, at: ContinuousClock.now, applyDefaults: false,
                immediate: sc.options.confirm == false && tool.confirmOptional) // Shortcut press -> Freeze Frame latency starts here
    }

    // MARK: trigger
    func trigger(_ tool: Tool, at start: ContinuousClock.Instant = .now, applyDefaults: Bool = true, immediate: Bool = false) {
        let s = AppState.shared
        if tool.isAction { if tool == .clearAnnotations { clearAnnotations() }; return }
        if !tool.opensFreezeFrame, s.phase == .desktop || s.phase == .frozen { overlayCtrl.showLiveToolbar(armed: tool); return }
        // switching Tools while frozen keeps the same Freeze Frame — Record
        // Tools are disabled while a Recording runs
        if s.phase == .frozen || (s.phase == .toolbar && tool.kind == .markup) {
            if s.tool != tool {
                guard tool.kind != .rec || !s.recActive else { AppLog.line("tool switch ignored: recording"); return }
                s.tool = tool; s.openMenu = nil; overlayCtrl.syncMenu(); overlayCtrl.refreshCursors(); overlayCtrl.applyFreezeVisibility(); overlayCtrl.swapFrozenImages(); AppLog.line("tool switched to \(tool.title)")
            }
            return
        }
        // a Record Shortcut while recording stops it
        if s.phase == .desktop && s.recActive && tool.kind == .rec { stopRecording(); return }
        if s.phase != .desktop && s.phase != .toolbar { AppLog.line("trigger ignored: busy (\(s.phase))"); return }
        if !CGPreflightScreenCaptureAccess() { permissionNeeded(); AppLog.line("screen capture preflight denied for \(tool.title)"); return }
        if applyDefaults { s.applyCaptureDefaults() }
        Task { await overlayCtrl.freezeAndShow(tool: tool, start: start, immediate: immediate) }
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
    func captureWindow(id: CGWindowID, screen: NSScreen, cursor: Bool) async -> CGImage? {
        guard let scw = overlayCtrl.scWindows[id] else { return nil }
        let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        let sc = screen.backingScaleFactor
        let cfg = SCScreenshotConfiguration()
        cfg.width = Int((scw.frame.width * sc).rounded())
        cfg.height = Int((scw.frame.height * sc).rounded())
        cfg.showsCursor = cursor
        cfg.ignoreShadows = true // Canvas crop and window pixels share the window frame
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
    /// the frontmost app's first window that's also in the frozen window list —
    /// nil when nothing matches (window numbers are compared as Int;
    /// CGWindowID() traps on bad values). Settings counts — it's a normal window.
    func focusedWindow() -> (id: CGWindowID, frame: CGRect, display: Int)? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in infos {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  let wn = w[kCGWindowNumber as String] as? Int else { continue }
            // every display's windowFrames holds all windows in its own view
            // coords — keep the display whose copy overlaps that screen most
            var best: (id: CGWindowID, frame: CGRect, display: Int, area: CGFloat)?
            for (di, fd) in Freeze.shared.displays.enumerated() {
                guard let e = fd.windowFrames.first(where: { Int($0.id) == wn }) else { continue }
                let inter = e.frame.intersection(CGRect(origin: .zero, size: fd.screen.frame.size))
                let area = inter.isNull ? 0 : inter.width * inter.height
                if area > (best?.area ?? 0) { best = (e.id, e.frame, di, area) }
            }
            if let best {
                AppLog.line("focused window \(wn) on d\(best.display)")
                return (best.id, best.frame, best.display)
            }
        }
        return nil
    }
    /// a confirm-off Shortcut: shoot without the overlay — Screen Tools take
    /// the pointer's display, Window Tools the focused window. Anything
    /// ambiguous falls back to the normal pick. Doesn't activate Wadjet, so
    /// the focused window keeps focus.
    func captureImmediately(_ tool: Tool) {
        AppState.shared.tool = tool // didSelect/didSelectWindow/showsFrozen read it
        switch tool {
        case .capScreen, .recScreen:
            let di = overlayCtrl.mouseDisplay()
            didSelect(CGRect(origin: .zero, size: Freeze.shared.displays[di].screen.frame.size), on: di)
        case .capWindow, .recWindow:
            if let w = focusedWindow() {
                AppLog.line("immediate: window \(w.id) on d\(w.display)")
                didSelectWindow(id: w.id, frame: w.frame, on: w.display)
            } else {
                AppLog.line("immediate: no focused window — falling back to the pick")
                overlayCtrl.showPanels(tool: tool)
            }
        default:
            overlayCtrl.showPanels(tool: tool)
        }
    }
    func didSelectWindow(id: CGWindowID, frame: CGRect, on display: Int) {
        let s = AppState.shared
        guard let tool = s.tool else { return }
        if tool.kind == .shot {
            captureScreenshot(rect: frame, on: display, windowID: id)
        } else {
            recordingWindowID = id
            startRecording(rect: frame, display: display)
        }
    }
    func didSelect(_ rect: CGRect, on display: Int) {
        let s = AppState.shared
        guard let tool = s.tool else { return }
        if tool.kind == .shot {
            captureScreenshot(rect: rect, on: display)
        } else {
            startRecording(rect: rect, display: display)
        }
    }
    // capture temp files land in the Captures dir and age out via the sweep
    lazy var captureFiles = CaptureFiles(directory: Self.capturesDir)
    lazy var canvasStore = CanvasStore(directory: Self.historyURL.deletingLastPathComponent().appendingPathComponent("Canvases"))
    lazy var workflowEffects = AppWorkflowEffects(toast: toastCtrl)
    lazy var runner = WorkflowRunner(effects: workflowEffects)

    /// the Screenshot Workflow for the current Tool, resolved at confirm —
    /// consumes the Shortcut's one-shot pick
    func takeShotWorkflow() -> String {
        let s = AppState.shared
        defer { s.triggerWorkflow = nil }
        return s.workflowFor(s.tool) ?? s.config.value.defaultWorkflows.screenshot
    }
    /// Run a finished capture file through `workflow` (resolved by the caller
    /// at capture time), record it in history, and finish any showToast items.
    func runCapture(file: URL, kind: CaptureKind, label: String, workflow: String,
                    runID: UUID = UUID(), capturedAt: Date = Date(), canvas: URL? = nil) {
        let state = AppState.shared
        let wf = state.config.value.workflows.first { $0.name == workflow && $0.takes == kind }
            ?? WadjetConfig().workflows.first { $0.takes == kind }!
        let defaultFolder = expandingTilde(kind.isRecording
            ? state.config.value.folders.recordings
            : state.config.value.folders.screenshots)
        workflowEffects.canvases[runID] = canvas
        AppLog.line("workflow \(wf.name): \(file.lastPathComponent)")
        Task { @MainActor in
            for await e in runner.run(file, through: wf, defaultFolder: defaultFolder, id: runID, canvas: canvas) {
                switch e {
                case .started(let i, let s): AppLog.line("workflow \(wf.name): started \(i) \(s.title)")
                case .finished(let i, let s): AppLog.line("workflow \(wf.name): finished \(i) \(s.title)")
                case .failed(let i, _, let m): AppLog.line("workflow \(wf.name): failed \(i) \(m)")
                case .done(let saved, let errors):
                    AppLog.line("workflow \(wf.name): done saved=\(saved.count) errors=\(errors.count)")
                    let entry: HistoryEntry?
                    do {
                        entry = try self.history?.record(
                            id: runID, kind: kind, createdAt: capturedAt,
                            file: saved.last ?? file, errors: errors)
                    } catch {
                        AppLog.line("history: record failed: \(error.localizedDescription)")
                        entry = nil
                    }
                    // OCR is for Screenshots; an MP4 has nothing to read.
                    if let entry, kind == .screenshot {
                        // only Sendable values cross into the detached task
                        let store = self.history, entryID = entry.id
                        let target = saved.last { $0.pathExtension != "wadjet" } ?? file
                        Task.detached {
                            do {
                                let text = try await recognizeText(in: target)
                                try await store?.setOCR(text, for: entryID)
                            } catch {
                                await AppLog.line("ocr failed: \(error.localizedDescription)")
                            }
                        }
                    }
                    for t in toastCtrl.runToasts[runID] ?? [] {
                        t.title = saved.isEmpty ? "Captured" : "Saved"
                        t.err = errors.isEmpty ? nil : errors.joined(separator: "\n")
                        t.cap.url = saved.last ?? file
                        toastCtrl.startTimer(t)
                    }
                    toastCtrl.runToasts.removeValue(forKey: runID)
                    workflowEffects.canvases.removeValue(forKey: runID)
                }
            }
        }
    }

    // MARK: recording

    /// The system can kill the stream (another capture client, the display
    /// sleeping): finish what's already on disk through the normal path.
    final class RecDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
        func stream(_ stream: SCStream, didStopWithError error: Error) {
            // The stream itself isn't Sendable; its identity is what matters.
            let id = ObjectIdentifier(stream), reason = error.localizedDescription
            Task { @MainActor in
                AppDelegate.shared?.streamStopped(id, reason: reason)
            }
        }
    }

    /// The frames ScreenCaptureKit hands us go straight to the MP4 writer on
    /// its own queue; the timeline drops paused frames.
    final class RecOutput: NSObject, SCStreamOutput, @unchecked Sendable {
        let writer: MP4Writer
        let overlay: WindowAnnotationOverlay? // Record Window only: the Markup panels never reach its frames
        init(writer: MP4Writer, overlay: WindowAnnotationOverlay? = nil) {
            self.writer = writer; self.overlay = overlay
        }
        func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, isCompleteScreenFrame(sb),
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            if let overlay { overlay.write(sb, pixels: pb) }
            else { writer.append(pb, at: CMSampleBufferGetPresentationTimeStamp(sb)) }
        }
    }

    /// The screen source for the Recording that's starting: a window, a region
    /// of one display, or the whole display. Returns nil if ScreenCaptureKit
    /// can't resolve it (the window went away, the display is gone).
    func recordSource(display: Int) async -> (filter: SCContentFilter, pixels: CGSize, sourceRect: CGRect)? {
        let s = AppState.shared
        let f = Freeze.shared.displays[display]
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            AppLog.line("record: shareable content failed: \(error.localizedDescription)")
            return nil
        }
        if s.tool == .recWindow {
            // Resolve against fresh content: overlayCtrl's map is from Freeze
            // time, and a Record Window that can't find its window must never
            // fall back to capturing the whole display.
            guard let id = recordingWindowID,
                  let win = content.windows.first(where: { $0.windowID == id }) else {
                AppLog.line("record: window \(recordingWindowID.map(String.init) ?? "?") is gone")
                return nil
            }
            let sc = f.screen.backingScaleFactor
            return (SCContentFilter(desktopIndependentWindow: win),
                    CGSize(width: win.frame.width * sc, height: win.frame.height * sc),
                    .null)
        }
        guard let num = f.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let disp = content.displays.first(where: { $0.displayID == num }) else {
            AppLog.line("record: no shareable display for index \(display)")
            return nil
        }
        // the Recording shows whatever is on screen — Wadjet's own Freeze
        // Frame, toolbar and markup included; only the red region border is out
        let border = content.windows.filter { $0.windowID == CGWindowID(recordingPanel?.windowNumber ?? -1) }
        let filter = SCContentFilter(display: disp, excludingWindows: border)
        // sourceRect is display-local points with a top-left origin; the
        // overlay's rect is view coords (bottom-left).
        var sourceRect = CGRect.null
        if s.tool == .recRegion {
            sourceRect = CGRect(
                x: recordingRect.origin.x,
                y: disp.frame.height - recordingRect.origin.y - recordingRect.height,
                width: recordingRect.width, height: recordingRect.height)
        }
        let scale = f.screen.backingScaleFactor
        // A region records at its own size; screen recordings at the display's.
        let source = sourceRect.isNull ? disp.frame.size : sourceRect.size
        return (filter, CGSize(width: source.width * scale, height: source.height * scale), sourceRect)
    }

    /// Even dimensions, longest edge capped at the configured resolution —
    /// downscale only, never upscale.
    func recSize(_ source: CGSize) -> CGSize {
        let limit = CGFloat(AppState.shared.config.value.recording.resolution)
        let scale = min(1, limit / max(source.width, source.height))
        return CGSize(
            width: 2 * Int((source.width * scale / 2).rounded(.toNearestOrEven)),
            height: 2 * Int((source.height * scale / 2).rounded(.toNearestOrEven)))
    }

    /// the Tool and Workflow the Recording started with — a Screenshot taken
    /// mid-Recording switches s.tool and consumes triggerWorkflow, so neither
    /// can be read back at stop time
    var recContext: (tool: Tool?, workflow: String)?
    func startRecording(rect: CGRect, display: Int) {
        let s = AppState.shared
        recContext = (s.tool, s.workflowFor(s.tool) ?? s.config.value.defaultWorkflows.recording)
        s.triggerWorkflow = nil // consumed by the Recording, not the next capture
        overlayCtrl.closeAllPanelsOnly() // live screen returns
        // the region border goes up now — recordSource needs the panel to
        // exist so it can exclude it from the video
        showRecBorder(rect: rect, display: display)
        overlayCtrl.chromeScreens = Freeze.shared.displays.isEmpty
            ? NSScreen.screens : Freeze.shared.displays.map(\.screen)
        recordingRect = rect; recordingDisplay = display
        pauseAcc = 0; s.recordingElapsed = 0; s.recordingPaused = false
        // .countdown holds until beginStream lands .recording or .desktop —
        // setup can await, and a Shortcut press meanwhile must not trigger.
        s.phase = .countdown
        recAttempt += 1
        let attempt = recAttempt
        let n = s.countdown == "Off" ? 0 : Int(s.countdown) ?? 0
        let begin = {
            _ = Task { @MainActor in
                await self.beginStream(attempt: attempt)
            }
        }
        if n > 0 {
            AppLog.line("phase=countdown (\(n))")
            updateEscHotkey()
            CountdownHUD.show(n)
            Task { @MainActor in
                for i in stride(from: n - 1, through: 0, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    guard attempt == self.recAttempt else { return } // a newer attempt owns the HUD
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
    // the Recording's own menu bar item beside the Wadjet eye — the main
    // item keeps its icon and normal menu throughout
    var recStatusItem: NSStatusItem?
    func updateRecChrome() {
        let s = AppState.shared
        if recStatusItem == nil { recStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        recStatusItem?.button?.title = (s.recordingPaused ? "❚❚ " : "● ") + fmtT(s.recordingElapsed)
        let m = NSMenu()
        m.addItem(mi(s.recordingPaused ? "Resume" : "Pause", #selector(recPause), on: false))
        m.addItem(mi("Stop Recording", #selector(recStop), on: false))
        recStatusItem?.menu = m
        AppLog.line("menu bar: wadjet=\(statusItem.button?.image == nil ? "?" : "eye") rec=\(recStatusItem?.button?.title ?? "-")")
        overlayCtrl.refreshToolbars()
    }
    @objc func recPause() { togglePause() }
    @objc func recStop() { stopRecording() }
    /// A lost Recording must be visible, not just logged — a toast with the
    /// reason and no thumbnail.
    func errorToast(_ title: String, _ detail: String) {
        let t = ToastItem(cap: Capture(thumb: nil, label: title, url: nil, duration: nil))
        t.title = title; t.err = detail
        toastCtrl.items.insert(t, at: 0)
        toastCtrl.relayout()
        toastCtrl.startTimer(t)
    }

    /// Build and start the SCStream + MP4Writer once any countdown finishes.
    /// .countdown stays the phase through setup — a Shortcut press is ignored
    /// and an Esc cancel lands us back on .desktop, which the guards catch.
    /// A failure (no Screen Recording permission, a gone window) closes the
    /// chrome, lands back on the desktop, and toasts the reason.
    func beginStream(attempt: Int) async {
        let s = AppState.shared
        let cfg = AppState.shared.config.value
        let live = { s.phase == .countdown && attempt == self.recAttempt }
        guard live(),
              let (filter, sourcePixels, sourceRect) = await recordSource(display: recordingDisplay),
              live(), // an Esc could have cancelled mid-setup
              let file = try? captureFiles.newFile(ext: "mp4") else {
            guard live() else { return } // cancelled: nothing to report
            AppLog.line("record: could not resolve the source or name the file")
            s.recActive = false; s.phase = .desktop; recContext = nil
            rebuildMenu(); overlayCtrl.closeAllPanelsOnly(); overlayCtrl.syncDesktopChrome()
            recordingPanel?.close(); recordingPanel = nil
            errorToast("Couldn't record", "No capture source — Screen Recording permission may be off.")
            return
        }
        let size = recSize(sourcePixels)
        let conf = SCStreamConfiguration()
        conf.width = Int(size.width); conf.height = Int(size.height)
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.recording.fps))
        conf.showsCursor = s.cursor
        conf.pixelFormat = kCVPixelFormatType_32BGRA
        conf.colorSpaceName = CGColorSpace.sRGB
        conf.capturesAudio = false // audio arrives in #30
        conf.queueDepth = 6
        if !sourceRect.isNull { conf.sourceRect = sourceRect }
        do {
            let writer = try MP4Writer(url: file, width: conf.width, height: conf.height, fps: cfg.recording.fps)
            let stream = SCStream(filter: filter, configuration: conf, delegate: recDelegate)
            let output = RecOutput(writer: writer,
                                   overlay: s.tool == .recWindow ? recordingWindowID.map {
                                       WindowAnnotationOverlay(windowID: $0, writer: writer,
                                                               queue: recQueue, fps: cfg.recording.fps)
                                   } : nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: recQueue)
            try await stream.startCapture()
            // An Esc during startup cancelled this attempt; don't start recording.
            guard live() else {
                try? await stream.stopCapture()
                writer.cancel()
                return
            }
            recStream = stream; recWriter = writer; recOutput = output
            s.recActive = true; s.phase = .desktop; self.recStart = Date()
            AppLog.line("recording \(Int(size.width))x\(Int(size.height)) @\(cfg.recording.fps)")
            self.updateEscHotkey()
            self.updateRecChrome()
        } catch {
            AppLog.line("record: stream failed to start: \(error.localizedDescription)")
            guard live() else { return } // a cancelled attempt must not reset a newer one
            s.recActive = false; s.phase = .desktop; recContext = nil
            rebuildMenu(); overlayCtrl.closeAllPanelsOnly(); overlayCtrl.syncDesktopChrome()
            recordingPanel?.close(); recordingPanel = nil
            errorToast("Couldn't record", error.localizedDescription)
        }
    }

    func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    func togglePause() {
        let s = AppState.shared
        if s.recordingPaused {
            pauseAcc += Date().timeIntervalSince(pauseStart!)
            s.recordingPaused = false
            recWriter?.resume(at: hostNow())
            recOutput?.overlay?.refresh() // catch up Annotations edited while paused
        } else {
            s.recordingPaused = true; pauseStart = Date()
            recWriter?.pause(at: hostNow())
        }
        updateRecChrome()
    }
    func recTick() {
        let s = AppState.shared
        guard s.recActive, !s.recordingPaused, let st = recStart else { return }
        s.recordingElapsed = Date().timeIntervalSince(st) - pauseAcc
        recStatusItem?.button?.title = "● " + fmtT(s.recordingElapsed)
    }
    // Esc during countdown cancels before the Recording starts.
    func cancelCountdown() {
        let s = AppState.shared
        guard s.phase == .countdown else { return }
        CountdownHUD.hide()
        s.phase = .desktop; recStart = nil; recContext = nil
        recordingPanel?.close(); recordingPanel = nil
        overlayCtrl.closeAllPanelsOnly()
        overlayCtrl.syncDesktopChrome()
        AppLog.line("esc: cancelled countdown")
        rebuildMenu(); updateEscHotkey()
    }
    func stopRecording() {
        let s = AppState.shared
        s.recordingElapsed = recStart.map { Date().timeIntervalSince($0) - pauseAcc } ?? s.recordingElapsed
        let dur = s.recordingElapsed
        let label = "\(recContext?.tool?.title ?? "Recording") \(fmtT(dur))"
        let stoppedAt = hostNow()
        let stream = recStream, writer = recWriter
        recStream = nil; recWriter = nil; recOutput = nil
        recordingPanel?.close(); recordingPanel = nil
        s.recActive = false; recStart = nil
        // stopping ends only the Recording — a Freeze Frame that's up is an
        // unrelated Screenshot in progress and stays up (its Shortcut one-shot
        // Workflow survives too). Without one, the recording chrome goes.
        if !s.toolbarOpen {
            s.phase = .desktop
            overlayCtrl.closeAllPanelsOnly()
            overlayCtrl.syncDesktopChrome()
        } else {
            // the bubble dies without the merge (there's no recording island to
            // merge into) and the island returns to the plain toolbar
            overlayCtrl.syncBubbles()
            overlayCtrl.refreshToolbars()
        }
        updateEscHotkey()
        AppLog.line("recording stopped (\(String(format: "%.1f", dur))s) \(label)")
        if let ri = recStatusItem { NSStatusBar.system.removeStatusItem(ri); recStatusItem = nil }
        rebuildMenu()
        // The Workflow is decided now — a Shortcut fired while this finishes
        // must not reach back and change it.
        let workflow = recContext?.workflow ?? s.config.value.defaultWorkflows.recording
        recContext = nil
        Task { @MainActor in
            guard let writer else { return }
            do { try await stream?.stopCapture() }
            catch { AppLog.line("record: stopCapture failed (finishing anyway): \(error.localizedDescription)") }
            do {
                let file = try await writer.finish(at: stoppedAt)
                runCapture(file: file, kind: .mp4, label: label, workflow: workflow)
            } catch {
                AppLog.line("record: finish failed: \(error.localizedDescription)")
                errorToast("Recording was lost", error.localizedDescription)
            }
        }
    }

    /// The stream died under us: finish the partial recording the same way a
    /// Stop press does, and surface the reason. A stale callback from an
    /// earlier stream does nothing.
    func streamStopped(_ id: ObjectIdentifier, reason: String) {
        guard let stream = recStream, ObjectIdentifier(stream) == id,
              AppState.shared.recActive else { return }
        AppLog.line("record: stream stopped: \(reason)")
        errorToast("Recording stopped", reason)
        stopRecording()
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
        // the config observer rescans the ruler when the mode lands
    }
    func updateEscHotkey() {
        let s = AppState.shared
        let active = s.phase == .frozen || s.phase == .toolbar || s.phase == .countdown
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
        if MarkupStyles.shared.cancelEyedropper() { AppLog.line("esc: cancelled eyedropper"); updateEscHotkey(); return }
        if MarkupController.shared.deselect() { AppLog.line("esc: deselected"); return }
        if s.toolbarOpen, s.tool?.kind == .markup { // disarm, dropping any Freeze Frame; Annotations stay
            if s.phase == .frozen { overlayCtrl.dropFreezeFrame() }
            s.tool = nil; s.triggerWorkflow = nil; AppLog.line("esc: disarmed Markup"); updateEscHotkey(); return
        }
        if s.phase == .frozen { s.triggerWorkflow = nil; AppLog.line("esc: cancelled overlay"); overlayCtrl.closeAll(); return }
        if s.phase == .toolbar { s.triggerWorkflow = nil; AppLog.line("esc: closed toolbar"); overlayCtrl.closeAll(); return }
        if s.phase == .countdown { s.triggerWorkflow = nil; cancelCountdown(); return }
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
    /// the screens that carry island/bubble chrome — the Freeze Frame's while
    /// an overlay is up, the live screens while only a Recording runs (the
    /// Freeze Frame is gone then, so nothing else can supply them)
    var chromeScreens: [NSScreen] = []
    var frozenImageViews: [NSView] = [] // each Freeze panel's picture layer
    /// whether the frozen picture shows over the desktop — off when Settings
    /// has Freeze disabled, except for Utilities, which read the frozen pixels
    var showsFrozen: Bool {
        AppState.shared.config.value.capture.freeze || AppState.shared.tool?.kind == .util
    }
    /// the Cursor/Wadjet toggles act on the Freeze Frame already up — swap every
    /// panel's picture to the new pick, keeping HDR where the variant has it
    func swapFrozenImages() {
        let s = AppState.shared
        for (i, v) in frozenImageViews.enumerated() {
            guard i < Freeze.shared.displays.count else { continue }
            let fd = Freeze.shared.displays[i]
            v.layer?.contents = fd.output(hdr: true)
            v.layer?.preferredDynamicRange = fd.outputHDR != nil ? .high : .standard
        }
        if s.openMenu != nil { syncMenu() } // the menu's frost crops the frozen image
        AppLog.line("freeze swap: cursor=\(s.shotCursor ? "on" : "off") wadjet=\(s.shotWadjet ? "on" : "off")")
    }
    var recBubblePanels: [Int: NSPanel] = [:] // the detached recording bubble, one per display
    var bubbleSizes: [Int: CGSize] = [:]
    var dyingBubbles: [Int: NSPanel] = [:]   // mid-merge bubbles awaiting their close
    var bubbleExpanded: [Int: Bool] = [:]    // RecBubbleView reports its controls state
    var scWindows: [CGWindowID: SCWindow] = [:] // windowID -> SCWindow, from freeze time
    var cornerRadii: [CGWindowID: CGFloat] = [:] // windowID -> measured corner radius, points
    var menuPanel: NSPanel?
    var menuMonitor: Any?
    var keyMonitor: Any?
    var lightMonitor: Any?
    init(app: AppDelegate) { self.app = app }

    // the Freeze display under the mouse, fallback 0
    func mouseDisplay() -> Int {
        let m = NSEvent.mouseLocation
        return Freeze.shared.displays.firstIndex { NSMouseInRect(m, $0.screen.frame, false) } ?? 0
    }
    // the toolbar's rect in screen coords — `visible: true` gives the bar
    // shape; the default is the hover rect (expanded on a non-notch display
    // also covers the collapsed-island ghost and the bridge strip, which is
    // right for hit-testing but wrong for "click outside the toolbar")
    func toolbarShapeScreenRect(on di: Int, visible: Bool = false) -> CGRect? {
        let map = visible ? ToolbarHit.shapes : ToolbarHit.rects
        guard let p = toolbarPanels[di], let cv = p.contentView, let r = map[di] else { return nil }
        return p.convertToScreen(cv.convert(r, to: nil))
    }
    var pointerOverUI: Bool {
        let m = NSEvent.mouseLocation
        for (di, _) in toolbarPanels {
            if toolbarShapeScreenRect(on: di)?.contains(m) == true { return true }
        }
        for (_, p) in recBubblePanels { if p.frame.contains(m) { return true } }
        if let mp = menuPanel, mp.frame.contains(m) { return true }
        if let tp = TipPanel.panel, tp.frame.contains(m) { return true }
        return false
    }
    /// the pointer in a panel layer's top-down coords; when it isn't tracked
    /// the light sits far above the shape, which reproduces the top-lit look
    func lightPoint(in panel: NSPanel?, height: CGFloat, above mid: CGPoint) -> CGPoint {
        guard let sc = PointerLight.shared.screen, let p = panel,
              let cv = p.contentView else { return CGPoint(x: mid.x, y: mid.y - 10000) }
        let v = p.convertPoint(fromScreen: sc)
        return CGPoint(x: v.x, y: cv.frame.height - v.y)
    }
    /// re-apply each overlay's cursor when the Tool changes under a still pointer
    func refreshCursors() {
        panels.forEach { $0.contentView?.subviews.compactMap { $0 as? OverlayNSView }.forEach { $0.updateCursor() } }
    }
    /// overlays draw based on pointerOverUI (loupe on/off): repaint when the
    /// pointer crosses between a toolbar/menu and the Freeze Frame
    func markOverlaysDirty() {
        panels.forEach { $0.contentView?.subviews.compactMap { $0 as? OverlayNSView }.forEach { $0.needsDisplay = true } }
    }
    // a Tool button's frame in screen coords (from measured panel-space frames)
    func buttonScreenRect(_ t: Tool, on di: Int) -> CGRect? {
        guard let fr = ToolbarBtnFrames.rects[di]?[t], let p = toolbarPanels[di], let cv = p.contentView else { return nil }
        return p.convertToScreen(cv.convert(fr, to: nil))
    }
    /// a rect in a toolbar panel's content-view coords, in screen coords —
    /// SwiftUI's named "panel" space is the content view's, flipped
    func panelScreenRect(_ r: CGRect, on di: Int) -> CGRect? {
        guard let p = toolbarPanels[di], let cv = p.contentView else { return nil }
        let flipped = CGRect(x: r.minX, y: cv.bounds.height - r.maxY, width: r.width, height: r.height)
        return p.convertToScreen(cv.convert(flipped, to: nil))
    }

    func syncMenu() {
        if let t = AppState.shared.openMenu { TipPanel.hide(); showMenu(t) } else { hideMenu() }
    }
    func showMenu(_ t: Tool) {
        // anchor to the panel of the expanded display (or the pointer's)
        let di = AppState.shared.expandedDisplay ?? mouseDisplay()
        guard let tp = toolbarPanels[di], t.hasMenu else { return }
        hideMenu()
        // headroom above the menu so its scale-in never clips; top-aligned so
        // a growing menu grows downward
        let scr = tp.screen?.frame ?? NSScreen.main!.frame
        let bar = toolbarShapeScreenRect(on: di)
        let anchor = buttonScreenRect(t, on: di) ?? bar ?? CGRect(x: scr.midX, y: scr.maxY - 40, width: 0, height: 0)
        // centred under the Tool, its top 8 pt below the bar's bottom edge
        let top = min(anchor.minY, bar?.minY ?? anchor.minY) - 8
        var f = NSRect(origin: .zero, size: NSHostingView(rootView: ToolMenuView(tool: t, ctrl: self)
            .padding(.top, Self.menuHeadroom).frame(maxHeight: .infinity, alignment: .top)).fittingSize)
        // a body taller than the space below its top edge scrolls instead
        f.size.height = cappedMenuHeight(t, maxBody: top - (scr.minY + 8))
        f.origin = CGPoint(x: min(max(scr.minX + 8, anchor.midX - f.width / 2), scr.maxX - f.width - 8),
                           y: max(scr.minY + 8, top - (f.height - Self.menuHeadroom)))
        // the menu's own frost: the Freeze Frame column from its body's top to
        // the display's bottom, so a menu that grows downward stays aligned;
        // blurred and darkened, under .regular glass for the rim — nil without a Freeze
        var backdrop: CGImage? = nil
        #if CLEAR_GLASS_PATCH
        if showsFrozen, di < Freeze.shared.displays.count {
            backdrop = Freeze.shared.crop(rect: CGRect(x: f.minX - scr.minX, y: 0,
                                                     width: f.width, height: f.maxY - Self.menuHeadroom - scr.minY), on: di)
        }
        #endif
        let h = NSHostingView(rootView: ToolMenuView(tool: t, ctrl: self, backdrop: backdrop)
            .padding(.top, Self.menuHeadroom).frame(maxHeight: .infinity, alignment: .top))
        h.frame.size = f.size
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver + 2; p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = h; p.orderFront(nil)
        menuPanel = p
        AppLog.line("menu \(t.title) @ \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))")
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, let mp = self.menuPanel else { return e }
            // clicks inside the toolbar are the toolbar's own business —
            // the tap lands in its gesture and toggles the menu from there
            if toolbarShapeScreenRect(on: di, visible: true)?.contains(NSEvent.mouseLocation) == true { return e }
            // the panel's top strip is scale-in headroom — clicks there count as outside
            let body = NSRect(x: mp.frame.minX, y: mp.frame.minY, width: mp.frame.width, height: mp.frame.height - Self.menuHeadroom)
            if !body.contains(NSEvent.mouseLocation) {
                AppState.shared.openMenu = nil; self.syncMenu()
                AppLog.line("menu closed (outside click)")
            }
            return e
        }
    }
    func hideMenu() {
        markOverlaysDirty()
        guard let p = menuPanel else { return }
        menuPanel = nil
        if let m = menuMonitor { NSEvent.removeMonitor(m); menuMonitor = nil }
        // the menu fades out, then the panel closes
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 },
                                           completionHandler: { Task { @MainActor in p.close() } })
    }

    var freezeLatencies: [Double] = [] // hotkey-to-Freeze-Frame ms, one per open
    struct CaptureError: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    func freezeAndShow(tool: Tool, start: ContinuousClock.Instant, immediate: Bool = false) async {
        func ms(_ d: Duration) -> Int { Int(d / .milliseconds(1)) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let tContent = start.duration(to: .now)
            Freeze.shared.displays = []
            scWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            // displays stay sequential: FrozenDisplay holds a raw bitmap
            // pointer, so it can't cross a task boundary without a sendability
            // hack — the two screenshots of each display still run concurrently
            var failures: [String] = []
            for screen in NSScreen.screens {
                do { Freeze.shared.displays.append(try await frozenDisplay(on: screen, from: content)) } catch {
                    failures.append("\(screen.localizedName): \(error.localizedDescription)")
                    AppLog.line("freeze \(screen.localizedName) failed: \(error.localizedDescription)")
                }
            }
            // nothing captured: stay on the desktop so the next Tool shortcut retries
            guard !Freeze.shared.displays.isEmpty else { throw CaptureError(failures.joined(separator: "; ")) }
            // "capture" includes pixel prep: the sRGB bitmap is drawn inside
            // the same per-display work as the screenshots
            let tCapture = start.duration(to: .now)
            await MainActor.run {
                // a confirm-off Shortcut: the captures above filled the displays,
                // windows and corners the select paths need — shoot without the
                // overlay and leave the latency/phase logging out, it's wrong here
                if immediate {
                    AppLog.line("freeze \(ms(start.duration(to: .now))) ms → immediate \(tool.title)")
                    AppDelegate.shared?.captureImmediately(tool)
                    return
                }
                self.showPanels(tool: tool)
                CATransaction.flush() // commit the Freeze Frame layers, then stop the clock
                let total = start.duration(to: .now)
                let totalMs = ms(total)
                self.freezeLatencies.append(Double(totalMs))
                AppState.shared.latencyText = String(format: "%.0f ms (%d displays)", Double(totalMs), Freeze.shared.displays.count)
                AppLog.line("freeze \(totalMs) ms (content \(ms(tContent)), capture \(ms(tCapture - tContent)), present \(ms(total - tCapture)))")
                for (i, fd) in Freeze.shared.displays.enumerated() {
                    let img = fd.hdrImage ?? fd.image
                    let f = fd.screen.frame
                    AppLog.line("freeze d\(i) \(fd.screen.localizedName): \(Int(f.width))×\(Int(f.height)) pt @\(Int(fd.screen.backingScaleFactor))x → \(img.width)×\(img.height) px\(fd.hdrImage != nil ? " HDR" : "") bare=\(fd.bareCaptured ? "captured" : "shared")")
                }
                if let p50 = self.freezeLatencies.percentile(50), let p95 = self.freezeLatencies.percentile(95) {
                    AppLog.line("freeze p50 \(Int(p50)) ms, p95 \(Int(p95)) ms over \(self.freezeLatencies.count) opens (target p95 ≤ 200 ms)")
                }
                AppLog.line("phase=frozen tool=\(tool.title)")
                self.measureWindowCorners()
            }
        } catch {
            await MainActor.run {
                AppState.shared.latencyText = "capture failed: \(error.localizedDescription)"
                AppLog.line("freeze failed: \(error.localizedDescription)")
            }
        }
    }
    // one display's Freeze Frame: two screenshots taken concurrently — what the
    // panel shows (cursor, HDR as the display allows) and `clean` (cursor-free
    // SDR) that every pixel read uses, so the frozen cursor never lands in a
    // Pick Colour, loupe or Measure reading
    func frozenDisplay(on screen: NSScreen, from content: SCShareableContent) async throws -> FrozenDisplay {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let disp = content.displays.first(where: { $0.displayID == num }) else { throw CaptureError("no shareable display") }
        let w = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let h = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        // the standard shot leaves out only the compact chrome (island, notch,
        // bubble); the bare shot leaves out every Wadjet window, and is taken
        // only if we have a window up beyond that chrome — otherwise the bare
        // fields just share the regular images
        let chromeExcluded = frozenExcludedWindows(from: content)
        let stdFilter = SCContentFilter(display: disp, excludingWindows: chromeExcluded)
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let bareFilter = SCContentFilter(display: disp, excludingApplications: own, exceptingWindows: [])
        let chromeIDs = Set(chromeExcluded.map(\.windowID))
        let primaryH = NSScreen.screens[0].frame.height
        let scrTL = CGRect(x: screen.frame.minX, y: primaryH - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height)
        // our status item windows are SCK-visible but never render into a
        // screenshot and would keep `needBare` permanently true — exclude
        // exactly them (a PID/layer filter would catch the .floating toast
        // and pin panels)
        let statusish: Set<CGWindowID> = Set([AppDelegate.shared?.statusItem?.button?.window,
                                              AppDelegate.shared?.recStatusItem?.button?.window]
            .compactMap { $0?.windowNumber }.map { CGWindowID(truncatingIfNeeded: $0) })
        let ownWindow = { (w: SCWindow) in w.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            && !statusish.contains(w.windowID) }
        let ownWindows = content.windows.filter { w in
            ownWindow(w) && w.isOnScreen && !chromeIDs.contains(w.windowID) && w.frame.intersects(scrTL)
        }
        // bare images only feed the frozen display swap — skip them when the
        // Freeze Frame isn't shown (the live shot at confirm decides then)
        let needBare = AppState.shared.config.value.capture.freeze && !ownWindows.isEmpty
        if !ownWindows.isEmpty {
            AppLog.line("bare: own windows \(ownWindows.map { "\($0.title ?? "?")@\($0.frame)" })")
        }
        // MainActor-inheriting tasks created on the actor itself: the SCK
        // calls suspend off-actor so the captures overlap, while `disp`
        // never leaves its region (no SCK type is Sendable, so `async let`
        // can't carry them itself)
        let shot = Task { @MainActor in try await screenshot(disp, width: w, height: h, cursor: true, hdr: hdr, filter: stdFilter) }
        let cleanShot = Task { @MainActor in try await screenshot(disp, width: w, height: h, cursor: false, hdr: hdr, filter: stdFilter) }
        let bareShot = needBare ? Task { @MainActor in try await screenshot(disp, width: w, height: h, cursor: true, hdr: hdr, filter: bareFilter) } : nil
        let bareCleanShot = needBare ? Task { @MainActor in try await screenshot(disp, width: w, height: h, cursor: false, hdr: hdr, filter: bareFilter) } : nil
        let (out, cleanOut) = try await (shot.value, cleanShot.value)
        let (bareOut, bareCleanOut) = (try await bareShot?.value, try await bareCleanShot?.value)
        guard let img = out.sdr ?? out.hdr, let clean = cleanOut.sdr else { throw CaptureError("screenshot returned no image") }
        var fd = FrozenDisplay(screen: screen, image: img, clean: clean)
        fd.hdrImage = out.hdr; fd.cleanHDR = cleanOut.hdr
        fd.bare = bareOut?.sdr ?? bareOut?.hdr; fd.bareHDR = bareOut?.hdr
        fd.bareClean = bareCleanOut?.sdr ?? bareCleanOut?.hdr; fd.bareCleanHDR = bareCleanOut?.hdr
        fd.bareCaptured = needBare
        // CGWindowList is front-to-back, so first-hit is the frontmost
        // window — SCShareableContent's windows list isn't ordered
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let sy = screen.frame
        // our own layer-0 windows (Settings) ARE capturable; every overlay
        // panel rides at a non-zero level, so the layer check excludes them
        fd.windowFrames = infos.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
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
        // bitmap for pixel reads — real sRGB so colour math is honest
        let bw = clean.width, bh = clean.height
        var data = [UInt8](repeating: 0, count: bw * bh * 4)
        let ok = data.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: bw, height: bh, bitsPerComponent: 8,
                                      bytesPerRow: bw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
            ctx.draw(clean, in: CGRect(x: 0, y: 0, width: bw, height: bh)); return true
        }
        if ok { fd.bitmap = UnsafePointer(data.withUnsafeBufferPointer { $0.baseAddress }); fd.bitmapWidth = bw; fd.bitmapHeight = bh
            bitmapStore.append(data) }
        return fd
    }
    // one display screenshot at pixel resolution: `cursor` decides whether the
    // pointer is composited in, `hdr` asks for an extended-sRGB variant
    // every full-display capture leaves out Wadjet's compact chrome — the
    // collapsed island/notch, the collapsed recording bubble, and the Markup
    // toolbar, live or expanded — so no stale remnant of our own UI freezes
    // under the live one. Expanded Recording-island controls and expanded
    // bubble controls DO freeze into the shot, like any window.
    func frozenExcludedWindows(from content: SCShareableContent) -> [SCWindow] {
        var nums: [CGWindowID] = []
        let expanded = AppState.shared.expandedDisplay
        let recIsland = AppState.shared.recActive && AppState.shared.showIslandWhileRecording
            && AppState.shared.phase == .desktop && MarkupController.shared.stack.isEmpty
        for (di, p) in toolbarPanels {
            // only the expanded Recording island freezes in; the collapsed
            // island and the live/expanded Markup toolbar never do
            if di != expanded || !recIsland { nums.append(CGWindowID(p.windowNumber)) }
        }
        nums.append(contentsOf: MarkupController.shared.windowNumbers.map(CGWindowID.init))
        for (di, p) in recBubblePanels {
            if bubbleExpanded[di] != true { nums.append(CGWindowID(p.windowNumber)) }
        }
        let set = Set(nums)
        return content.windows.filter { set.contains($0.windowID) }
    }
    func screenshot(_ disp: SCDisplay, width: Int, height: Int, cursor: Bool, hdr: Bool, filter: SCContentFilter) async throws -> (sdr: CGImage?, hdr: CGImage?) {
        let cfg = SCScreenshotConfiguration()
        cfg.width = width; cfg.height = height
        cfg.showsCursor = cursor; cfg.displayIntent = .local
        cfg.dynamicRange = hdr ? .bothSDRAndHDR : .sdr
        let out = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter, configuration: cfg)
        return (out.sdrImage, out.hdrImage)
    }
    // measure each window's real corner radius from a corner screenshot, so the
    // Capture Window highlight can follow it — window radii vary per window in
    // macOS 26+ (title-bar-only vs toolbar, none full-screen). Front-to-back in
    // windowFrames order; stops if the Freeze Frame goes away.
    func measureWindowCorners() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var seen = Set<CGWindowID>()
            var measured: [String] = []
            for fd in Freeze.shared.displays {
                for w in fd.windowFrames where seen.insert(w.id).inserted {
                    guard AppState.shared.phase == .frozen else { return }
                    guard let scw = scWindows[w.id],
                          let r = await measureWindowCorner(scw, scale: fd.screen.backingScaleFactor) else { continue }
                    cornerRadii[w.id] = r
                    let name = scw.owningApplication?.applicationName ?? "?"
                    measured.append("\(name) \(String(format: "%.1f", r)) pt")
                }
            }
            for p in panels {
                p.contentView?.subviews.compactMap { $0 as? OverlayNSView }.forEach { $0.needsDisplay = true }
            }
            AppLog.line("window corners: \(measured.joined(separator: ", "))")
        }
    }
    // the window's real corner radius in points, read off the alpha ramp along
    // the diagonal of a 32×32 pt shot of its bottom-right corner; nil when the
    // corner can't be captured
    func measureWindowCorner(_ scw: SCWindow, scale: CGFloat) async -> CGFloat? {
        let side: CGFloat = 32
        let px = Int((side * scale).rounded())
        let cfg = SCScreenshotConfiguration()
        cfg.sourceRect = CGRect(x: scw.frame.width - side, y: scw.frame.height - side, width: side, height: side)
        cfg.width = px; cfg.height = px
        cfg.ignoreShadows = true; cfg.showsCursor = false
        cfg.dynamicRange = .sdr
        guard let img = try? await SCScreenshotManager.captureScreenshot(
            contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: cfg).sdrImage,
              img.width >= 2, img.height >= 2 else { return nil }
        var alpha = [UInt8](repeating: 0, count: img.width * img.height)
        let ok = alpha.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: img.width, height: img.height,
                                      bitsPerComponent: 8, bytesPerRow: img.width, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height)); return true
        }
        guard ok else { return nil }
        // bitmap row 0 is the image's top row: walk the diagonal inward from
        // the bottom-right pixel
        let n = min(img.width, img.height)
        let diag = (0..<n).map { i in alpha[(img.height - 1 - i) * img.width + (img.width - 1 - i)] }
        return cornerRadius(diagonalAlpha: diag).map { CGFloat($0) / scale }
    }
    var bitmapStore: [[UInt8]] = []

    /// the app that was active before we stole activation for the overlay —
    /// handed back on close unless the user switched away meanwhile
    var prevFrontmost: NSRunningApplication?

    func showPanels(tool: Tool) {
        let s = AppState.shared
        // a Markup Tool armed on the live toolbar already took activation;
        // keep its hand-back target so close returns focus to the user's app —
        // captured before s.tool fires syncArmed, whose disarm hands back
        let prev = prevFrontmost ?? NSWorkspace.shared.frontmostApplication
        prevFrontmost = nil
        s.tool = tool; s.phase = .frozen
        chromeScreens = Freeze.shared.displays.map(\.screen)
        closeAllPanelsOnly()
        for (i, fd) in Freeze.shared.displays.enumerated() {
            let p = OverlayPanel(contentRect: fd.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver; p.hasShadow = false
            p.animationBehavior = .none // no system scale-in: the Freeze Frame must sit exactly on the screen it copies
            p.isOpaque = false; p.backgroundColor = .clear // live desktop shows through when the Freeze Frame is off
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.ignoresMouseEvents = false; p.acceptsMouseMovedEvents = true
            p.hidesOnDeactivate = false
            // the frozen frame lives in its own layer under the overlay drawing so
            // HDR captures can render with extended dynamic range
            let imageView = NSView(frame: NSRect(origin: .zero, size: fd.screen.frame.size))
            imageView.wantsLayer = true
            imageView.layer?.contents = fd.output(hdr: true)
            imageView.layer?.contentsGravity = .resize
            if fd.outputHDR != nil { imageView.layer?.preferredDynamicRange = .high }
            imageView.isHidden = !showsFrozen
            frozenImageViews.append(imageView)
            let ov = OverlayNSView(frame: NSRect(origin: .zero, size: fd.screen.frame.size), displayIndex: i, controller: self)
            let container = NSView(frame: NSRect(origin: .zero, size: fd.screen.frame.size))
            container.addSubview(imageView); container.addSubview(ov)
            p.contentView = container
            p.orderFront(nil)
            p.makeFirstResponder(ov)
            panels.append(p)
        }
        MarkupController.shared.raise() // Annotations sit above the Freeze Frame
        // Only the ACTIVE app's cursor changes reach the screen — the overlay
        // is non-activating, so while a Freeze Frame is up we take activation
        // and make the pointer's panel key so cursorUpdate fires for it.
        // Window lists were read at freeze time, before this.
        prevFrontmost = prev
        if prevFrontmost?.processIdentifier != getpid() {
            NSApp.activate(ignoringOtherApps: true)
            AppLog.line("active for overlay (was \(prevFrontmost?.localizedName ?? "?"))")
        }
        if let md = panels.firstIndex(where: { $0.screen != nil && NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            panels[md].makeKey()
        }
        // borderless nonactivating panels can't be key windows, so keyDown on
        // the view never fires — route keys through a local monitor instead
        lightMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { e in
            PointerLight.shared.feed(NSEvent.mouseLocation)
            return e
        }
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
        for (idx, sc) in chromeScreens.enumerated() {
            let tv = ToolbarView(displayIndex: idx, ctrl: self)
            let hosting = PassthroughHostingView(rootView: tv)
            hosting.displayIndex = idx
            let size = NSSize(width: tv.panelW, height: tv.panelH)
            hosting.frame = NSRect(origin: .zero, size: size)
            let p = NSPanel(contentRect: NSRect(x: sc.frame.midX - size.width / 2,
                                                y: sc.frame.maxY - size.height,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver + 1; p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = false; p.animationBehavior = .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.acceptsMouseMovedEvents = true; p.hidesOnDeactivate = false
            p.contentView = hosting; p.orderFront(nil)
            toolbarPanels[idx] = p
            AppLog.line("toolbar panel d\(idx) \(p.frame.debugDescription) shape=\(tv.shapeRectInView.debugDescription)")
        }
        syncBubbles()
    }

    /// the recording bubble exists only while the Recording can't own the island —
    /// a Freeze Frame or live toolbar is open mid-Recording, or Annotations hold the
    /// island — one per display, beside the island/toolbar shape
    func syncBubbles() {
        let want = AppState.shared.recActive && AppState.shared.showIslandWhileRecording
            && (AppState.shared.toolbarOpen || !MarkupController.shared.stack.isEmpty)
        for di in chromeScreens.indices {
            if want, recBubblePanels[di] == nil {
                if let d = dyingBubbles[di] { d.close(); dyingBubbles[di] = nil } // cancel a merge still in flight
                let h = NSHostingView(rootView: RecBubbleView(displayIndex: di, ctrl: self))
                let p = NSPanel(contentRect: NSRect(origin: .zero, size: h.fittingSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.level = .screenSaver + 1; p.isOpaque = false; p.backgroundColor = .clear
                p.hasShadow = false
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                p.acceptsMouseMovedEvents = true; p.hidesOnDeactivate = false
                p.contentView = h; p.orderFront(nil)
                recBubblePanels[di] = p
            } else if !want {
                closeBubble(di: di, merge: AppState.shared.recActive && AppState.shared.showIslandWhileRecording)
            }
        }
        for (di, _) in recBubblePanels { layoutBubble(on: di) }
    }

    /// hide/show the frozen picture for the current Tool — a mid-session
    /// switch to a Utility reveals it, switching back hides it again
    func applyFreezeVisibility() {
        let hidden = !showsFrozen
        for v in frozenImageViews { v.isHidden = hidden }
        markOverlaysDirty()
    }
    /// the island pill's midline and height on a display — the same maths the
    /// ToolbarView uses (islandH/gap/pillH), so the bubble stays centred on the
    /// pill whatever shape the toolbar is in
    func islandPill(on di: Int) -> (midY: CGFloat, h: CGFloat)? {
        guard di < chromeScreens.count else { return nil }
        let sc = chromeScreens[di]
        let hasNotch = sc.safeAreaInsets.top > 0 && !AppState.shared.islandMode
        let islandH = max(22, max(0, sc.frame.maxY - sc.visibleFrame.maxY))
        let gap: CGFloat = hasNotch ? 0 : 3
        let pillH = islandH - 2 * gap
        return (sc.frame.maxY - gap - pillH / 2, pillH)
    }
    /// a Screenshot taken at confirm, not at freeze — the desktop has moved on
    /// by then. Called after closeAll, so our session windows are already down;
    /// their window numbers leave the shot when Wadjet windows stay in.
    func liveShot(rect: CGRect, screen: NSScreen, excluding: Set<Int>, cursor: Bool, wadjet: Bool) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let disp = content.displays.first(where: { $0.displayID == num }) else {
            AppLog.line("live shot: no shareable display")
            return nil
        }
        let filter: SCContentFilter
        if wadjet {
            // closeAll may have rebuilt the desktop islands since `excluding` was taken
            let excluded = excluding.union(toolbarPanels.values.map(\.windowNumber))
            filter = SCContentFilter(display: disp, excludingWindows: content.windows.filter { excluded.contains(Int($0.windowID)) })
        } else {
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: disp, excludingApplications: own, exceptingWindows: [])
        }
        let w = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let h = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        let hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        guard let out = try? await screenshot(disp, width: w, height: h, cursor: cursor, hdr: hdr, filter: filter),
              let img = out.hdr ?? out.sdr else {
            AppLog.line("live shot: capture failed")
            return nil
        }
        AppLog.line("live shot \(img.width)x\(img.height)")
        return Freeze.pixelCrop(of: img, rect: rect, in: screen)
    }
    /// `gap` off the right edge of whatever shape is up (island or expanded
    /// bar), top-aligned with the island pill — flipping to the shape's left
    /// when the right side would leave the screen, under it when neither side
    /// has room. Called on every shape/layout change via syncHit
    func layoutBubble(on di: Int, size: CGSize? = nil) {
        if let size { bubbleSizes[di] = size }
        guard let p = recBubblePanels[di], let shape = toolbarShapeScreenRect(on: di),
              let pill = islandPill(on: di), di < chromeScreens.count else { return }
        let sz = bubbleSizes[di] ?? p.frame.size
        // top edge anchored to the pill's top: the compact bubble IS the pill,
        // and the taller expanded controls grow downward, staying on screen
        let r = BubbleLayout.frame(size: sz, beside: shape, top: pill.midY + pill.h / 2,
                                   in: chromeScreens[di].frame)
        guard r != p.frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            p.animator().setFrame(r, display: true)
        }
    }
    /// overlay close mid-Recording: the bubble slides back into the island's
    /// right edge (scale 0.6, fade, ~0.3 s) before its panel goes; every other
    /// path closes it at once
    func closeBubble(di: Int, merge: Bool) {
        guard let p = recBubblePanels[di] else { return }
        recBubblePanels[di] = nil; bubbleSizes[di] = nil
        guard merge else { p.close(); return }
        dyingBubbles[di] = p
        AppState.shared.bubblesDying = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            p.close()
            if self.dyingBubbles[di] === p { self.dyingBubbles[di] = nil }
        }
    }
    func bubbleScreenRect(_ r: CGRect, on di: Int) -> CGRect? {
        guard let p = recBubblePanels[di], let cv = p.contentView else { return nil }
        return p.convertToScreen(cv.convert(r, to: nil))
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
        if AppState.shared.toolbarOpen || (AppState.shared.recActive && AppState.shared.showIslandWhileRecording)
            || !MarkupController.shared.stack.isEmpty { showToolbars() }
        AppLog.line("chrome: \(toolbarPanels.count) islands, \(recBubblePanels.count) bubbles on \(chromeScreens.count) screens")
    }
    func closeAllPanelsOnly() {
        panels.forEach { $0.close() }
        panels = []; frozenImageViews = []
        hideMenu()
        if AppState.shared.openMenu != nil { AppState.shared.openMenu = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = lightMonitor { NSEvent.removeMonitor(m); lightMonitor = nil }
        PointerLight.shared.screen = nil
        TipPanel.hide()
        toolbarPanels.values.forEach { $0.close() }; toolbarPanels = [:]
        let merge = AppState.shared.recActive && AppState.shared.showIslandWhileRecording
        for di in recBubblePanels.keys { closeBubble(di: di, merge: merge) }
        ToolbarHit.rects = [:]; ToolbarBtnFrames.rects = [:]
        handBackActivation()
    }
    /// every teardown — Recording start, Esc, failures — hands activation
    /// back unless the user switched apps meanwhile
    func handBackActivation() {
        if let prev = prevFrontmost {
            prevFrontmost = nil
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                prev.activate(options: [])
                AppLog.line("activation back to \(prev.localizedName ?? "?")")
            }
            NSCursor.arrow.set() // once activation leaves, our cursor can't change
        }
    }
    /// Escape with a Markup Tool armed: the Freeze Frame goes, the toolbar stays over the live screen
    func dropFreezeFrame() {
        AppState.shared.phase = .toolbar
        closeAllPanelsOnly()
        Freeze.shared.displays = []; bitmapStore = []; cornerRadii = [:]
        AppState.shared.expandedDisplay = nil
        chromeScreens = NSScreen.screens
        refreshToolbars()
        app?.updateEscHotkey()
    }
    func closeAll() {
        // phase first: cursorUpdate on the dying panels must not re-assert
        // a tool cursor after we're gone
        if AppState.shared.phase != .desktop { AppLog.line("phase=desktop (overlay closed)") }
        AppState.shared.phase = .desktop
        closeAllPanelsOnly()
        // mid-Recording the recording island returns once the overlay is gone,
        // and the island stays while Annotations exist; the Freeze Frame is
        // about to be freed, so the islands ride the live screens from here on
        syncDesktopChrome()
        AppState.shared.expandedDisplay = nil
        Freeze.shared.displays = []; bitmapStore = []; cornerRadii = [:]
        NSCursor.arrow.set()
        AppDelegate.shared?.updateEscHotkey()
    }
}

/// Per-tool pointer over the Freeze Frame; built once and cached.
/// Over a toolbar the plain arrow wins (set from the toolbar's own hover).
@MainActor
enum WadjetCursors {
    static var cache: [Tool: NSCursor] = [:]
    static func cursor(for t: Tool) -> NSCursor {
        if let c = cache[t] { return c }
        let c = make(t); cache[t] = c; return c
    }
    static func make(_ t: Tool) -> NSCursor {
        switch t {
        case .capRegion, .recRegion, .copyText, .measure, .draw, .shapes, .counter, .censor: return .crosshair
        case .select: return .arrow
        case .capWindow, .capScreen: return symbol("camera.fill", centre: true)
        case .recWindow, .recScreen: return symbol("video.fill", centre: true)
        case .pickColour: return symbol("eyedropper", centre: false)
        case .clearAnnotations, .moreMarkup: return .arrow
        }
    }
    /// white glyph with a soft dark halo so it reads on any backdrop —
    /// a black template pass under an NSShadow, then the white palette glyph
    static func symbol(_ name: String, centre: Bool) -> NSCursor {
        let S: CGFloat = 20
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let proto = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return .arrow }
        // the glyph at its natural aspect ratio, centred in the canvas —
        // drawing into proto.size keeps it undistorted
        var drawn = CGRect.zero
        let img = NSImage(size: CGSize(width: S, height: S), flipped: false) { r in
            NSGraphicsContext.current?.imageInterpolation = .high
            let sz = proto.size
            let dst = CGRect(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2,
                             width: min(sz.width, r.width), height: min(sz.height, r.height))
            drawn = dst
            // halo: the same glyph as a black template, blurred 1.5 pt
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.6)
            sh.shadowBlurRadius = 1.5; sh.set()
            proto.isTemplate = true; NSColor.black.set()
            proto.draw(in: dst)
            NSGraphicsContext.restoreGraphicsState()
            proto.isTemplate = false
            proto.draw(in: dst)
            return true
        }
        // handler-backed images rasterize lazily — force it so drawn is real
        _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        AppLog.line("cursorimg \(name) glyph=\(Int(drawn.width))x\(Int(drawn.height)) in \(Int(S))")
        // eyedropper points down-leading; the lens/tip is its hotspot
        return NSCursor(image: img, hotSpot: centre ? NSPoint(x: S / 2, y: S / 2) : NSPoint(x: 4, y: S - 4))
    }
}

/// the Freeze Frame panel: non-activating, but keyable so it can own the
/// pointer's cursor while the app is activated for the overlay
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    // manual region confirm: after mouse-up the selection stays editable —
    // 8 handles resize, a drag inside moves, the button / Return confirms
    var confirming = false
    var confirmHost: NSView?
    enum SelHandle: CaseIterable { case n, s, e, w, ne, nw, se, sw
        func point(in r: CGRect) -> CGPoint {
            CGPoint(x: contains(.w) ? r.minX : contains(.e) ? r.maxX : r.midX,
                    y: contains(.n) ? r.maxY : contains(.s) ? r.minY : r.midY)
        }
        func contains(_ o: SelHandle) -> Bool { self == o || (self == .ne && o == .n) || (self == .nw && o == .n) || (self == .se && o == .s) || (self == .sw && o == .s) || (self == .ne && o == .e) || (self == .se && o == .e) || (self == .nw && o == .w) || (self == .sw && o == .w) }
    }
    enum SelOp { case move(start: CGPoint, sel: CGRect), resize(SelHandle, CGRect) }
    var selOp: SelOp?
    var manualConfirm: Bool { (tool == .capRegion || tool == .recRegion) && AppState.shared.confirmMode == "manual" }
    func hitHandle(at pt: CGPoint) -> SelHandle? {
        guard let s = sel else { return nil }
        return SelHandle.allCases.first { abs($0.point(in: s).x - pt.x) < 9 && abs($0.point(in: s).y - pt.y) < 9 }
    }
    func resizeSel(from orig: CGRect, handle h: SelHandle, to pt: CGPoint) -> CGRect {
        var r = orig
        if h.contains(.e) { r.size.width = max(8, pt.x - r.minX) }
        if h.contains(.w) { let m = r.maxX; r.origin.x = min(pt.x, m - 8); r.size.width = m - r.minX }
        if h.contains(.n) { r.size.height = max(8, pt.y - r.minY) }
        if h.contains(.s) { let m = r.maxY; r.origin.y = min(pt.y, m - 8); r.size.height = m - r.minY }
        return r
    }
    func showConfirmHost() {
        confirmHost?.removeFromSuperview()
        let label = tool == .capRegion ? "Capture" : "Record"
        let sym = tool == .capRegion ? "camera.fill" : "record.circle"
        let v = Button { [weak self] in self?.confirmSel() } label: {
            Image(systemName: sym).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .onContinuousHover { ph in
            if case .active = ph {
                TipPanel.hover(label, anchor: self.confirmScreenRect())
            } else { TipPanel.hide() }
        }
        let h = NSHostingView(rootView: v); h.frame.size = h.fittingSize
        addSubview(h); confirmHost = h; positionConfirmHost()
    }
    func confirmScreenRect() -> CGRect {
        guard let h = confirmHost, let w = window else { return .zero }
        return w.convertToScreen(h.convert(h.bounds, to: nil))
    }
    /// the confirm circle sits just outside the selection's bottom-trailing
    /// corner, clamped into the overlay
    func positionConfirmHost() {
        guard let h = confirmHost, let s = sel else { return }
        h.frame.origin = CGPoint(
            x: min(bounds.width - 38, s.maxX + 8),
            y: max(8, s.minY - 38))
    }
    /// manual-confirm bookkeeping for a Tool switch: the pending selection
    /// belongs to the Tool it was drawn under
    var lastTool: Tool?
    func syncConfirmTool() {
        if lastTool != tool {
            lastTool = tool
            if confirming {
                confirming = false; selOp = nil; sel = nil
                confirmHost?.removeFromSuperview(); confirmHost = nil
                needsDisplay = true
            }
        }
    }
    func confirmSel() {
        guard confirming, let s = sel,
              tool == .capRegion || tool == .recRegion else { return }
        confirming = false; selOp = nil
        confirmHost?.removeFromSuperview(); confirmHost = nil
        app?.didSelect(s, on: di) // the exact release path
    }
    init(frame f: NSRect, displayIndex: Int, controller: OverlayController) {
        di = displayIndex; ctrl = controller
        super.init(frame: f)
        wantsLayer = true
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
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
            if !overToolbar, let w = hoverWin {
                let r = ctrl?.cornerRadii[w.id] ?? fallbackWindowRadius
                target = NSBezierPath(roundedRect: w.frame, xRadius: r, yRadius: r)
            }
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
            if confirming {
                NSColor.white.setFill()
                for h in SelHandle.allCases {
                    let c = h.point(in: s)
                    NSBezierPath(rect: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
                }
            }
        }
        if t == .measure { drawMeasure() }
        if !overToolbar && t != .measure && t.kind != .markup { drawLoupe(ctx) }
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
        guard ctrl?.showsFrozen != false else { return } // no frozen pixels on a live desktop
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
        let ix1 = min(f.clean.width - 1, x0 + n - 1), iy1 = min(f.clean.height - 1, y0 + n - 1)
        let cell = CGFloat(px), gridY = ly + infoH + 6
        if ix1 >= ix0, iy1 >= iy0,
           let crop = f.clean.cropping(to: CGRect(x: ix0, y: iy0, width: ix1 - ix0 + 1, height: iy1 - iy0 + 1)) {
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
        if tool == .measure, measureMode != "Bounds" { scanRuler(at: pt) }
        updateCursor()
        needsDisplay = true
    }
    /// the arrow over a toolbar/menu, the Tool's own cursor over the frame —
    /// only while frozen; a late cursorUpdate after close must not re-assert
    var lastCursorSig = ""
    func updateCursor() {
        guard AppState.shared.phase == .frozen else { return }
        syncConfirmTool()
        let overUI = ctrl?.pointerOverUI ?? false
        if overUI { NSCursor.arrow.set() }
        else { WadjetCursors.cursor(for: tool).set() }
        // event-rate file I/O is silly — only log when the choice changes
        let cur = NSCursor.currentSystem ?? NSCursor.current
        let sig = "\(cur.image.size)x\(cur.hotSpot)x\(tool.rawValue)x\(overUI)"
        if sig != lastCursorSig { lastCursorSig = sig; AppLog.line("cursor -> sys=\(cur.image.size) hot=\(cur.hotSpot) tool=\(tool.rawValue) overUI=\(overUI)") }
    }
    // a non-activating panel still gets cursorUpdate for its tracking area —
    // that's the reliable hook, mouseMoved alone loses to the system
    override func cursorUpdate(with e: NSEvent) { updateCursor() }
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
        case .copyText, .select, .draw, .shapes, .counter, .censor, .clearAnnotations, .moreMarkup: break
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
            if MarkupStyles.shared.pick(c) { break } // a Markup eyedropper took the pixel
            let s = (ColourFormat(rawValue: AppState.shared.colourFmt) ?? .hex).format(c)
            clipboard(s); showHUD("Copied \(s)", swatch: ColourFormat.hex.format(c))
            ctrl?.closeAll()
        case .measure where measureMode != "Bounds":
            if let v = rulerLabel() { copyMeasureAndClose(v) }
        default:
            if confirming { // manual mode: move / resize / start over
                if let h = hitHandle(at: pt) { selOp = .resize(h, sel!) }
                else if let s = sel, s.contains(pt) { selOp = .move(start: pt, sel: s) }
                else {
                    confirming = false; selOp = nil
                    confirmHost?.removeFromSuperview(); confirmHost = nil
                    dragStart = pt; sel = CGRect(origin: pt, size: .zero)
                }
            } else { dragStart = pt; sel = CGRect(origin: pt, size: .zero) }
        }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        let pt0 = convert(e.locationInWindow, from: nil)
        if let op = selOp {
            switch op {
            case .move(let st, let orig):
                var r = orig.offsetBy(dx: pt0.x - st.x, dy: pt0.y - st.y)
                r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
                r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
                sel = r
            case .resize(let h, let orig):
                sel = resizeSel(from: orig, handle: h, to: pt0)
            }
            positionConfirmHost()
            needsDisplay = true; return
        }
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
        if selOp != nil { selOp = nil; return }
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
        if (tool == .capRegion || tool == .recRegion) && s.width > 4 && s.height > 4 {
            if manualConfirm { confirming = true; showConfirmHost(); return }
            app?.didSelect(s, on: di); return
        }
        sel = nil
    }
    // called from the local key monitor (nonactivating panels don't get keyDown)
    @discardableResult
    func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 36, confirming { confirmSel(); return true } // Return
        if e.keyCode == 53 { app?.handleEsc(); return true }
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
    nonisolated(unsafe) static var rects: [Int: CGRect] = [:] // hover rect, per display index
    nonisolated(unsafe) static var shapes: [Int: CGRect] = [:] // the visible bar, per display index
    nonisolated(unsafe) static var lastHit: [Int: Bool] = [:]
}
// measured button frames in each toolbar panel's coordinate space, reported by
// onGeometryChange — used for hover mapping, menu anchors and CGEvent driving
enum ToolbarBtnFrames {
    nonisolated(unsafe) static var recRects: [Int: [String: CGRect]] = [:] // label -> panel frame
    nonisolated(unsafe) static var rects: [Int: [Tool: CGRect]] = [:]
}

struct ToolbarView: View {
    let displayIndex: Int
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    var expanded: Bool { s.expandedDisplay == displayIndex }
    @Namespace var ns
    var screen: NSScreen? {
        displayIndex < ctrl.chromeScreens.count ? ctrl.chromeScreens[displayIndex] : NSScreen.main
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
    // the compact recording island — only while no Freeze Frame is up; during one the
    // island holds the toolbar and the Recording is the bubble, as it also is while
    // Annotations hold the island
    var recording: Bool { s.recActive && s.showIslandWhileRecording && !s.toolbarOpen
        && MarkupController.shared.stack.isEmpty }

    // Notched display: black, flush with the top edge, rounded bottom corners,
    // centred on (and slightly wider than) the notch.
    // Other displays: a fake Dynamic Island, a black capsule floating inside the
    // menu bar band with a small gap above it. Both show the current Tool's icon
    // and an expand chevron (or the recording dot and time) in ears either side
    // of the notch, so the toolbar is visible while collapsed.
    /// the wide collapsed island: recording dot + time, or the Annotation count
    var wideIsland: Bool { recording || annotationCount != nil }
    var earW: CGFloat { wideIsland ? 48 : 28 }
    // A fake island sizes like the notched one: the notch-width formula with
    // a 185 pt stand-in notch on displays that don't have one.
    var islandW: CGFloat { hasNotch ? max(126, notchW + 2 * earW) : (wideIsland ? 120 : 100) }
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
    /// The concentric rule: one gap `d` between the rest capsule and every
    /// shape edge, so outer corners (radius selH/2 + d) are concentric with
    /// the capsule's end caps.
    var d: CGFloat { 10 }
    var rowGap: CGFloat { 6 }
    var shapeTop: CGFloat { expanded && !hasNotch ? islandH : gap }
    var contentTop: CGFloat { hasNotch ? islandH + rowGap : d }
    var expW: CGFloat { min(limit, recording ? recRowSize.width : rowSize.width) }
    var expH: CGFloat { contentTop + selH + d }
    var shapeW: CGFloat { expanded ? expW : islandW }
    var shapeH: CGFloat { expanded ? expH : pillH }
    // slack beyond expW so a fully stretched lens (lensW × 1.3 at the last
    // cell) still fits inside the panel — hoverRect is shape-based, unaffected
    /// room past the bar's ends for the lens: its stretched half-width beyond
    /// the end cell (~30 pt) plus the spring's overshoot (capped at
    /// lensOvershootCap below), with a few points spare
    let lensSlack: CGFloat = 96
    let lensOvershootCap: CGFloat = 40
    var panelW: CGFloat { min(limit, expW) + 2 * lensSlack }
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
        // an open menu holds its own display expanded — it must NOT make the
        // other displays claim expandedDisplay, which collapses this one and
        // kills the menu. An armed Markup Tool holds the bar expanded —
        // claiming the pointer's display if none is expanded — until Escape
        // or a non-Markup Tool releases it.
        let pointerOnScreen = screen.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false
        let h = hoverInside || lensActive || (s.openMenu != nil && s.expandedDisplay == displayIndex)
            || (MarkupController.shared.armed != nil && (s.expandedDisplay == displayIndex || (s.expandedDisplay == nil && pointerOnScreen)))
        if h != expanded { AppLog.line("hover d\(displayIndex) -> \(h)") }
        if h { s.expandedDisplay = displayIndex }
        else if s.expandedDisplay == displayIndex { s.expandedDisplay = nil }
    }

    func syncHit() {
        ToolbarHit.rects[displayIndex] = hoverRect
        ToolbarHit.shapes[displayIndex] = shapeRectInView
        ctrl.layoutBubble(on: displayIndex)
        if expanded {
            let xs = visibleTools.sorted { $0.rawValue < $1.rawValue }
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
            #if CLEAR_GLASS_PATCH
            // the lens is its own glass-free layer drawn over the bar —
            // glassEffect/backdrop views can't rasterize into layerEffect
            .overlay { lensLayer }
            #endif
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
            .onChange(of: lensActive) { AppLog.line("lensActive d\(displayIndex) -> \(lensActive) bg=\(lensBg != nil)"); syncExpanded() }
            .onAppear { syncHit(); syncLensBg()
                // a Markup Tool armed by a Shortcut or the menu expands the new
                // bar; unarmed bars wait for hover so they don't collapse under
                // a resting pointer
                if MarkupController.shared.armed != nil { syncExpanded() }
            }
            .onChange(of: rowSize) { syncHit(); syncLensBg() }
            .onChange(of: expanded) {
                if expanded, let t = s.tool, let c = cellCentres[t] { snapLens(to: c) }
                else {
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { openGroup = restingGroup }
                }
                syncHit(); syncLensBg()
                if !expanded { s.openMenu = nil; ctrl.hideMenu(); TipPanel.hide() }
            }
            .onChange(of: s.openMenu) { ctrl.syncMenu(); syncExpanded() }
            .onChange(of: s.debugGroup) { // cmd.sh group — the expanded bar animates it
                if let k = s.debugGroup, expanded {
                    s.debugGroup = nil; openTheGroup(k)
                    Task { try? await Task.sleep(for: .milliseconds(600)); syncHit() // log the settled cell rects
                        AppLog.line("all centres d\(displayIndex) @ " + (ToolbarBtnFrames.rects[displayIndex] ?? [:])
                            .sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.title):\(Int($0.value.midX))" }.joined(separator: " ")) }
                }
            }
            .onChange(of: s.debugTap) { // cmd.sh tap — same path as a tap release
                if let t = s.debugTap, expanded, t != s.tool { s.debugTap = nil; travelTap(t) }
                else if s.debugTap != nil { s.debugTap = nil }
            }
            .onChange(of: s.debugHold) { // cmd.sh hold — snap the lens to the cell, pressed
                guard expanded else { return }
                if let t = s.debugHold, let c = cellCentres[t] {
                    snapLens(to: c); pressing = true
                } else if s.debugHold == nil { pressing = false }
            }
            .onChange(of: s.tool) { s.openMenu = nil; ctrl.hideMenu(); TipPanel.hide(); syncHit(); syncExpanded() }
    }

    var shape: UnevenRoundedRectangle {
        // expanded corners are concentric with the rest capsule's caps;
        // collapsed corners stay capsule-round (notch reads as 13 because its
        // top edge is flat against the screen's)
        let bottom: CGFloat = expanded ? selH / 2 + d : (hasNotch ? 13 : pillH / 2)
        let top: CGFloat = hasNotch ? 0 : bottom
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top)
    }

    var morph: some View {
        ZStack(alignment: .top) {
            // collapsed fill sits under the island icons, not over them
            shape.fill(Color.black).opacity(expanded ? 0 : 1).allowsHitTesting(false)
            // everything expanded lives in panel space at its FINAL geometry,
            // centred so it never moves — the animating clip reveals it,
            // nothing slides. (Its morph-space position varies with shapeW
            // exactly so its panel-space position stays put.)
            expandedLayer
                .opacity(expanded ? 1 : 0)
                .position(x: shapeW / 2, y: panelH / 2 - shapeTop)
            islandContent
                .opacity(expanded ? 0 : 1)
                .frame(width: shapeW, height: shapeH)
        }
        .frame(width: shapeW, height: shapeH)
        .clipShape(shape) // nothing may draw outside the island/toolbar shape
        .glassEffect(ownBar ? .identity : .clear.tint(.black.opacity(0.35)).interactive(), in: shape)
        .glassEffectID("pill", in: ns)
        .contentShape(shape)
        .padding(.top, shapeTop)
        .animation(.spring(duration: 0.35), value: expanded)
    }

    // island contents, Dynamic-Island-style: one leading item concentric with
    // the rounded end cap (its centre pillH/2 from the edge). Frozen: the
    // current Tool's icon only. Recording: red dot leading, elapsed trailing.
    // Annotations on the desktop: the Markup badge leading, their count
    // trailing — the count island stays on every display until they're cleared.
    // island: items sit concentric with the end caps; notch: centred in the ears
    // Non-notch: the leading round item's centre sits pillH/2 from the end —
    // concentric with the end cap — and the trailing item's edge mirrors the
    // leading item's edge inset (the 8 pt dot's edge is pillH/2 - 4 in).
    var islandSlot: CGFloat { hasNotch ? earW : pillH }
    var islandContent: some View {
        HStack(spacing: 0) {
            if recording {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .frame(width: islandSlot, height: pillH)
            } else {
                // nothing selected (the count island, or the live toolbar
                // unarmed): the Markup group's badge
                Image(systemName: s.tool?.symbol ?? Tool.Kind.markup.badge)
                    .resizable().scaledToFit()
                    .frame(width: min(pillH * 0.45, pillH - 14), height: min(pillH * 0.45, pillH - 14))
                    // on the glyph's own frame, so size and position both travel
                    .matchedGeometryEffect(id: "selectedIcon", in: ns, isSource: !expanded)
                    .frame(width: islandSlot, height: pillH)
            }
            Spacer(minLength: 0)
            if recording || annotationCount != nil {
                // the time/count must never touch the cap or the notch: measure
                // it and inset its edge like the leading dot's, shrinking the
                // inset only as far as the glyph itself needs
                Group {
                    if recording { Text(fmtT(s.recordingElapsed)) }
                    else {
                        let n = annotationCount ?? 0
                        Text("\(n)").accessibilityLabel(n == 1 ? "1 Annotation" : "\(n) Annotations")
                    }
                }
                .font(.system(size: 12)).monospacedDigit()
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { islandTimeW = $0 }
                .padding(.trailing, max(4, min((islandSlot - 8) / 2, islandSlot - islandTimeW - 4)))
                .frame(height: pillH)
            }
        }
        .foregroundStyle(.white)
        .frame(width: islandW, height: pillH)
    }

    /// where the expanded content's top sits in panel space (final geometry)
    var expTop: CGFloat { hasNotch ? gap : islandH }
    /// the expanded bar + row at their final positions in panel coords —
    /// one layout, revealed by the animating shape rather than re-laid-out
    var expandedLayer: some View {
        ZStack {
            #if CLEAR_GLASS_PATCH
            // while frozen the bar is our own surface — the same view the
            // lens bends — so inside the lens reads like outside
            if lensBg != nil, !recording { barSurface }
            #endif
            expandedContent
                .frame(width: expW, height: expH, alignment: .top)
                .position(x: panelW / 2, y: expTop + expH / 2)
        }
        .frame(width: panelW, height: panelH)
    }

    @ViewBuilder var expandedContent: some View {
        if recording { recControls } else { toolRow }
    }

    @State var recRowSize = CGSize(width: 220, height: 64)
    @State var islandTimeW: CGFloat = 20 // measured "mm:ss" glyph width
    var recControls: some View {
        RecControlsView(displayIndex: displayIndex, ctrl: ctrl,
                        screenRect: { ctrl.panelScreenRect($0, on: displayIndex) })
            .padding(.top, contentTop)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { recRowSize = $0 }
    }

    let toolD: CGFloat = 72
    let compactD: CGFloat = 44 // More's button: an icon, no label
    func cellW(_ t: Tool) -> CGFloat { t == .moreMarkup ? compactD : toolD }
    /// More's look: an ellipsis in a circle, no label — shared by cell() and
    /// iconCell() so the lens strip lines up
    var moreButton: some View {
        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(Circle().fill(.white.opacity(s.openMenu == .moreMarkup ? 0.22 : 0.12)))
            .frame(width: compactD, height: selH)
            .accessibilityLabel(Tool.moreMarkup.title)
    }
    let cellGap: CGFloat = 8 // rowContent's spacing = cell pitch − toolD
    let selW: CGFloat = 92, selH: CGFloat = 64 // rest capsule size
    // the capsule overhangs its cell by (selW − toolD)/2 on each side; the
    // dividers pad past that so they never touch the highlight
    let sepMargin: CGFloat = 6
    // pressed lens: 4 pt past the bar's edges so the bar's own edge falls
    // inside it and gets refracted (iOS tab-bar lens); the mask follows it
    let lensOverhang: CGFloat = 4
    let lensIconBoost: CGFloat = 0.15 // icons seen through the lens are this much bigger
    var lensW: CGFloat { selW * (selH + 2 * d + 2 * lensOverhang) / selH }
    var lensH: CGFloat { selH + 2 * d + 2 * lensOverhang }
    var lensSize: CGSize { lensActive ? CGSize(width: lensW, height: lensH) : CGSize(width: selW, height: selH) }
    // tab-bar state: cell centres measured in row space, capsule centre same
    @State var cellCentres: [Tool: CGPoint] = [:]
    @State var blobX: CGFloat = 0
    @State var blobY: CGFloat = 0
    @State var pressing = false   // finger down, before/without the drag threshold
    @State var dragging = false
    @State var travelling = false // a tap's spring trip to the new Tool, press-free
    @State var travelStart = Date()
    /// one group open at a time; the rest collapse to their last-used Tool
    @State var openGroup: Tool.Kind = .shot
    @State var lastUsed: [Tool.Kind: Tool] = [:]
    /// One spring sim owns the lens: position chases lensTarget, velocity
    /// drives the stretch — no gesture-event velocity, no debounce.
    @State var lensVel = CGPoint.zero
    @State var lensTarget = CGPoint.zero
    @State var lensMoving = false
    @State var lensRunning = false
    @State var stretchX: CGFloat = 1
    @State var stretchY: CGFloat = 1
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @State var pressX: CGFloat = 0
    @State var pressTool: Tool?
    @State var pressActive = false
    @State var menuByHold = false
    @State var holdTask: Task<Void, Never>?
    @State var hoverInside = false
    var lensActive: Bool { pressing || dragging || travelling }
    /// with the clear-glass patch the Metal lens layer owns the pressed look —
    /// the in-row accent/cut-out lens pieces must not draw under it
    var shaderLensActive: Bool {
        #if CLEAR_GLASS_PATCH
        return lensActive
        #else
        return false
        #endif
    }
    /// the pre-patch in-row lens: glass + accent mask + cut-outs, only while
    /// pressing. With the shader patch nothing in-row draws for the lens
    var usesInRowLens: Bool {
        #if CLEAR_GLASS_PATCH
        return false
        #else
        return lensActive
        #endif
    }
    /// frozen + expanded: our barSurface draws the bar; system glass off
    var ownBar: Bool {
        #if CLEAR_GLASS_PATCH
        return expanded && lensBg != nil && !recording
        #else
        return false
        #endif
    }

    /// row-space centre the lens rests on
    var rowCentreY: CGFloat { selH / 2 }
    /// no spring: put the whole lens model on the cell instantly — used
    /// on expand and passive tool changes, inside a disabled-animation
    /// transaction so the morph's own transaction can't animate it either
    func snapLens(to c: CGPoint) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            blobX = c.x; blobY = c.y
            lensTarget = c; lensVel = .zero; lensMoving = false
            stretchX = 1; stretchY = 1
        }
    }
    /// aim the spring: press picks the pressed cell, drag follows the
    /// pointer (x clamped to the row's ends, y pulled gently toward it)
    func setLensTarget(x: CGFloat, pointerY: CGFloat? = nil) {
        var y = rowCentreY
        if let py = pointerY { y += 6 * tanh((py - rowCentreY) / 30) } // lean toward the cursor, ≤ 6 pt
        lensTarget = CGPoint(x: x, y: y)
        if reduceMotion { blobX = x; blobY = y; lensVel = .zero }
        else { lensMoving = true; kickLens() }
    }

    /// the spring's driver: a task loop that runs only while unsettled —
    /// (TimelineView never delivered ticks inside the overlay)
    func kickLens() {
        guard !lensRunning else { return }
        lensRunning = true
        Task { @MainActor in
            var last = Date()
            while lensMoving {
                try? await Task.sleep(for: .milliseconds(8))
                if Task.isCancelled { break }
                let now = Date()
                stepLens(dt: min(now.timeIntervalSince(last), 0.05))
                last = now
            }
            lensRunning = false
        }
    }

    /// fixed-substep underdamped spring — k 380 / c 26
    func stepLens(dt dt0: TimeInterval) {
        if reduceMotion { blobX = lensTarget.x; blobY = lensTarget.y; lensVel = .zero; lensMoving = false; return }
        var p = CGPoint(x: blobX, y: blobY), v = lensVel
        var dt = dt0
        let k: CGFloat = 380, c: CGFloat = 26
        while dt > 0 {
            let h = min(dt, 1.0 / 240)
            v.x += (k * (lensTarget.x - p.x) - c * v.x) * h
            v.y += (k * (lensTarget.y - p.y) - c * v.y) * h
            p.x += v.x * h; p.y += v.y * h
            dt -= h
        }
        // a hard flick could overshoot past the panel; cap it at the ends
        let (lo, hi) = rowEnds
        if hi > lo, p.x < lo - lensOvershootCap || p.x > hi + lensOvershootCap {
            p.x = min(max(p.x, lo - lensOvershootCap), hi + lensOvershootCap); v.x = 0
        }
        blobX = p.x; blobY = p.y; lensVel = v
        // squash/stretch from the sim's own velocity, low-passed; below
        // 120 pt/s nothing stretches, overshoot does the settle wobble
        let raw = 1 + min(max((abs(v.x) - 120) / 1400, 0), 0.3)
        stretchX += (raw - stretchX) * 0.3
        stretchY = 1 - 0.5 * (stretchX - 1)
        lensMoving = abs(v.x) + abs(v.y) > 4
            || abs(lensTarget.x - p.x) + abs(lensTarget.y - p.y) > 0.5
        if !lensMoving { stretchX = 1; stretchY = 1; lensVel = .zero
            // a tap's travel ends when the spring lands
            if travelling { AppLog.line("travel settled \(Int(Date().timeIntervalSince(travelStart) * 1000)) ms"); travelling = false } }
    }

    /// a tap's Tool switch: the lens stays up and the spring carries it to the
    /// new cell (the "set transition"); it fades to the rest highlight on land
    func travelTap(_ t: Tool) {
        travelling = true; travelStart = .now
        AppLog.line("travel -> \(t.title)")
        AppDelegate.shared?.trigger(t)
        if let c = cellCentres[t] { setLensTarget(x: c.x) }
        if reduceMotion { travelling = false } // the jump already landed
    }

    func openToolMenu(_ t: Tool) {
        guard t.hasMenu, !toolDisabled(t) else { return }
        TipPanel.hide()
        if s.tool != t, !t.isAction { AppDelegate.shared?.trigger(t) }
        s.openMenu = s.openMenu == t ? nil : t
        ctrl.syncMenu()
    }
    struct RowSlot { let tool: Tool; let collapsed: Bool }
    func groupTools(_ k: Tool.Kind) -> [Tool] {
        // Markup lays out by use: pinned, ranked slots, the overflow under More,
        // then Clear — every other group is simply all its Tools
        k == .markup ? MarkupToolbar.shared.visible + MarkupToolbar.shared.overflow + [.moreMarkup, .clearAnnotations]
                     : Tool.allCases.filter { $0.kind == k }
    }
    /// whether an open group shows the cell: the Markup group's overflow Tools
    /// render (stable identity) but take no room, and More itself hides while
    /// the overflow is empty
    func inRow(_ t: Tool) -> Bool {
        if MarkupToolbar.shared.overflow.contains(t) { return false }
        return t != .moreMarkup || !MarkupToolbar.shared.overflow.isEmpty
    }
    /// a collapsed group's representative: its last-used Tool — the selected
    /// Tool's group always shows the selection
    func lastUsedTool(_ k: Tool.Kind) -> Tool {
        if let t = s.tool, t.kind == k { return t }
        return lastUsed[k] ?? groupTools(k)[0]
    }
    func slots(in k: Tool.Kind) -> [RowSlot] {
        k == openGroup ? groupTools(k).filter(inRow).map { RowSlot(tool: $0, collapsed: false) }
                       : [RowSlot(tool: lastUsedTool(k), collapsed: true)]
    }
    var visibleTools: Set<Tool> { Set(Tool.Kind.allCases.flatMap { slots(in: $0).map(\.tool) }) }
    /// open a group — the same centred spring as hover; the lens retargets
    /// onto the pointer's position in the new layout, so no jump
    func openTheGroup(_ k: Tool.Kind) {
        guard k != openGroup, !(s.recActive && k == .rec) else { return }
        AppLog.line("openTheGroup \(k)")
        if reduceMotion { // no bouncy layout spring under Reduce Motion
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { openGroup = k }
        } else {
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { openGroup = k }
        }
    }
    /// Record Tools are dead while a Recording runs
    func toolDisabled(_ t: Tool) -> Bool { s.recActive && t.kind == .rec }
    /// the Tool whose visible cell actually contains x — gaps and hidden
    /// stacked cells return nil
    func hitTool(at x: CGFloat) -> Tool? {
        cellCentres.first { visibleTools.contains($0.key) && abs($0.value.x - x) <= cellW($0.key) / 2 }?.key
    }
    /// press and drag targets skip disabled Tools; a gap still snaps to the
    /// nearest live cell
    func nearestTool(to x: CGFloat) -> Tool? {
        cellCentres.filter { visibleTools.contains($0.key) && !toolDisabled($0.key) && !$0.key.isAction }
            .min { abs($0.value.x - x) < abs($1.value.x - x) }?.key
    }
    var rowEnds: (CGFloat, CGFloat) {
        let xs = cellCentres.filter { visibleTools.contains($0.key) }.values.map(\.x)
        return (xs.min() ?? 0, xs.max() ?? 0)
    }
    /// the row laid out once, shared by the real cells, the accent copy and
    /// the lens's icon strip — every copy keeps the same geometry
    func rowContent<V: View>(_ make: @escaping (Tool, Bool) -> V) -> some View {
        HStack(spacing: cellGap) {
            ForEach(Tool.Kind.allCases, id: \.self) { k in
                if k != .shot { // thin divider between groups, clear of the highlight capsule
                    Rectangle().fill(.white.opacity(0.14))
                        .frame(width: 1, height: selH * 0.6)
                        .padding(.horizontal, (selW - toolD) / 2 + sepMargin - cellGap)
                }
                // every group always renders all its Tools (stable identity,
                // no inserts/removals): closed groups give EVERY slot zero
                // width — leading-aligned — so the siblings stack on the rep
                // wherever it sits, and open groups take a cell + gap each.
                // The Markup group's overflow Tools take no room either. The
                // spread is real layout, so the geometry readers
                // (cellCentres, ToolbarBtnFrames) report true positions
                let open = k == openGroup, g = groupTools(k), v = g.filter(inRow)
                HStack(spacing: 0) {
                    ForEach(g, id: \.self) { t in
                        let rep = t == lastUsedTool(k), shown = open ? v.contains(t) : rep
                        make(t, !open && rep)
                            .scaleEffect(shown ? 1 : 0.5)
                            .opacity(shown ? (toolDisabled(t) ? 0.35 : 1) : 0) // a Recording greys the video group
                            .allowsHitTesting(shown)
                            .accessibilityHidden(!shown)
                            .frame(width: open && shown ? cellW(t) + (t != v.last ? cellGap : 0) : 0,
                                   alignment: .leading)
                            .zIndex(rep ? 1 : 0)
                    }
                }
                .frame(width: open ? v.map(cellW).reduce(0, +) + cellGap * CGFloat(max(v.count - 1, 0)) : toolD, alignment: .leading)
            }
        }
        .padding(.horizontal, d + (selW - toolD) / 2)
    }
    // the icon strip once, for the accent-tint mask — same layout as the row
    @ViewBuilder func iconCell(_ t: Tool, collapsed: Bool) -> some View {
        if t == .moreMarkup {
            moreButton
        } else {
        // pixel-identical layout to cell() so the masked splice joins equal:
        // the same 24×24 icon + 10 pt label VStack, the same collapsed badge
        VStack(spacing: 3) {
            Image(systemName: collapsed ? t.kind.badge : t.symbol).resizable().scaledToFit()
                .frame(width: 24, height: 24)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .overlay(alignment: .bottomTrailing) {
                    if collapsed { // the last-used Tool's symbol as the badge
                        Image(systemName: t.symbol).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(.black.opacity(0.85)))
                            .offset(x: 6, y: 4)
                    }
                }
            Text(collapsed ? t.kind.groupTitle : t.shortTitle)
                .font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
                // the menu chevron rides beside the selected Tool's label —
                // trailing overlay so the label itself stays centred
                .overlay(alignment: .trailing) {
                    if !collapsed && s.tool == t && t.hasMenu && !lensActive {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            .offset(x: 11)
                    }
                }
        }
        .frame(width: toolD, height: selH)
        }
    }

    /// pixel-res Freeze Frame crop under the whole toolbar panel — the
    /// layer's stand-in for the world behind the bar
    @State var lensBg: CGImage?
    func syncLensBg() {
        #if CLEAR_GLASS_PATCH
        guard ctrl.showsFrozen, let p = ctrl.toolbarPanels[displayIndex], let sc = screen,
              displayIndex < Freeze.shared.displays.count else { return }
        let local = CGRect(x: p.frame.minX - sc.frame.minX, y: p.frame.minY - sc.frame.minY,
                           width: p.frame.width, height: p.frame.height)
        lensBg = Freeze.shared.crop(rect: local, on: displayIndex)
        #endif
    }
    #if CLEAR_GLASS_PATCH
    /// the lens capsule's centre in panel coords
    var lensCentre: CGPoint {
        CGPoint(x: (panelW - rowSize.width) / 2 + blobX, y: shapeTop + contentTop + blobY)
    }
    /// the lens capsule's centre in row space (for the accent mask)
    var lensCentreInRow: CGPoint {
        CGPoint(x: (shapeW - rowSize.width) / 2 + blobX, y: blobY)
    }
    /// the lens's icon copy — every icon always grown about its own centre;
    /// the copy only shows inside the lens, so the real row never scales
    func iconStrip(_ color: Color) -> some View {
        rowContent { t, collapsed in iconCell(t, collapsed: collapsed).scaleEffect(1 + lensIconBoost) }
            .foregroundStyle(color)
    }
    /// the bar's surface, drawn by us while frozen: the Freeze Frame crop,
    /// edge-lensed by barGlass, lightly frosted, tinted. The SAME view is the
    /// visible bar (masked into morph) and the lens's input — so inside the
    /// lens the bar reads exactly like outside, plus the lens's refraction.
    let notchOverscan: CGFloat = 200
    var barSurface: some View {
        ZStack(alignment: .top) {
            if let img = lensBg {
                // frost first, so the glass shader's edge, fringe and rim stay crisp
                Image(decorative: img, scale: CGFloat(img.width) / panelW)
                    .resizable()
                    .frame(width: panelW, height: panelH)
                    .blur(radius: 5)
            }
        }
        // under a notch the bar hangs from the screen's top edge: extend the
        // glass rect above the panel so the top has no rounded corners,
        // rim or edge bend — only the sides and bottom are glass edges
        .modifier(BarGlassEffect(ctrl: ctrl, di: displayIndex,
                                 rect: CGRect(x: (panelW - shapeW) / 2, y: shapeTop - (hasNotch ? notchOverscan : 0),
                                              width: shapeW, height: shapeH + (hasNotch ? notchOverscan : 0)),
                                 radius: selH / 2 + d, bounds: CGSize(width: panelW, height: panelH)))
        .mask(alignment: .top) {
            shape.frame(width: shapeW, height: shapeH).padding(.top, shapeTop)
        }
        .frame(width: panelW, height: panelH, alignment: .top)
    }

    /// a glass-free copy of what sits under the lens — backdrop views can't
    /// rasterize into layerEffect, so the shader bends this instead
    var lensSource: some View {
        ZStack(alignment: .top) {
            if let img = lensBg {
                // crisp everywhere — the bar copy above frosts what's behind it
                Image(decorative: img, scale: CGFloat(img.width) / panelW)
                    .resizable()
                    .frame(width: panelW, height: panelH)
            }
            barSurface
        }
        .frame(width: panelW, height: panelH, alignment: .top)
    }
    /// lensSource refracted through the shader — all lens drawing runs
    /// through LensEffect so the mask, rim and SDF share the same
    /// interpolated values every frame (shader args don't animate on
    /// their own — the mask would run ahead of them during the springs)
    /// the icons, kept out of the shader so they read like the real row —
    /// grown about their own centres in this copy only, so a Tool swells as
    /// it passes into the lens. Same panel-space spot it had in lensSource.
    var lensIcons: some View {
        ZStack {
            iconStrip(.white)
            iconStrip(Color.wadjetAccent)
                .mask(Capsule().frame(width: lensW, height: lensH)
                      .scaleEffect(x: stretchX, y: stretchY)
                      .position(lensCentreInRow))
        }
        .frame(width: shapeW, height: shapeH, alignment: .top)
        .padding(.top, shapeTop + contentTop)
        .frame(width: panelW, height: panelH, alignment: .top)
    }
    var lensLayer: some View {
        lensSource
            .modifier(LensEffect(ctrl: ctrl, di: displayIndex, icons: lensIcons, bounds: CGSize(width: panelW, height: panelH), centre: lensCentre, size: lensSize,
                                 stretch: CGSize(width: stretchX, height: stretchY)))
            .opacity(lensActive ? 1 : 0)
            .animation(.smooth(duration: 0.15), value: lensActive)
            .allowsHitTesting(false)
    }
    #endif

    var selShape: some View {
        Capsule()
            .frame(width: lensSize.width, height: lensSize.height)
            .scaleEffect(x: stretchX, y: stretchY) // with the lens, never against it
    }

    func lens(_ glass: Glass) -> some View {
        Capsule().fill(.clear)
            .frame(width: lensSize.width, height: lensSize.height)
            .glassEffect(lensActive ? glass : .identity, in: .capsule)
            .glassEffectTransition(.materialize)
            .scaleEffect(x: stretchX, y: stretchY) // stretches the glass output too
            .position(x: blobX, y: blobY)
            .allowsHitTesting(false)
    }

    // one cell of the tab bar: plain white icon (accent on the selected cell
    // at rest); a collapsed cell carries its group's badge
    func cell(_ t: Tool, collapsed: Bool) -> some View {
        let selected = s.tool == t
        let c = cellCentres[t] ?? .zero
        // a collapsed group's cell IS the group: category icon at Tool size,
        // the last-used Tool's symbol as the tiny badge
        return VStack(spacing: 3) {
            if t == .moreMarkup {
                // the rest of cell()'s modifier chain (mask, RightClickCatcher,
                // geometry) still applies to More
                moreButton
            } else {
            Image(systemName: collapsed ? t.kind.badge : t.symbol).resizable().scaledToFit()
                .frame(width: 24, height: 24)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                // the selected cell's icon and the island's icon are one element:
                // it travels into the bar (and back) as the shape morphs
                .matchedGeometryEffect(id: selected ? "selectedIcon" : "icon-\(t)", in: ns, isSource: expanded)
                .overlay(alignment: .bottomTrailing) {
                    if collapsed { // the last-used Tool's symbol as the badge
                        Image(systemName: t.symbol).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(.black.opacity(0.85)))
                            .offset(x: 6, y: 4)
                    }
                }
            Text(collapsed ? t.kind.groupTitle : t.shortTitle)
                .font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
                // the menu chevron rides beside the selected Tool's label —
                // trailing overlay so the label itself stays centred
                .overlay(alignment: .trailing) {
                    if !collapsed && s.tool == t && t.hasMenu && !lensActive {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                            .offset(x: 11)
                    }
                }
            }
        }
        .foregroundStyle(selected && !lensActive ? Color.wadjetAccent : .white)
            .frame(width: cellW(t), height: selH)
            // the rest highlight rides the selected cell, so group reflows
            // carry it with layout instead of chasing it in row space
            .background {
                if selected, !lensActive {
                    Capsule().fill(.white.opacity(0.10))
                        .frame(width: selW, height: selH)
                }
            }
            .contentShape(Rectangle()) // whole cell, not just the glyph
            .mask {
                ZStack {
                    Rectangle()
                    selShape.opacity(usesInRowLens ? 1 : 0)
                        .transaction { $0.animation = nil }
                        .offset(x: blobX - c.x, y: blobY - c.y).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .overlay(RightClickCatcher { openToolMenu(t) })
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named("row")).origin } action: {
                // keep the whole frame's centre in row space
                cellCentres[t] = CGPoint(x: $0.x + cellW(t) / 2, y: $0.y + selH / 2)
                if !lensActive, s.tool == t { snapLens(to: CGPoint(x: $0.x + cellW(t) / 2, y: $0.y + selH / 2)) }
                // a tap's travel follows its Tool if a group reflow moves it mid-flight
                else if travelling, !dragging, !pressing, s.tool == t { setLensTarget(x: $0.x + cellW(t) / 2) }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { f in
                ToolbarBtnFrames.rects[displayIndex, default: [:]][t] = f
            }
    }

    var toolRow: some View {
        // rest highlight sits below the icons in .background; the glass lens
        // goes on top with the clear-glass patch (it must refract the icons)
        // and behind them without it
        rowContent(cell)
        .coordinateSpace(name: "row")
        // the accent tint follows the lens, clipped to its shape — the icon row
        // is drawn a second time in accent, masked to a capsule at blobX.
        // Only while the in-row lens draws: at rest the selected cell's own
        // icon carries the accent
        .overlay {
            rowContent(iconCell)
                .mask(selShape.opacity(usesInRowLens ? 1 : 0)
                    .position(x: blobX, y: blobY)
                    .transaction { $0.animation = nil })
                .foregroundStyle(Color.wadjetAccent)
                .allowsHitTesting(false)
        }
        // the glass lens: identity glass at rest, glass while pressing —
        // animating the effect, never inserted. With the clear-glass patch it
        // sits on top and refracts the icons; without it, glass would blur and
        // tint them, so regular glass sits behind the icons instead
        // With the patch the lens also lives outside the bar's clip (see
        // morph) so it can overhang; without it the lens stays behind the
        // icons and clipped to the shape.
        #if !CLEAR_GLASS_PATCH
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
                    pressActive = true
                    // a press takes the lens over from a tap's travel: keep the
                    // lens where it is mid-flight, don't snap back to selected
                    let wasTravelling = travelling; travelling = false
                    pressX = v.startLocation.x
                    // the real cell under the finger (gaps pick the nearest
                    // cell); a greyed Record cell swallows the press entirely
                    pressTool = hitTool(at: v.startLocation.x) ?? nearestTool(to: v.startLocation.x)
                    if let pt = pressTool, toolDisabled(pt) || pt.isAction { pressTool = nil }
                    // the lens only pops for an actual switch — a press on the
                    // selected Tool (its menu tap) shows none; a travel in
                    // flight keeps it up so it can't vanish mid-flight
                    pressing = wasTravelling || (pressTool != nil && pressTool != s.tool)
                    // start the sim exactly where the rest highlight was —
                    // unless it's still travelling from the last tap
                    if !wasTravelling, let sel = s.tool, let sc = cellCentres[sel] { snapLens(to: sc) }
                    // the spring carries the lens to the pressed cell
                    if let t = pressTool, let c = cellCentres[t], c.x != blobX {
                        setLensTarget(x: c.x)
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
                    setLensTarget(x: min(hi, max(lo, v.location.x)), pointerY: v.location.y)
                    // hover callbacks don't fire mid-drag — open the group
                    // under the lens ourselves, anchored on that cell
                    if let t = nearestTool(to: v.location.x) { openTheGroup(t.kind) }
                }
            }
            .onEnded { v in
                holdTask?.cancel()
                let wasDragging = dragging
                pressing = false; dragging = false
                // hover events may not have arrived during the drag — refresh
                // before lensActive falls, so releasing outside collapses
                hoverInside = pointerInside()
                let under = hitTool(at: v.location.x)
                if let u = under, toolDisabled(u) {
                    // dropped on a greyed Record cell: the lens goes home
                    if let c = cellCentres[s.tool ?? .capRegion] { setLensTarget(x: c.x) }
                } else if wasDragging {
                    if let n = nearestTool(to: v.location.x) {
                        if n != s.tool { AppDelegate.shared?.trigger(n) }
                        // the spring carries it home — overshoot is the wobble
                        if let c = cellCentres[n] { setLensTarget(x: c.x) }
                    }
                } else if !menuByHold, let t = hitTool(at: v.location.x) ?? nearestTool(to: v.location.x) {
                    if t.isAction { t.hasMenu ? openToolMenu(t) : AppDelegate.shared?.trigger(t) }
                    else if t != s.tool {
                        travelTap(t) // the lens travels all the way there
                    } else if t.hasMenu { openToolMenu(t) } // tap the selected Tool: menu
                }
                pressTool = nil; pressActive = false; menuByHold = false
            })
        // map the pointer to a Tool cell using measured frames
        .onContinuousHover(coordinateSpace: .named("panel")) { phase in
            switch phase {
            case .active(let p):
                NSCursor.arrow.set()
                ctrl.markOverlaysDirty() // loupe off while over the bar
                if dragging { TipPanel.hide() }
                else if let t = (ToolbarBtnFrames.rects[displayIndex] ?? [:]).first(where: { visibleTools.contains($0.key) && $0.value.contains(p) })?.key {
                    openTheGroup(t.kind) // groups open under the pointer
                } else { TipPanel.hide() }
            case .ended:
                TipPanel.hide()
                ctrl.markOverlaysDirty() // loupe back on the Freeze Frame
            }
        }
        .onChange(of: s.tool) {
            if let t = s.tool { lastUsed[t.kind] = t }
            // only an active lens interaction goes through the spring;
            // a passive switch snaps
            if dragging || travelling { if let c = cellCentres[s.tool ?? .capRegion] { setLensTarget(x: c.x) } }
            else if let c = cellCentres[s.tool ?? .capRegion] { snapLens(to: c) }
            // the selected Tool's group is the default open one; a collapsed
            // group's click opens it
            if !lensActive { openTheGroup(restingGroup) }
        }
        .padding(.top, contentTop)

    }
}

#if CLEAR_GLASS_PATCH
/// The pressed-lens effect as one animatable unit: shader, capsule mask and
/// glass body/rim all read the same interpolated centre/size/stretch.
/// barGlass with the pointer as its light — observing PointerLight here (a
/// tiny modifier) keeps ToolbarView's body from re-rendering per mouse move
struct BarGlassEffect: ViewModifier {
    let ctrl: OverlayController
    let di: Int
    var rect: CGRect
    var radius: CGFloat
    var bounds: CGSize
    @ObservedObject var light = PointerLight.shared
    func body(content: Content) -> some View {
        let lp = ctrl.lightPoint(in: ctrl.toolbarPanels[di], height: bounds.height,
                                 above: CGPoint(x: rect.midX, y: rect.midY))
        content.layerEffect(
            ShaderLibrary.barGlass(.float2(rect.minX, rect.minY), .float2(rect.width, rect.height),
                                   .float(radius), .float2(bounds.width, bounds.height),
                                   .float2(Float(lp.x), Float(lp.y)),
                                   .float(Float(1 / (ctrl.toolbarPanels[di]?.backingScaleFactor ?? 2)))),
            maxSampleOffset: CGSize(width: 32, height: 32))
    }
}

struct LensEffect<Icons: View>: ViewModifier, @preconcurrency Animatable {
    let ctrl: OverlayController
    let di: Int
    let icons: Icons // rides above the refraction, inside the same mask
    @ObservedObject var light = PointerLight.shared
    var bounds: CGSize = .zero // the source layer's size; samples clamp to it
    var centre: CGPoint
    var size: CGSize
    var stretch: CGSize
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                      AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                                      AnimatablePair<CGFloat, CGFloat>>> {
        get { .init(.init(centre.x, centre.y),
                    .init(.init(size.width, size.height), .init(stretch.width, stretch.height))) }
        set {
            centre = CGPoint(x: newValue.first.first, y: newValue.first.second)
            size = CGSize(width: newValue.second.first.first, height: newValue.second.first.second)
            stretch = CGSize(width: newValue.second.second.first, height: newValue.second.second.second)
        }
    }
    func body(content: Content) -> some View {
        content
            .layerEffect(
                ShaderLibrary.lens(.float2(centre.x, centre.y),
                                   .float2(size.width, size.height),
                                   .float2(stretch.width, stretch.height),
                                   .float2(bounds.width, bounds.height),
                                   {
                                       let lp = ctrl.lightPoint(in: ctrl.toolbarPanels[di], height: bounds.height, above: centre)
                                       return .float2(Float(lp.x), Float(lp.y))
                                   }(),
                                   .float(Float(1 / (ctrl.toolbarPanels[di]?.backingScaleFactor ?? 2)))),
                maxSampleOffset: CGSize(width: 64, height: 64))
            .overlay { icons }
            .mask {
                Capsule().frame(width: size.width + 2, height: size.height + 2)
                    .scaleEffect(x: stretch.width, y: stretch.height)
                    .position(centre)
            }
    }
}
#endif

/// the recording controls row — shared by the recording island's expansion
/// and the detached recording bubble: dot + time, Pause, Stop
struct RecControlsView: View {
    let displayIndex: Int
    let ctrl: OverlayController
    /// the button's frame in its panel, converted to screen coords
    let screenRect: (CGRect) -> CGRect?
    @ObservedObject var s = AppState.shared
    var body: some View {
        // leading: the same red dot + time as the island; trailing: pause and
        // stop as glass circles, all centred in the selH-tall row
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(fmtT(s.recordingElapsed)).font(.system(size: 14)).monospacedDigit().fixedSize()
            }
            Spacer(minLength: 0)
            recButton(s.recordingPaused ? "play.fill" : "pause.fill",
                      label: s.recordingPaused ? "Resume" : "Pause") { AppDelegate.shared?.togglePause() }
            recButton("stop.fill", label: "Stop") { AppDelegate.shared?.stopRecording() }
        }
        .foregroundStyle(.white)
        // the outer circles' edges sit so their centres meet the corner
        // centres (radius 32 + 10) — concentric, like the tool capsule
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // one recording control: a glass circle, TipPanel tooltip on hover
    func recButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18))
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: {
            ToolbarBtnFrames.recRects[displayIndex, default: [:]][label] = $0
        }
        .onContinuousHover(coordinateSpace: .named("panel")) { phase in
            switch phase {
            case .active:
                // the button's own frame, not a box around the pointer
                if let r = ToolbarBtnFrames.recRects[displayIndex]?[label] {
                    TipPanel.hover(label, anchor: screenRect(r) ?? .zero)
                }
            case .ended:
                TipPanel.hide()
            }
        }
    }
}

/// the detached recording bubble: a black capsule with the dot + time that
/// springs out of the island's right edge when a Freeze Frame opens mid-
/// Recording. Its own small panel sits 8 pt right of the island/toolbar
/// shape, so it slides outward as the bar expands. Hover expands it into the
/// full recording controls — unless this display's bar is already expanded.
struct RecBubbleView: View {
    let displayIndex: Int
    let ctrl: OverlayController
    @ObservedObject var s = AppState.shared
    @State var hovering = false
    @State var emerged = false
    var expanded: Bool { hovering && s.expandedDisplay != displayIndex }
    var body: some View {
        ZStack(alignment: .leading) {
            if expanded {
                RecControlsView(displayIndex: displayIndex, ctrl: ctrl,
                                screenRect: { ctrl.bubbleScreenRect($0, on: displayIndex) })
            } else {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(fmtT(s.recordingElapsed)).font(.system(size: 12)).monospacedDigit()
                }
                .padding(.horizontal, 12).frame(height: ctrl.islandPill(on: displayIndex)?.h ?? 28)
            }
        }
        .foregroundStyle(.white).fixedSize()
        .background(Capsule().fill(.black))
        .contentShape(Capsule())
        .scaleEffect(emerged ? 1 : 0.6, anchor: .leading) // buds off the island's edge
        .opacity(emerged ? 1 : 0)
        .onAppear {
            s.bubblesDying = false
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { emerged = true }
        }
        .onChange(of: s.bubblesDying) { _, dying in
            if dying { withAnimation(.spring(duration: 0.3)) { emerged = false } }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true
            case .ended: hovering = false
            }
        }
        .onChange(of: hovering) { ctrl.markOverlaysDirty() }
        .onChange(of: expanded) { ctrl.bubbleExpanded[displayIndex] = expanded }
        .onAppear { ctrl.bubbleExpanded[displayIndex] = expanded }
        .animation(.spring(duration: 0.3), value: expanded)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { ctrl.layoutBubble(on: displayIndex, size: $0) }
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
    static var current: String?
    static var tipSize = CGSize.zero
    static var anchor = CGRect.zero
    /// centred under the anchor (a Tool cell or control), just below the
    /// bar's edge — the cell sits `belowCell` points above it — kept on screen
    static let belowCell: CGFloat = 10 + 6
    static func tipOrigin(_ size: CGSize) -> CGPoint {
        var o = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - belowCell - size.height)
        if let scr = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            o.x = min(max(scr.frame.minX + 4, o.x), scr.frame.maxX - size.width - 4)
        }
        return o
    }
    /// immediate — no hover delay; `anchor` kept for the call sites' sake
    /// (recording controls, the manual-confirm button — Tools have labels now)
    static func hover(_ label: String, anchor: CGRect) {
        show(label, anchor: anchor)
    }
    static func show(_ label: String, anchor a: CGRect) {
        anchor = a
        // same label: just re-anchor
        if let p = panel, current == label { p.setFrameOrigin(tipOrigin(tipSize)); return }
        panel?.close()
        let h = NSHostingView(rootView: Text(label).font(.system(size: 11)).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.black.opacity(0.85), in: .rect(cornerRadius: 6)))
        h.frame.size = h.fittingSize
        tipSize = h.fittingSize; current = label
        let f = NSRect(origin: tipOrigin(h.fittingSize), size: h.fittingSize)
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver + 3; p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces]; p.ignoresMouseEvents = true
        p.contentView = h; p.orderFront(nil); panel = p
        AppLog.line("tip \(label) at \(Int(f.origin.x)),\(Int(f.origin.y))")
    }
    static func hide() { task?.cancel(); task = nil; current = nil; panel?.close(); panel = nil }
}

/// the menu's pointer-lit rim — system glass can't move its highlight, so a
/// radial stroke follows the pointer instead. The only PointerLight observer
/// in the menu.
struct MenuRimLight: View {
    let ctrl: OverlayController
    @ObservedObject var light = PointerLight.shared
    var body: some View {
        GeometryReader { g in
            if let sc = light.screen, let mp = ctrl.menuPanel, let cv = mp.contentView {
                let v = mp.convertPoint(fromScreen: sc)
                let gf = g.frame(in: .global)
                let local = CGPoint(x: v.x - gf.minX, y: cv.frame.height - v.y - gf.minY)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(RadialGradient(colors: [.white.opacity(0.45), .clear],
                        center: UnitPoint(x: local.x / max(g.size.width, 1),
                                          y: local.y / max(g.size.height, 1)),
                        startRadius: 0, endRadius: 180), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// a Tool's dropdown menu: its own dark panel under the button. Radio rows
// close it; toggles leave it open.
struct ToolMenuView: View {
    let tool: Tool
    let ctrl: OverlayController
    var backdrop: CGImage? = nil // Freeze Frame crop under the menu body
    /// the Editor's menus drop the screen-only Markup group settings
    var editor = false
    @ObservedObject var s = AppState.shared
    @State var shown = false // spring in from the cell it hangs under
    /// the menu's rows — scrolled when they outgrow the space under the top edge
    @ViewBuilder var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tool.kind {
            // what goes in → how it starts → what happens after
            case .shot:
                tileRow(shotTiles)
                if tool == .capRegion { section("Start") { confirmRow() } }
                section("Workflow") { workflowRows() }
            case .rec:
                tileRow(recTiles)
                section("Start") {
                    if tool == .recRegion { confirmRow() }
                    countdownRows()
                }
                section("Workflow") { workflowRows() }
            case .util where tool == .pickColour:
                colourRows([.hex, .rgb, .hsl, .oklch, .lab])
                section("Code") { colourRows([.swiftUI]) }
            case .util where tool == .measure:
                tileRow(measureTiles)
            case .markup where tool == .moreMarkup:
                overflowRows()
            case .markup:
                if tool == .shapes { ShapeVariantControls(ctrl: ctrl) }
                if tool == .counter { CounterControls(ctrl: ctrl) }
                if tool == .censor { CensorControls(ctrl: ctrl) } else { MarkupStyleControls(tool: tool, ctrl: ctrl) }
                if tool == .shapes { ShapePaintControls(tool: tool, ctrl: ctrl) }
                selectionRows()
                if tool == .select, !editor { markupGroupRows() }
            default: EmptyView()
            }
        }
    }

    var body: some View {
        Group {
            if let h = s.menuScrollHeight {
                ScrollView(.vertical) { rows.padding(Self.inset) }
                    .frame(height: h)
            } else {
                rows.padding(Self.inset)
            }
        }
        .frame(width: 280)
        // row and tile highlights take ConcentricRectangle from this, so
        // their corners nest inside the menu's
        .containerShape(Self.shape)
        // heavy frost like the reference menu: the frozen world behind, hard
        // blurred and darkened, under the glass's rim and highlight. The crop
        // is the whole column under the menu body, drawn at its natural size
        // top-aligned — a taller menu reveals more of it, aligned with the scene
        .background {
            if let backdrop {
                ZStack {
                    Image(decorative: backdrop, scale: CGFloat(backdrop.width) / 280)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top) // min 0: take the body's size, not the column's
                        .blur(radius: 24, opaque: true)
                    Color.black.opacity(0.28)
                }
                .clipShape(Self.shape)
            }
        }
        .overlay { MenuRimLight(ctrl: ctrl) }
        .glassEffect(.regular, in: Self.shape)
        .scaleEffect(shown ? 1 : 0.85, anchor: .top)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { shown = true } }
    }

    func row(_ title: String, subtitle: String? = nil, icon: String, on: Bool, isToggle: Bool = false, action: @escaping () -> Void) -> some View {
        MenuRow(title: title, subtitle: subtitle, icon: icon, on: on, isToggle: isToggle) {
            action()
            s.openMenu = nil; ctrl.syncMenu()
        }
    }
    static let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    /// one inset on every side, so the concentric corners stay even
    static let inset: CGFloat = 6
    /// tiles in groups, a hairline between groups
    func tileRow(_ groups: [[MenuTile]]) -> some View {
        HStack(spacing: 0) {
            ForEach(groups.indices, id: \.self) { i in
                if i > 0 { Rectangle().fill(.white.opacity(0.15)).frame(width: 0.5, height: 36) }
                ForEach(groups[i], id: \.caption) { $0 }
            }
        }
    }
    func divider() -> some View {
        Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
            .padding(.horizontal, 20).padding(.vertical, 3)
    }
    /// a titled group of rows under a divider, like a native menu section
    func section(_ title: String, @ViewBuilder _ rows: () -> some View) -> some View {
        Group {
            divider()
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            rows()
        }
    }
    func colourRows(_ formats: [ColourFormat]) -> some View {
        ForEach(formats, id: \.self) { f in
            row(f.rawValue, icon: f == .hex ? "number" : f == .swiftUI ? "swift" : "function", on: f.rawValue == s.colourFmt) { s.colourFmt = f.rawValue }
        }
    }
    /// Workflow radio rows, subtitled with each Workflow's Steps
    @ViewBuilder func workflowRows() -> some View {
        ForEach(s.workflows(for: tool), id: \.self) { w in
            let wf = s.config.value.workflows.first { $0.name == w }
            row(w, subtitle: wf?.steps.map(\.title).joined(separator: " · "),
                icon: wf?.takes == .screenshot ? "photo" : wf?.takes == .mp4 ? "film" : "photo.stack",
                on: w == s.workflowFor(tool)) {
                s.workflowByTool[tool] = w; s.triggerWorkflow = nil // a menu pick wins over the Shortcut's
            }
        }
    }
    func confirmRow() -> some View {
        // a two-state pick, so it closes the menu like the other rows
        row("Confirm on Release", icon: "hand.tap", on: s.confirmMode == "release", isToggle: true) {
            s.confirmMode = s.confirmMode == "release" ? "manual" : "release"
        }
    }
    /// the Screenshot options — they swap the frozen image live and keep the
    /// menu open
    var shotTiles: [[MenuTile]] {
        [[
            MenuTile(icon: "cursorarrow", caption: "Cursor", on: s.shotCursor, isToggle: true) { s.shotCursor.toggle() },
            MenuTile(icon: "eye", caption: "Wadjet", on: s.shotWadjet, isToggle: true) { s.shotWadjet.toggle() },
        ]]
    }
    /// the recording options as tiles, like the reference's top icon row —
    /// picture, then sound. They keep the menu open
    var recTiles: [[MenuTile]] {
        [[
            MenuTile(icon: "cursorarrow", caption: "Cursor", on: s.cursor, isToggle: true) { s.cursor.toggle() },
            MenuTile(icon: "cursorarrow.click.2", caption: "Clicks", on: s.clickCircles, isToggle: true) { s.clickCircles.toggle() },
            MenuTile(icon: "eye", caption: "Wadjet", on: s.showIslandWhileRecording, isToggle: true) { s.showIslandWhileRecording.toggle() },
        ], [
            MenuTile(icon: "speaker.wave.2", filledIcon: "speaker.wave.2.fill", caption: "Audio", on: s.sysAudio, isToggle: true) { s.sysAudio.toggle() },
            MenuTile(icon: "mic", filledIcon: "mic.fill", caption: "Mic", on: s.mic, isToggle: true) { s.mic.toggle() },
        ]]
    }
    /// Measure's four modes as pick tiles, areas then lines — they close the menu
    var measureTiles: [[MenuTile]] {
        func tile(_ mode: String, _ icon: String) -> MenuTile {
            MenuTile(icon: icon, caption: mode, on: s.measureMode == mode) {
                s.measureMode = mode; s.openMenu = nil; ctrl.syncMenu()
            }
        }
        return [[tile("Bounds", "square.dashed"), tile("Spacing", "arrow.left.and.right.square")],
                [tile("Horizontal", "arrow.left.and.right"), tile("Vertical", "arrow.up.and.down")]]
    }
    @ViewBuilder func countdownRows() -> some View {
        ForEach(["Off", "3 s", "5 s", "10 s"], id: \.self) { v in
            let current = s.countdown == "Off" ? "Off" : s.countdown + " s"
            row(v == "Off" ? "No Countdown" : "\(v) Countdown", icon: v == "Off" ? "bolt" : "timer", on: v == current) {
                s.countdown = v.replacingOccurrences(of: " s", with: "")
            }
        }
    }
}

/// a menu row's or tile's hover fill: concentric with the menu where it
/// meets the menu's corners, 14 pt elsewhere
func menuHighlight(_ on: Bool) -> some View {
    ConcentricRectangle(corners: .concentric(minimum: .fixed(14)), isUniform: false)
        .fill(.white.opacity(on ? 0.1 : 0))
}

// a menu row: 22 pt leading column (checkmark when on, an icon otherwise, or
// blank), title + optional subtitle, hover highlight like a native menu's
struct MenuRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String // leading column — every row gets one
    let on: Bool
    /// an on/off option rather than one pick of several — VoiceOver reads it as a toggle
    var isToggle = false
    let action: () -> Void
    @State var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15))
                    .foregroundStyle(.white).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15)).foregroundStyle(.white)
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1).truncationMode(.tail) }
                }
                Spacer()
                Color.clear.frame(width: 22, height: 22) // fixed trailing slot
                    .overlay {
                        if on { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white) }
                    }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 14)
            .background(menuHighlight(hovering))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isToggle ? .isToggle : (on ? .isSelected : []))
        .accessibilityValue(isToggle ? (on ? "On" : "Off") : "")
    }
}

// a menu tile — icon over caption, like the reference menu's top row. On is
// accent; toggles report On/Off to VoiceOver, picks report selected
struct MenuTile: View {
    let icon: String
    var filledIcon: String? = nil // used when on, if a filled variant exists
    let caption: String
    let on: Bool
    /// toggles report On/Off; pick tiles report selected
    var isToggle = false
    /// greys the tile out and swallows its action — variants that don't exist yet
    var disabled = false
    let action: () -> Void
    @State var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: on ? (filledIcon ?? icon) : icon).font(.system(size: 20))
                Text(caption).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(on ? Color.wadjetAccent : .white)
            .frame(maxWidth: .infinity).frame(height: 64)
            .background(menuHighlight(hovering))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityAddTraits(isToggle ? .isToggle : (on ? .isSelected : []))
        .accessibilityValue(isToggle ? (on ? "On" : "Off") : "")
    }
}


/// The Workflow Steps only the app can perform: the pasteboard and the toast UI.
/// Keeps the toast each showToast created per run id; the run's `.done` finishes it.
@MainActor
final class AppWorkflowEffects: WorkflowEffects {
    let toast: ToastController
    var canvases: [UUID: URL] = [:]
    init(toast: ToastController) { self.toast = toast }

    func copyImage(_ file: URL, run: UUID) async throws {
        try CanvasClipboard.copyImage(file, canvas: canvases[run])
    }

    func copyFile(_ file: URL, run: UUID) async throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        AppState.shared.lastClipboard = "<file \(file.lastPathComponent)>"
    }

    func open(_ file: URL, app: String?, run: UUID) async throws {
        if let app {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else {
                throw NSError(domain: "wadjet", code: 2, userInfo: [NSLocalizedDescriptionKey: "no app with id \(app)"])
            }
            try await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: .init())
        } else if !NSWorkspace.shared.open(file) {
            throw NSError(domain: "wadjet", code: 3, userInfo: [NSLocalizedDescriptionKey: "couldn't open \(file.lastPathComponent)"])
        }
    }

    func pin(_ file: URL, run: UUID) async throws {
        guard let img = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "wadjet", code: 1, userInfo: [NSLocalizedDescriptionKey: "couldn't read the image"])
        }
        AppDelegate.shared?.openPin(image: img)
    }

    func showToast(_ file: URL, run: UUID) async throws {
        let img = await captureThumbnail(file, maxPixels: 400)
        let t = ToastItem(cap: Capture(thumb: img, label: file.deletingPathExtension().lastPathComponent,
                                     url: file, duration: nil, canvas: canvases[run]))
        t.title = "Captured"
        toast.items.insert(t, at: 0)
        toast.relayout()
        AppDelegate.shared?.updateEscHotkey()
        toast.runToasts[run, default: []].append(t)
    }
}

/// A thumbnail for a capture file: the package thumbnail for Canvases,
/// ImageIO for images, the first frame via
/// AVAssetImageGenerator for .mp4 (ImageIO can't read video). Async because the
/// video path is.
func captureThumbnail(_ file: URL, maxPixels: Int = 64) async -> CGImage? {
    if file.pathExtension.lowercased() == "mp4" {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        return try? await gen.image(at: .zero).image
    }
    let imageFile = file.pathExtension.lowercased() == "wadjet" ? file.appendingPathComponent("thumbnail.png") : file
    if let src = CGImageSourceCreateWithURL(imageFile as CFURL, nil),
       let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
           kCGImageSourceCreateThumbnailFromImageAlways: true,
           kCGImageSourceThumbnailMaxPixelSize: maxPixels,
       ] as CFDictionary) { return cg }
    return nil
}

// MARK: - Toasts

struct Capture {
    let thumb: CGImage?; let label: String; var url: URL?; let duration: TimeInterval?
    /// the capture's editable Canvas package — a Screenshot toast opens it in the Editor
    var canvas: URL? = nil
    var kindShot: Bool { duration == nil }
}

@MainActor
final class ToastItem: ObservableObject, Identifiable {
    let id = UUID(); var cap: Capture
    @Published var title = ""; @Published var sub = ""; @Published var err: String? = nil
    @Published var showRing = false
    @Published var showBar = false
    @Published var showRetry = false
    @Published var showCancel = false
    @Published var progress: Double = 0
    var remaining: TimeInterval = 5; var timer: Timer?; var t0 = Date()
    var dragging = false // a file drag is in progress — hover must not restart the timer
    init(cap: Capture) { self.cap = cap }
}

@MainActor
final class ToastController: ObservableObject {
    static var shared: ToastController?
    @Published var items: [ToastItem] = []
    // Workflow runs' toasts, keyed by run id; .done finishes them all
    var runToasts: [UUID: [ToastItem]] = [:]
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
    func finish(_ t: ToastItem, _ err: String?) {
        t.err = err; t.showRing = false; startTimer(t)
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
    /// idempotent: a drag pause after a hover pause must not subtract twice
    func pauseTimer(_ t: ToastItem) {
        guard let timer = t.timer else { return }
        timer.invalidate(); t.timer = nil
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

/// an AppKit drag source over the thumbnail — dragging it hands the saved
/// file to whatever it's dropped on, like macOS's screenshot thumbnail
struct ToastDragSource: NSViewRepresentable {
    let url: URL
    let thumb: CGImage?
    let onClick: () -> Void
    let onDragStart: () -> Void
    let onEnd: (NSDragOperation, NSPoint) -> Void
    func makeNSView(context: Context) -> DragView { let v = DragView(); v.rep = self; return v }
    func updateNSView(_ v: DragView, context: Context) { v.rep = self }
    final class DragView: NSView, NSDraggingSource {
        var rep: ToastDragSource?
        var downPt: NSPoint?
        var didDrag = false
        override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) { downPt = convert(e.locationInWindow, from: nil); didDrag = false }
        override func mouseDragged(with e: NSEvent) {
            guard !didDrag, let down = downPt, let rep else { return }
            let pt = convert(e.locationInWindow, from: nil)
            guard hypot(pt.x - down.x, pt.y - down.y) > 3 else { return }
            didDrag = true
            rep.onDragStart()
            let item = NSDraggingItem(pasteboardWriter: rep.url as NSURL)
            let img = rep.thumb.map { NSImage(cgImage: $0, size: bounds.size) }
                ?? NSWorkspace.shared.icon(forFile: rep.url.path)
            item.setDraggingFrame(bounds, contents: img)
            beginDraggingSession(with: [item], event: e, source: self)
        }
        override func mouseUp(with e: NSEvent) { if !didDrag { rep?.onClick() }; downPt = nil }
        func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
            rep?.onEnd(operation, p)
        }
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
        .onHover { h in
            if h { ctrl.pauseTimer(item) }
            else if !item.dragging { ctrl.startTimer(item) }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .animation(.smooth(duration: 0.35), value: offset)
    }
    var card: some View {
        ZStack(alignment: .bottom) {
            if let cg = item.cap.thumb {
                // sized to the capture's own aspect so the rim hugs the image
                let k = min(220 / CGFloat(cg.width), 160 / CGFloat(cg.height), 1)
                Image(cg, scale: 1, label: Text(""))
                    .resizable()
                    .frame(width: CGFloat(cg.width) * k, height: CGFloat(cg.height) * k)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.9), lineWidth: 2))
                    .shadow(radius: 10, y: 4)
                    .overlay {
                        if let url = item.cap.url {
                            ToastDragSource(url: url, thumb: cg,
                                onClick: { open() },
                                onDragStart: {
                                    item.dragging = true; ctrl.pauseTimer(item)
                                },
                                onEnd: { op, pt in
                                    item.dragging = false
                                    // a landed drop, or a fling off the right edge, dismisses
                                    let gone = op != [] || (ctrl.panel?.screen ?? .main)
                                        .map { pt.x >= $0.frame.maxX - 40 } ?? false
                                    if gone { ctrl.dismiss(item) } else { ctrl.startTimer(item) }
                                    AppLog.line("toast drag ended op=\(op.rawValue) → \(gone ? "dismissed" : "kept")")
                                })
                        }
                    }
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
    /// a Screenshot's Canvas opens in the Editor; anything else opens its file
    func open() {
        if let u = item.cap.canvas, FileManager.default.fileExists(atPath: u.path) {
            AppDelegate.shared?.openCanvas(u)
        } else if let u = item.cap.url {
            NSWorkspace.shared.open(u)
        }
    }
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
            Text("rec: \(s.recActive ? fmtT(s.recordingElapsed) + (s.recordingPaused ? " (paused)" : "") : "-")")
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

// MARK: - Shortcuts (KeyboardShortcuts; Esc/Space/⌃n in-overlay Carbon hotkeys
// are elsewhere — they're overlay-scoped, not global)

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
