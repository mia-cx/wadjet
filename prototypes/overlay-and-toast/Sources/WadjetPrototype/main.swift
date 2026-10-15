// Throwaway prototype for mia-cx/wadjet #12 (Freeze Frame overlay and toolbar)
// and #13 (post-capture toast). Not product code.

import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon
import Vision
import UniformTypeIdentifiers

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
    init?(named s: String) { self = Tool.allCases.first { $0.title.lowercased().contains(s.lowercased()) } ?? Tool(rawValue: s)! }
}

enum Phase { case desktop, frozen, countdown, recording }

@MainActor
final class ProtoState: ObservableObject {
    static let shared = ProtoState()
    @Published var phase: Phase = .desktop
    @Published var tool: Tool? = nil
    @Published var workflow: String? = nil
    @Published var colourFmt = "Hex"
    @Published var measureMode = "Region" // Region, Line, Edges X, Edges Y, Edges X+Y
    @Published var countdown = "Off" // Off 3 5 10
    @Published var sysAudio = false
    @Published var mic = false
    @Published var cursor = true
    @Published var clickCircles = false
    @Published var showIslandWhileRecording = true
    @Published var toolbarExpanded = false
    @Published var workflowMenuOpen = false
    @Published var recordingElapsed: TimeInterval = 0
    @Published var recordingPaused = false
    @Published var lastClipboard = ""
    @Published var latencyText = "none"
    @Published var islandMode = false        // prototype: island even with notch
    @Published var uploadMode = 0            // 0 succeed, 1 fail, 2 offline
    @Published var stepErrorNext = false
    @Published var showStateHUD = true
    var workflows: [String] {
        guard let tool else { return [] }
        switch tool.kind {
        case .shot: return ["Screenshot", "Upload to w.mia.cx", "Pin"]
        case .rec: return ["MP4", "GIF", "GIF to w.mia.cx"]
        case .util: return []
        }
    }
    var effectiveWorkflow: String? { workflow ?? workflows.first }
}

// MARK: - Frozen frame store

struct FrozenDisplay {
    let screen: NSScreen
    let image: CGImage          // pixel resolution
    var bitmap: UnsafePointer<UInt8>? // RGBA premultiplied, pixel coords
    var bitmapWidth = 0, bitmapHeight = 0
    var windowFrames: [CGRect] = []
}
@MainActor
final class Freeze {
    static let shared = Freeze()
    var displays: [FrozenDisplay] = []
    var panels: [NSPanel] = []
    var capturedAt = Date()
    func pixel(at pt: CGPoint, on d: Int) -> (UInt8, UInt8, UInt8) {
        guard d < displays.count, let bm = displays[d].bitmap else { return (0, 0, 0) }
        let f = displays[d]
        let sx = CGFloat(f.bitmapWidth) / f.screen.frame.width
        let sy = CGFloat(f.bitmapHeight) / f.screen.frame.height
        // pt is in view coords (bottom-left origin); image rows are top-left origin
        let x = min(max(0, Int(pt.x * sx)), f.bitmapWidth - 1)
        let y = min(max(0, Int((f.screen.frame.height - pt.y) * sy)), f.bitmapHeight - 1)
        let i = (y * f.bitmapWidth + x) * 4
        return (bm[i + 1], bm[i + 2], bm[i + 3]) // ARGB -> RGB
    }
    func crop(rect: CGRect, on d: Int) -> CGImage? {
        guard d < displays.count else { return nil }
        let f = displays[d]
        let sx = CGFloat(f.image.width) / f.screen.frame.width
        let sy = CGFloat(f.image.height) / f.screen.frame.height
        let r = CGRect(x: rect.origin.x * sx, y: (f.screen.frame.height - rect.origin.y - rect.height) * sy,
                       width: rect.width * sx, height: rect.height * sy).integral
        return f.image.cropping(to: r)
    }
}

func hexString(_ c: (UInt8, UInt8, UInt8)) -> String { String(format: "#%02X%02X%02X", c.0, c.1, c.2) }
func fmtColour(_ c: (UInt8, UInt8, UInt8), fmt: String) -> String {
    switch fmt {
    case "RGB": return "rgb(\(c.0), \(c.1), \(c.2))"
    case "HSL":
        let r = Double(c.0) / 255, g = Double(c.1) / 255, b = Double(c.2) / 255
        let mx = max(r, g, b), mn = min(r, g, b); var h = 0.0, s = 0.0
        let l = (mx + mn) / 2
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            h *= 60
        }
        return String(format: "hsl(%.0f, %.0f%%, %.0f%%)", h, s * 100, l * 100)
    default: return hexString(c)
    }
}
@MainActor
func clipboard(_ s: String) {
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    ProtoState.shared.lastClipboard = s
}

// MARK: - Log file

enum ProtoLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("wadjet-prototype/prototype.log")
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
    var recordingPanel: NSPanel?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "wadjet")
        rebuildMenu()
        overlayCtrl = OverlayController(app: self)
        toastCtrl = ToastController()
        Hotkeys.register()
        ProtoLog.line("launch; preflight screen capture = \(CGPreflightScreenCaptureAccess()); statusItem frame = \(statusItem.button?.window?.frame.debugDescription ?? "?")")
        buildStateHUD()
        _ = try? FileManager.default.createDirectory(at: Self.capturesDir, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in self.recTick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ProtoLog.line("statusItem frame = \(self.statusItem.button?.window?.frame.debugDescription ?? "?")")
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("cx.mia.wadjet.prototype.cmd"), object: nil, queue: .main
        ) { [weak self] n in
            if let cmd = n.object as? String { Task { @MainActor in self?.handleCmd(cmd) } }
        }
    }

    // debug command channel, driven by tools/cmd.sh
    func handleCmd(_ cmd: String) {
        ProtoLog.line("cmd: \(cmd)")
        let parts = cmd.split(separator: " ").map(String.init)
        let s = ProtoState.shared
        switch parts.first {
        case "open" where parts.count > 1:
            if let t = Tool(named: parts.dropFirst().joined(separator: " ")) { trigger(t) }
        case "tool" where parts.count > 1:
            if let t = Tool(named: parts.dropFirst().joined(separator: " ")) { trigger(t) }
        case "workflow":
            s.workflow = parts.dropFirst().joined(separator: " ")
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
            default: ProtoLog.line("cmd option: unknown key \(key)")
            }
        case "expand": s.toolbarExpanded = true
        case "collapse": s.toolbarExpanded = false
        case "upload" where parts.count > 1:
            s.uploadMode = ["succeed": 0, "fail": 1, "offline": 2][parts[1]] ?? s.uploadMode
            rebuildMenu()
        case "steperror" where parts.count > 1:
            s.stepErrorNext = parts[1] == "on"
        case "stop": if s.phase == .recording { stopRecording() }
        case "pause": if s.phase == .recording { togglePause() }
        case "esc": handleEsc()
        default: ProtoLog.line("cmd: unhandled \(cmd)")
        }
    }

    static var capturesDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wadjet-prototype/Captures")
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
        let proto = NSMenuItem(title: "Prototype", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        psub.addItem(mi("Island Mode Even With Notch", #selector(toggleIsland), on: ProtoState.shared.islandMode))
        psub.addItem(.separator())
        psub.addItem(mi("Next Upload: Succeed", #selector(upl0), on: ProtoState.shared.uploadMode == 0))
        psub.addItem(mi("Next Upload: Fail", #selector(upl1), on: ProtoState.shared.uploadMode == 1))
        psub.addItem(mi("Next Upload: Offline", #selector(upl2), on: ProtoState.shared.uploadMode == 2))
        psub.addItem(.separator())
        psub.addItem(mi("Step Error on Next Capture", #selector(toggleStepErr), on: ProtoState.shared.stepErrorNext))
        psub.addItem(mi("Show State HUD", #selector(toggleHUD), on: ProtoState.shared.showStateHUD))
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
    @objc func toggleIsland(_ s: NSMenuItem) { ProtoState.shared.islandMode.toggle(); s.state = ProtoState.shared.islandMode ? .on : .off }
    @objc func upl0(_ s: NSMenuItem) { setUpl(0) }; @objc func upl1(_ s: NSMenuItem) { setUpl(1) }; @objc func upl2(_ s: NSMenuItem) { setUpl(2) }
    func setUpl(_ v: Int) { ProtoState.shared.uploadMode = v; rebuildMenu() }
    @objc func toggleStepErr(_ s: NSMenuItem) { ProtoState.shared.stepErrorNext.toggle(); s.state = ProtoState.shared.stepErrorNext ? .on : .off }
    @objc func toggleHUD(_ s: NSMenuItem) { ProtoState.shared.showStateHUD.toggle(); s.state = ProtoState.shared.showStateHUD ? .on : .off
        hudPanel.setIsVisible(ProtoState.shared.showStateHUD) }
    @objc func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: trigger
    func trigger(_ tool: Tool) {
        let s = ProtoState.shared
        if s.phase == .recording && tool.kind == .rec { stopRecording(); return }
        // switching Tools while frozen keeps the same Freeze Frame
        if s.phase == .frozen { if s.tool != tool { s.tool = tool; s.workflow = nil; ProtoLog.line("tool switched to \(tool.title)") }; return }
        if s.phase != .desktop { ProtoLog.line("trigger ignored: busy (\(s.phase))"); return }
        if !CGPreflightScreenCaptureAccess() { permissionNeeded(); ProtoLog.line("screen capture preflight denied for \(tool.title)"); return }
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { await overlayCtrl.freezeAndShow(tool: tool, t0: t0) }
    }
    func permissionNeeded() {
        _ = CGRequestScreenCaptureAccess()
        let a = NSAlert()
        a.messageText = "Screen Recording Permission Needed"
        a.informativeText = "The prototype needs Screen Recording access to take a Freeze Frame. Grant it in System Settings, then relaunch."
        a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: selection -> capture or recording
    func didSelect(_ rect: CGRect, on display: Int) {
        let s = ProtoState.shared
        guard let tool = s.tool else { return }
        if tool.kind == .shot {
            let thumb = Freeze.shared.crop(rect: rect, on: display)
            overlayCtrl.closeAll()
            runCapture(thumb: thumb, label: "\(tool.title) \(Int(rect.width))×\(Int(rect.height))")
        } else {
            startRecording(rect: rect, display: display)
        }
    }
    func runCapture(thumb: CGImage?, label: String, duration: TimeInterval? = nil) {
        var path: URL? = nil
        if let img = thumb {
            path = Self.capturesDir.appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970)).png")
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: path!)
        }
        toastCtrl.start(cap: Capture(thumb: thumb, label: label, url: path, duration: duration))
        let wf = ProtoState.shared.effectiveWorkflow ?? "Screenshot"
        if wf == "Pin", let img = thumb { openPin(image: img) }
        if wf == "Screenshot", let img = thumb {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: img, size: .zero) as NSPasteboardWriting])
            ProtoState.shared.lastClipboard = "<image \(img.width)×\(img.height)>"
        }
    }

    // MARK: recording (simulated)
    func startRecording(rect: CGRect, display: Int) {
        let s = ProtoState.shared
        let thumb = Freeze.shared.crop(rect: rect, on: display)
        overlayCtrl.closeAllPanelsOnly() // live screen returns
        recordingRect = rect; recordingDisplay = display; recordingThumb = thumb.map { NSImage(cgImage: $0, size: .zero) }
        pauseAcc = 0; s.recordingElapsed = 0; s.recordingPaused = false
        let n = s.countdown == "Off" ? 0 : Int(s.countdown) ?? 0
        let begin = {
            s.phase = .recording; self.recStart = Date()
            ProtoLog.line("phase=recording")
            self.updateEscHotkey()
            self.showRecBorder(rect: rect, display: display)
            self.updateRecChrome()
        }
        if n > 0 {
            s.phase = .countdown
            ProtoLog.line("phase=countdown (\(n))")
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
        let s = ProtoState.shared
        statusItem.button?.title = "● " + fmtT(s.recordingElapsed)
        statusItem.button?.image = nil
        let m = NSMenu()
        m.addItem(mi(s.recordingPaused ? "Resume" : "Pause", #selector(recPause), on: false))
        m.addItem(mi("Stop Recording", #selector(recStop), on: false))
        statusItem.menu = m
        overlayCtrl.refreshToolbar(onDisplay: recordingDisplay)
    }
    @objc func recPause() { togglePause() }
    @objc func recStop() { stopRecording() }
    func togglePause() {
        let s = ProtoState.shared
        if s.recordingPaused { pauseAcc += Date().timeIntervalSince(pauseStart!); s.recordingPaused = false }
        else { s.recordingPaused = true; pauseStart = Date() }
        updateRecChrome()
    }
    func recTick() {
        let s = ProtoState.shared
        guard s.phase == .recording, !s.recordingPaused, let st = recStart else { return }
        s.recordingElapsed = Date().timeIntervalSince(st) - pauseAcc
        statusItem.button?.title = "● " + fmtT(s.recordingElapsed)
    }
    // Esc during countdown cancels before the Recording starts.
    func cancelCountdown() {
        let s = ProtoState.shared
        guard s.phase == .countdown else { return }
        CountdownHUD.hide()
        s.phase = .desktop; recStart = nil
        overlayCtrl.closeAllPanelsOnly()
        ProtoLog.line("esc: cancelled countdown")
        rebuildMenu(); updateEscHotkey()
    }
    func stopRecording() {
        let s = ProtoState.shared
        s.recordingElapsed = recStart.map { Date().timeIntervalSince($0) - pauseAcc } ?? s.recordingElapsed
        let dur = s.recordingElapsed
        let label = "\(s.tool?.title ?? "Recording") \(fmtT(dur))"
        recordingPanel?.close(); recordingPanel = nil
        s.phase = .desktop; recStart = nil
        updateEscHotkey()
        ProtoLog.line("phase=desktop (recording stopped, \(String(format: "%.1f", dur))s)")
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
    var escRegistered = false
    var escHandlerInstalled = false
    func updateEscHotkey() {
        let s = ProtoState.shared
        let active = s.phase == .frozen || s.phase == .countdown
            || !toastCtrl.items.isEmpty || !pins.isEmpty
        if active && !escRegistered {
            if !escHandlerInstalled {
                escHandlerInstalled = true
                var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ -> OSStatus in
                    var id = EventHotKeyID()
                    GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                    guard id.id == 10 else { return OSStatus(eventNotHandledErr) }
                    DispatchQueue.main.async { AppDelegate.shared?.handleEsc() }
                    return noErr
                }, 1, &type, nil, nil)
            }
            var ref: EventHotKeyRef?
            let err = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x77646A74), id: 10),
                                          GetApplicationEventTarget(), 0, &ref)
            escRef = ref; escRegistered = (err == noErr && ref != nil)
            ProtoLog.line("esc hotkey registered (err=\(err))")
        } else if !active && escRegistered {
            if let r = escRef { UnregisterEventHotKey(r) }
            escRef = nil; escRegistered = false
            ProtoLog.line("esc hotkey unregistered")
        }
    }
    // priority: overlay > countdown > in-flight toast > idle toast > pin.
    // (Recording is never here; Esc is not registered on its account.)
    func handleEsc() {
        let s = ProtoState.shared
        if s.workflowMenuOpen { s.workflowMenuOpen = false; ProtoLog.line("esc: closed workflow menu"); return }
        if s.phase == .frozen { ProtoLog.line("esc: cancelled overlay"); overlayCtrl.closeAll(); return }
        if s.phase == .countdown { cancelCountdown(); return }
        if let t = toastCtrl.items.first(where: { $0.showBar || $0.showRing }) {
            t.showBar = false; t.showRing = false; t.showCancel = false
            t.title = "Cancelled"; toastCtrl.startTimer(t)
            ProtoLog.line("esc: cancelled in-flight \(t.sub.isEmpty ? t.title : t.sub)")
            updateEscHotkey(); return
        }
        if let t = toastCtrl.items.first {
            toastCtrl.dismiss(t); ProtoLog.line("esc: dismissed idle toast")
            updateEscHotkey(); return
        }
        if let p = pins.last {
            p.close(); pins.removeLast(); ProtoLog.line("esc: closed pin")
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
        h.frame.origin = .zero; p.contentView = h; p.orderFront(nil)
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
    var toolbarPanel: NSPanel?
    init(app: AppDelegate) { self.app = app }

    func freezeAndShow(tool: Tool, t0: CFAbsoluteTime) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            Freeze.shared.displays = []
            for screen in NSScreen.screens {
                guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      let disp = content.displays.first(where: { $0.displayID == num }) else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(disp.width); cfg.height = Int(disp.height)
                cfg.showsCursor = true; cfg.scalesToFit = true
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: disp, excludingWindows: []), configuration: cfg)
                var fd = FrozenDisplay(screen: screen, image: img)
                fd.windowFrames = content.windows
                    .filter { w in
                        w.isActive && w.windowLayer == 0 &&
                        !(w.owningApplication?.bundleIdentifier ?? "").contains("WadjetPrototype") &&
                        w.frame.width > 40 && w.frame.height > 40
                    }.map(\.frame)
                // SCWindow frames are in top-left global coords; convert to this
                // display's bottom-left view coords for NSView hit-testing/drawing
                let sy = screen.frame
                let primaryH = NSScreen.screens[0].frame.height
                fd.windowFrames = fd.windowFrames.map { f in
                    CGRect(x: f.origin.x - sy.origin.x,
                           y: primaryH - sy.origin.y - f.origin.y - f.height,
                           width: f.width, height: f.height)
                }
                // bitmap for pixel reads
                let w = img.width, h = img.height
                var data = [UInt8](repeating: 0, count: w * h * 4)
                let ok = data.withUnsafeMutableBytes { ptr -> Bool in
                    guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
                }
                if ok { fd.bitmap = UnsafePointer(data.withUnsafeBufferPointer { $0.baseAddress }); fd.bitmapWidth = w; fd.bitmapHeight = h
                    bitmapStore.append(data) }
                Freeze.shared.displays.append(fd)
            }
            let latency = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            await MainActor.run {
                ProtoState.shared.latencyText = String(format: "%.0f ms (%d displays)", latency, Freeze.shared.displays.count)
                let perDisplay = Freeze.shared.displays.map { "\($0.image.width)x\($0.image.height)" }.joined(separator: ", ")
                ProtoLog.line("freeze latency \(Int(latency)) ms across \(Freeze.shared.displays.count) displays: \(perDisplay)")
                self.showPanels(tool: tool)
                ProtoLog.line("phase=frozen tool=\(tool.title)")
            }
        } catch {
            await MainActor.run {
                ProtoState.shared.latencyText = "capture failed: \(error.localizedDescription)"
                ProtoLog.line("freeze failed: \(error.localizedDescription)")
            }
        }
    }
    var bitmapStore: [[UInt8]] = []

    func showPanels(tool: Tool) {
        let s = ProtoState.shared
        s.phase = .frozen; s.tool = tool
        if tool.kind != .util, !(s.workflows.contains(s.workflow ?? "")) { s.workflow = s.workflows.first }
        closeAllPanelsOnly()
        for (i, fd) in Freeze.shared.displays.enumerated() {
            let p = NSPanel(contentRect: fd.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver; p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.ignoresMouseEvents = false; p.acceptsMouseMovedEvents = true
            p.hidesOnDeactivate = false
            let ov = OverlayNSView(frame: NSRect(origin: .zero, size: fd.screen.frame.size), displayIndex: i, controller: self)
            p.contentView = ov
            p.orderFront(nil)
            p.makeFirstResponder(ov)
            panels.append(p)
        }
        showToolbar()
        app?.updateEscHotkey()
    }
    func showToolbar(onDisplay forced: Int? = nil) {
        // toolbar on the display under the mouse unless overridden
        let mouse = NSEvent.mouseLocation
        let idx = forced ?? Freeze.shared.displays.firstIndex { NSMouseInRect(mouse, $0.screen.frame, false) } ?? 0
        guard idx < Freeze.shared.displays.count else { return }
        let fd = Freeze.shared.displays[idx]
        let tv = ToolbarView(displayIndex: idx)
        let hosting = PassthroughHostingView(rootView: tv)
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
        toolbarPanel = p
    }
    func refreshToolbar(onDisplay forced: Int? = nil) {
        toolbarPanel?.close(); toolbarPanel = nil
        let p = ProtoState.shared.phase
        if p == .frozen || (p == .recording && ProtoState.shared.showIslandWhileRecording) { showToolbar(onDisplay: forced) }
    }
    func closeAllPanelsOnly() {
        panels.forEach { ($0.contentView as? OverlayNSView)?.measurePop?.close(); $0.close() }
        panels = []
        toolbarPanel?.close(); toolbarPanel = nil
    }
    func closeAll() {
        closeAllPanelsOnly()
        if ProtoState.shared.phase != .desktop { ProtoLog.line("phase=desktop (overlay closed)") }
        ProtoState.shared.phase = .desktop
        ProtoState.shared.toolbarExpanded = false
        Freeze.shared.displays = []; bitmapStore = []
        AppDelegate.shared?.updateEscHotkey()
    }
}

// MARK: - Overlay NSView (per display)

@MainActor
final class OverlayNSView: NSView {
    let di: Int
    weak var ctrl: OverlayController?
    var dragStart: CGPoint?, sel: CGRect?, moving = false, lastPt = CGPoint.zero
    var hoverWin: CGRect?, hoverPt = CGPoint.zero
    var guideLines: [(axis: Int, a: CGFloat, b: CGFloat, c: CGFloat)] = []
    var measureCopy: String?
    var measurePop: NSPanel?
    init(frame f: NSRect, displayIndex: Int, controller: OverlayController) {
        di = displayIndex; ctrl = controller
        super.init(frame: f)
        wantsLayer = true
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
    }
    required init?(coder: NSCoder) { fatalError() }
    var fd: FrozenDisplay { Freeze.shared.displays[di] }
    var tool: Tool { ProtoState.shared.tool ?? .capRegion }
    var measureMode: String { ProtoState.shared.measureMode }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func draw(_ r: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.draw(fd.image, in: bounds)
        let t = tool, mm = measureMode
        if t == .capRegion || t == .recRegion || t == .copyText || (t == .measure && mm == "Region") {
            if let s = sel {
                // dim everything except the selection; inside stays untouched
                let dim = NSColor.black.withAlphaComponent(0.35)
                for r in [CGRect(x: 0, y: s.maxY, width: bounds.width, height: bounds.height - s.maxY),
                          CGRect(x: 0, y: 0, width: bounds.width, height: s.minY),
                          CGRect(x: 0, y: s.minY, width: s.minX, height: s.height),
                          CGRect(x: s.maxX, y: s.minY, width: bounds.width - s.maxX, height: s.height)] {
                    dim.setFill(); r.fill()
                }
                NSColor.white.withAlphaComponent(0.8).setStroke()
                let p = NSBezierPath(rect: s); p.lineWidth = 0.5; p.stroke()
            } else {
                NSColor.black.withAlphaComponent(0.15).setFill(); bounds.fill()
            }
        }
        let overToolbar = ctrl?.toolbarPanel?.frame.contains(NSEvent.mouseLocation) ?? false
        if !overToolbar, (t == .capWindow || t == .recWindow), let w = hoverWin,
           w.width < bounds.width * 0.9 && w.height < bounds.height * 0.9 {
            NSColor.systemBlue.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: w, xRadius: 10, yRadius: 10).fill()
        }
        if t == .measure && mm == "Line", let st = dragStart {
            let p = NSBezierPath(); NSColor.systemBlue.setStroke(); p.lineWidth = 1.5
            p.move(to: st); p.line(to: lastPt); p.stroke()
        }
        for g in guideLines {
            let p = NSBezierPath(); NSColor.systemRed.setStroke(); p.lineWidth = 1.5
            if g.axis == 0 { p.move(to: CGPoint(x: g.a, y: g.c)); p.line(to: CGPoint(x: g.b, y: g.c)) }
            else { p.move(to: CGPoint(x: g.c, y: g.a)); p.line(to: CGPoint(x: g.c, y: g.b)) }
            p.stroke()
            let ticks: [(CGFloat, CGFloat)] = g.axis == 0
                ? [(g.a, g.c), (g.b, g.c)]
                : [(g.c, g.a), (g.c, g.b)]
            for (x, y) in ticks {
                p.move(to: CGPoint(x: x - 5, y: y)); p.line(to: CGPoint(x: x + 5, y: y))
                p.move(to: CGPoint(x: x, y: y - 5)); p.line(to: CGPoint(x: x, y: y + 5))
            }
            p.stroke()
        }
        if !overToolbar { drawLoupe(ctx) }
        if let s = sel, t == .capRegion || t == .recRegion {
            let str = "\(Int(s.width)) × \(Int(s.height))"
            let at = CGPoint(x: min(bounds.width - 90, s.maxX + 8), y: min(bounds.height - 26, s.maxY + 8))
            drawBadge(str, at: at)
        }
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
        let n = tool == .pickColour ? 15 : 11, px = 11
        let sz = CGFloat(n * px)
        let lx = pt.x + 26 + sz > bounds.width ? pt.x - 26 - sz : pt.x + 26
        let ly = min(bounds.height - sz - 40, pt.y + 20)
        let f = fd; let sx = CGFloat(f.image.width) / bounds.width, sy = CGFloat(f.image.height) / bounds.height
        // view coords are bottom-left origin; image rows are top-left origin
        let cxp = pt.x * sx, cyp = (bounds.height - pt.y) * sy
        let nf = CGFloat(n)
        let imgBounds = CGRect(x: 0, y: 0, width: f.image.width, height: f.image.height)
        let src = CGRect(x: cxp - nf / 2, y: cyp - nf / 2, width: nf, height: nf).intersection(imgBounds)
        if let crop = f.image.cropping(to: src.integral) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: lx, y: ly, width: sz, height: sz))
            ctx.restoreGState()
            // centre pixel outline
            let mid = CGFloat(n / 2 * px)
            NSColor.white.setStroke()
            NSBezierPath(rect: NSRect(x: lx + mid, y: ly + mid, width: 11, height: 11)).stroke()
            // border
            NSColor.black.withAlphaComponent(0.4).setStroke()
            NSBezierPath(roundedRect: NSRect(x: lx, y: ly, width: sz, height: sz), xRadius: 8, yRadius: 8).stroke()
            let c = Freeze.shared.pixel(at: pt, on: di)
            drawBadge("\(Int(pt.x)), \(Int(pt.y))  \(hexString(c))", at: CGPoint(x: lx, y: ly + sz + 6))
        }
    }
    func mouseInView() -> CGPoint { convert(NSEvent.mouseLocation, from: nil) }

    override func mouseMoved(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil); hoverPt = pt
        if tool == .capWindow || tool == .recWindow {
            hoverWin = fd.windowFrames.first { $0.contains(pt) }
        } else {
            hoverWin = nil
        }
        if tool == .measure && measureMode.hasPrefix("Edges") { scanEdges(at: pt) }
        needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        ProtoLog.line("mouseDown \(tool.title) d\(di) @\(Int(pt.x)),\(Int(pt.y))")
        switch tool {
        case .capScreen, .recScreen:
            app?.didSelect(bounds, on: di)
        case .capWindow, .recWindow:
            if let w = hoverWin { app?.didSelect(w, on: di) }
        case .pickColour:
            let c = Freeze.shared.pixel(at: pt, on: di)
            let s = fmtColour(c, fmt: ProtoState.shared.colourFmt)
            clipboard(s); showHUD("Copied \(s)", swatch: hexString(c))
            ctrl?.closeAll()
        case .measure where measureMode.hasPrefix("Edges"):
            copyMeasure()
        default:
            dragStart = pt; sel = CGRect(origin: pt, size: .zero); lastPt = pt; moving = false
        }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        guard let st = dragStart else { return }
        let pt = convert(e.locationInWindow, from: nil)
        if true {
            if e.modifierFlags.contains(.option) {
                sel = CGRect(x: st.x - abs(pt.x - st.x), y: st.y - abs(pt.y - st.y), width: 2 * abs(pt.x - st.x), height: 2 * abs(pt.y - st.y))
            } else if e.modifierFlags.contains(.shift) {
                if tool == .measure && measureMode == "Line" {
                    let dx = pt.x - st.x, dy = pt.y - st.y, len = max(abs(dx), abs(dy))
                    let sx2: CGFloat = dx >= 0 ? 1 : -1, sy2: CGFloat = dy >= 0 ? 1 : -1
                    if abs(dx) < 0.41 * len { lastPt = CGPoint(x: st.x, y: st.y + sy2 * len) }
                    else if abs(dy) < 0.41 * len { lastPt = CGPoint(x: st.x + sx2 * len, y: st.y) }
                    else { lastPt = CGPoint(x: st.x + sx2 * len, y: st.y + sy2 * len) }
                    sel = CGRect(origin: st, size: .zero)
                } else {
                    let w = pt.x - st.x, h = pt.y - st.y, m = max(abs(w), abs(h))
                    sel = rectNorm(st, CGPoint(x: st.x + (w >= 0 ? m : -m), y: st.y + (h >= 0 ? m : -m)))
                }
            } else if tool == .measure && measureMode == "Line" {
                lastPt = pt; sel = CGRect(origin: st, size: .zero)
            } else {
                sel = rectNorm(st, pt)
            }
        }
        if tool == .measure { showMeasurePopover() }
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        defer { needsDisplay = true }
        ProtoLog.line("mouseUp \(tool.title) sel=\(sel.debugDescription)")
        if tool == .measure && (measureMode == "Region" || measureMode == "Line") { showMeasurePopover(); dragStart = nil; return }
        guard let s = sel, dragStart != nil else { return }
        dragStart = nil
        if tool == .copyText { copyText(in: s); ctrl?.closeAll(); return }
        if (tool == .capRegion || tool == .recRegion) && s.width > 4 && s.height > 4 { app?.didSelect(s, on: di); return }
        sel = nil
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { ctrl?.closeAll() }
        else if e.keyCode == 36 && tool == .measure { copyMeasure() }
    }
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
                ProtoLog.line("ocr: \(lines.count) lines -> \(lines.joined(separator: " | "))")
                clipboard(lines.joined(separator: "\n"))
                item.title = "Copied \(lines.count) line\(lines.count == 1 ? "" : "s")"
                tc.startTimer(item)
            }
        }
    }

    // measure
    func displayPPI() -> CGFloat {
        let f = fd.screen
        // per-display: use this screen's displayID
        guard let num = f.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return 254 }
        let mm = CGDisplayScreenSize(num)
        let pxW = CGFloat(CGDisplayPixelsWide(num))
        return mm.width > 0 ? pxW / (mm.width / 25.4) : 254
    }
    func showMeasurePopover() {
        let ppi = displayPPI()
        var html: String; var copy: String; var near: CGPoint
        if measureMode == "Region" {
            guard let s = sel else { return }
            let px = s.width * CGFloat(fd.image.width) / bounds.width, py = s.height * CGFloat(fd.image.height) / bounds.height
            html = String(format: "%.0f × %.0f pt\n%.0f × %.0f px\n%.2f × %.2f in\n%.2f × %.2f cm",
                          s.width, s.height, px, py, px / ppi, py / ppi, px / ppi * 2.54, py / ppi * 2.54)
            copy = String(format: "%.0f × %.0f pt", s.width, s.height)
            near = CGPoint(x: s.maxX + 12, y: s.maxY + 12)
        } else {
            guard let a = dragStart else { return }
            let dx = lastPt.x - a.x, dy = lastPt.y - a.y
            let len = hypot(dx, dy), ang = atan2(-dy, dx) * 180 / .pi
            let px = len * CGFloat(fd.image.width) / bounds.width
            html = String(format: "%.0f pt ∠ %.1f°\n%.0f px\n%.2f in\n%.2f cm", len, ang, px, px / ppi, px / ppi * 2.54)
            copy = String(format: "%.0f pt ∠ %.1f°", len, ang)
            near = CGPoint(x: lastPt.x + 12, y: lastPt.y + 12)
        }
        measureCopy = copy
        showPop(html, near: near)
    }
    func showPop(_ s: String, near pt: CGPoint) {
        if measurePop == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver + 2; p.isOpaque = false; p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces]; p.ignoresMouseEvents = true
            measurePop = p
        }
        let lines = s.components(separatedBy: "\n")
        let h = NSHostingView(rootView: VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).font(i == 0 ? .system(size: 13, weight: .bold) : .system(size: 12))
            }
        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
         .padding(10).background(Color.black.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 8)))
        h.frame.size = h.fittingSize
        measurePop?.contentView = h
        var f = NSRect(origin: .zero, size: h.fittingSize)
        let screen = fd.screen.frame
        f.origin = CGPoint(x: min(screen.maxX - f.width - 4, screen.origin.x + pt.x),
                           y: screen.origin.y + pt.y)
        measurePop?.setFrame(f, display: true); measurePop?.orderFront(nil)
    }
    let ETHR = 28
    func scanEdges(at pt: CGPoint) {
        func diff(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let c0 = Freeze.shared.pixel(at: pt, on: di)
            let c1 = Freeze.shared.pixel(at: CGPoint(x: x, y: y), on: di)
            return abs(Int(c1.0) - Int(c0.0)) + abs(Int(c1.1) - Int(c0.1)) + abs(Int(c1.2) - Int(c0.2)) > ETHR
        }
        guideLines = []
        var copy = ""
        if measureMode != "Edges Y" {
            var l = pt.x, r = pt.x
            while l > 0 && !diff(l - 1, pt.y) { l -= 1 }
            while r < bounds.width - 1 && !diff(r + 1, pt.y) { r += 1 }
            guideLines.append((0, l, r, pt.y))
            copy += "\(Int(r - l)) pt wide"
        }
        if measureMode != "Edges X" {
            var t = pt.y, b = pt.y
            while t > 0 && !diff(pt.x, t - 1) { t -= 1 }
            while b < bounds.height - 1 && !diff(pt.x, b + 1) { b += 1 }
            guideLines.append((1, t, b, pt.x))
            copy += copy.isEmpty ? "\(Int(b - t)) pt tall" : ""
        }
        if measureMode == "Edges X+Y", guideLines.count == 2 {
            let w = guideLines[0].b - guideLines[0].a, h = guideLines[1].b - guideLines[1].a
            copy = String(format: "%.0f × %.0f pt", w, h)
        }
        measureCopy = copy
        if !copy.isEmpty { showPop(copy + " — click or Enter to copy", near: CGPoint(x: pt.x + 20, y: pt.y + 20)) }
        needsDisplay = true
    }
    func copyMeasure() {
        guard let c = measureCopy else { return }
        clipboard(c); showHUD("Copied \(c)", swatch: nil)
        measurePop?.close(); measurePop = nil; guideLines = []
        ctrl?.closeAll()
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
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = ToolbarHit.rect.contains(point)
        if hit != ToolbarHit.lastHit { ToolbarHit.lastHit = hit; ProtoLog.line("hitTest \(hit ? "in" : "out") @\(Int(point.x)),\(Int(point.y)) rect=\(ToolbarHit.rect.debugDescription)") }
        return hit ? super.hitTest(point) : nil
    }
}

enum ToolbarHit {
    nonisolated(unsafe) static var rect = CGRect.zero
    nonisolated(unsafe) static var lastHit: Bool? = nil
}

struct ToolbarView: View {
    let displayIndex: Int
    @ObservedObject var s = ProtoState.shared
    var expanded: Bool { s.toolbarExpanded }
    @State var tip: String? = nil
    @State var tipTask: Task<Void, Never>? = nil
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

    // island: black, flush with the top edge, rounded bottom corners like the notch;
    // on notched displays it is centred on (and slightly wider than) the notch.
    var islandW: CGFloat { hasNotch ? max(126, notchW + 40) : 126 }
    var islandH: CGFloat { max(22, barH) }
    // expanded toolbar grows down from inside the same shape: square top corners
    // flush with the screen edge, rounded bottom, sized to its content.
    var contentH: CGFloat { twoRows ? 74 : 40 }
    var recExpandedW: CGFloat { 260 }
    var expW: CGFloat { min(limit, (compact ? compactOptionsWidth : optionsWidth) + 430) }
    var expH: CGFloat { islandH + 8 + contentH }
    var shapeW: CGFloat { expanded ? (recording ? recExpandedW : expW) : islandW }
    var shapeH: CGFloat { expanded ? expH : islandH }
    var panelW: CGFloat { max(islandW, min(limit, baseWidth + 430)) + 48 } // room for the widest tool's options
    var panelH: CGFloat { islandH + 6 + 74 + 100 + 28 } // island + gap + 2-row max + dropdown + tooltip band
    var shapeRectInView: CGRect {
        CGRect(x: (panelW - shapeW) / 2, y: panelH - shapeH, width: shapeW, height: shapeH)
    }

    var limit: CGFloat { (screen?.frame.width ?? 1280) - 40 }
    var baseWidth: CGFloat { 420 }
    var optionsWidth: CGFloat {
        switch s.tool {
        case .pickColour: 150
        case .measure: 110
        case .recRegion, .recWindow, .recScreen: 430
        default: 0
        }
    }
    var compactOptionsWidth: CGFloat {
        switch s.tool {
        case .recRegion, .recWindow, .recScreen: 260
        default: optionsWidth
        }
    }
    var compact: Bool { baseWidth + optionsWidth > limit }
    var twoRows: Bool { baseWidth + compactOptionsWidth > limit }

    func syncHit() {
        ToolbarHit.rect = s.workflowMenuOpen ? shapeRectInView.union(menuRectInView) : shapeRectInView
        if expanded {
            var xs = [Tool.capRegion, .capWindow, .capScreen, .recRegion, .recWindow, .recScreen, .pickColour, .copyText, .measure]
                .map { "\($0.title):\(Int(iconCenterX($0)))" }.joined(separator: " ")
            if s.tool?.kind == .rec { xs += " countdown3:\(Int(iconCenterX(.measure) + 195))" }
            ProtoLog.line("toolbar icons @ \(xs)")
        }
    }
    // screen-x of a Tool button's centre inside the expanded row, for test driving
    func iconCenterX(_ t: Tool) -> CGFloat {
        var px: CGFloat = 0
        let bw: CGFloat = 28, div: CGFloat = 13
        let groups: [[Tool]] = [[.capRegion, .capWindow, .capScreen], [.recRegion, .recWindow, .recScreen], [.pickColour, .copyText, .measure]]
        var local: CGFloat = 0
        for g in groups {
            if let i = g.firstIndex(of: t) { local = px + CGFloat(i) * bw + bw / 2; break }
            px += CGFloat(g.count) * bw + div
        }
        let sc = screen ?? NSScreen.main!
        let shapeX = sc.frame.midX - shapeW / 2
        // content (fixedSize) is centred inside the shape
        let contentW = CGFloat(3 * 28 + 13) * 3 - 13 + 130 + (compact ? compactOptionsWidth : optionsWidth)
        return shapeX + (shapeW - contentW) / 2 + 14 + local
    }

    var body: some View {
        VStack(spacing: 0) {
            morph
            if s.workflowMenuOpen {
                workflowMenu.padding(.top, 4)
            }
            if let tip, !s.workflowMenuOpen {
                Text(tip).font(.system(size: 11)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.black.opacity(0.85), in: .rect(cornerRadius: 6))
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(width: panelW, height: panelH)
        .onAppear { syncHit() }
        .onChange(of: expanded) { syncHit() }
        .onChange(of: s.tool) { s.workflowMenuOpen = false; syncHit() }
        .onChange(of: s.workflowMenuOpen) { syncHit() }
    }

    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0,
                               bottomLeadingRadius: expanded ? 18 : 13,
                               bottomTrailingRadius: expanded ? 18 : 13,
                               topTrailingRadius: 0)
    }

    var morph: some View {
        ZStack(alignment: .top) {
            expandedContent
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.7, anchor: .top)
            islandContent
                .opacity(expanded ? 0 : 1)
        }
        .frame(width: shapeW, height: shapeH)
        .glassEffect(.regular.tint(.black.opacity(0.4)).interactive(), in: shape)
        .glassEffectID("pill", in: ns)
        .overlay(shape.fill(Color.black).opacity(expanded ? 0 : 1).allowsHitTesting(false))
        .contentShape(shape)
        .onHover { h in ProtoLog.line("hover -> \(h)"); s.toolbarExpanded = h }
        .animation(.spring(duration: 0.35), value: expanded)
    }

    // black island contents: current Tool icon (or recording dot + time)
    @ViewBuilder var islandContent: some View {
        if recording {
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(fmtT(s.recordingElapsed)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.white)
            }
        } else {
            Image(systemName: (s.tool ?? .capRegion).symbol)
                .font(.system(size: 13)).foregroundStyle(.white)
        }
    }

    @ViewBuilder var expandedContent: some View {
        if recording { recControls } else { toolbarRows }
    }

    var recControls: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(fmtT(s.recordingElapsed)).font(.system(size: 12)).monospacedDigit()
            Button(s.recordingPaused ? "Resume" : "Pause") { AppDelegate.shared?.togglePause() }
            Button("Stop") { AppDelegate.shared?.stopRecording() }
        }
        .font(.system(size: 12))
        .padding(.top, islandH + 6)
    }

    func setTip(_ text: String, _ on: Bool) {
        if !on {
            if tip == text { tip = nil }
            tipTask?.cancel(); tipTask = nil
            return
        }
        tipTask?.cancel()
        tipTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            tip = text
        }
    }

    // Map an x position inside the expanded row to a Tool/button label for the
    // tooltip (hover state per-button is unreliable inside the glass container).
    func tipFor(x: CGFloat) -> String? {
        var px: CGFloat = 0
        let bw: CGFloat = 28, div: CGFloat = 13
        let caps: [Tool] = [.capRegion, .capWindow, .capScreen]
        let recs: [Tool] = [.recRegion, .recWindow, .recScreen]
        let utils: [Tool] = [.pickColour, .copyText, .measure]
        let x0 = x
        if x0 < 0 { return nil }
        if x0 < 3 * bw { let t = caps[Int(x0 / bw)]; return t.title + (t.shortcut.map { " " + $0 } ?? "") }
        px = 3 * bw + div
        if x0 < px + 3 * bw { let t = recs[Int((x0 - px) / bw)]; return t.title + (t.shortcut.map { " " + $0 } ?? "") }
        px += 3 * bw + div
        if x0 < px + 3 * bw { let t = utils[Int((x0 - px) / bw)]; return t.title }
        px += 3 * bw + div
        if x0 < px + 130 { return "Workflow" }
        return nil
    }

    func tbtn(_ t: Tool) -> some View {
        Button { AppDelegate.shared?.trigger(t) } label: {
            Image(systemName: t.symbol).font(.system(size: 13)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(s.tool == t ? Color.white : Color.white.opacity(0.7))
        .background(s.tool == t ? Color.white.opacity(0.25) : .clear, in: .rect(cornerRadius: 7))
    }

    var toolbarRows: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0).frame(height: islandH + 6)
            HStack(spacing: 2) {
                ForEach([Tool.capRegion, .capWindow, .capScreen], id: \.self, content: tbtn)
                Divider().frame(height: 18).padding(.horizontal, 5)
                ForEach([Tool.recRegion, .recWindow, .recScreen], id: \.self, content: tbtn)
                Divider().frame(height: 18).padding(.horizontal, 5)
                ForEach([Tool.pickColour, .copyText, .measure], id: \.self, content: tbtn)
                Divider().frame(height: 18).padding(.horizontal, 5)
                workflowPicker
                if !twoRows { options }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    if let label = tipFor(x: p.x) {
                        if tip != label { ProtoLog.line("hover x=\(Int(p.x)) -> \(label)") }
                        setTip(label, true)
                    }
                case .ended:
                    tip = nil; tipTask?.cancel()
                }
            }
            if twoRows { HStack { options } }
        }
        .padding(.horizontal, 14)
        .fixedSize()
    }

    var workflowPicker: some View {
        HStack(spacing: 4) {
            if s.tool?.kind == .util {
                Text("No Workflow").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            } else {
                Button { tip = nil; s.workflowMenuOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(s.effectiveWorkflow ?? "Workflow").font(.system(size: 11))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }
    // dropdown rendered inside the toolbar panel, below the shape
    var menuW: CGFloat { 200 }
    var menuH: CGFloat { CGFloat(s.workflows.count) * 26 + 12 }
    var menuRectInView: CGRect {
        // anchored under the toolbar's bottom edge, right-aligned to the picker
        let x = min(max(4, shapeRectInView.maxX - 16 - menuW), panelW - menuW - 4)
        return CGRect(x: x, y: panelH - shapeH - menuH - 4, width: menuW, height: menuH)
    }
    var workflowMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(s.workflows, id: \.self) { w in
                Button {
                    s.workflow = w; s.workflowMenuOpen = false
                } label: {
                    Text(w).font(.system(size: 12)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(w == s.effectiveWorkflow ? Color.white.opacity(0.15) : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: menuW)
        .background(Color.black.opacity(0.9), in: .rect(cornerRadius: 8))
    }

    func iconToggle(_ on: Binding<Bool>, _ symbol: String, _ label: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(on.wrappedValue ? Color.white : Color.white.opacity(0.45))
        .background(on.wrappedValue ? Color.white.opacity(0.22) : .clear, in: .rect(cornerRadius: 6))
        .onHover { setTip(label, $0) }
    }

    @ViewBuilder var options: some View {
        switch s.tool {
        case .pickColour:
            Picker("", selection: $s.colourFmt) {
                ForEach(["Hex", "RGB", "HSL"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).fixedSize()
            .onHover { setTip("Colour Format", $0) }
        case .measure:
            Picker("", selection: $s.measureMode) {
                ForEach(["Region", "Line", "Edges X", "Edges Y", "Edges X+Y"], id: \.self) { Text($0) }
            }.pickerStyle(.menu).fixedSize()
            .onHover { setTip("Measure Mode", $0) }
        case .recRegion, .recWindow, .recScreen:
            if compact || twoRows {
                HStack(spacing: 4) {
                    Picker("", selection: $s.countdown) {
                        ForEach(["Off", "3", "5", "10"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).fixedSize()
                    .onHover { setTip("Countdown", $0) }
                    iconToggle($s.sysAudio, "speaker.wave.2", "System Audio")
                    iconToggle($s.mic, "microphone", "Microphone")
                    iconToggle($s.cursor, "cursorarrow.rays", "Cursor")
                    iconToggle($s.clickCircles, "circle.dotted", "Click Circles")
                    iconToggle($s.showIslandWhileRecording, "capsule", "Show Island While Recording")
                }
            } else {
                HStack(spacing: 6) {
                    Picker("", selection: $s.countdown) {
                        ForEach(["Off", "3", "5", "10"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).frame(width: 140)
                    .onHover { setTip("Countdown", $0) }
                    Toggle("Audio", isOn: $s.sysAudio).toggleStyle(.checkbox).font(.system(size: 10))
                    .onHover { setTip("System Audio", $0) }
                    Toggle("Mic", isOn: $s.mic).toggleStyle(.checkbox).font(.system(size: 10))
                    .onHover { setTip("Microphone", $0) }
                    Toggle("Cursor", isOn: $s.cursor).toggleStyle(.checkbox).font(.system(size: 10))
                    .onHover { setTip("Cursor", $0) }
                    Toggle("Island", isOn: $s.showIslandWhileRecording).toggleStyle(.checkbox).font(.system(size: 10))
                    .onHover { setTip("Show Island While Recording", $0) }
                }
            }
        default: EmptyView()
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
    func start(cap: Capture) {
        let t = ToastItem(cap: cap)
        items.insert(t, at: 0)
        relayout()
        AppDelegate.shared?.updateEscHotkey()
        let s = ProtoState.shared
        let wf = s.effectiveWorkflow ?? "Screenshot"
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
        let s = ProtoState.shared
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
    @ObservedObject var s = ProtoState.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PROTOTYPE").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
            Text("phase: \(String(describing: s.phase))  tool: \(s.tool?.title ?? "-")")
            Text("workflow: \(s.effectiveWorkflow ?? "-")")
            Text("colour=\(s.colourFmt) measure=\(s.measureMode) countdown=\(s.countdown)")
            Text("audio=\(s.sysAudio ? "on" : "off")/\(s.mic ? "on" : "off") cursor=\(s.cursor ? "on" : "off") island=\(s.showIslandWhileRecording ? "on" : "off")")
            Text("rec: \(s.phase == .recording ? fmtT(s.recordingElapsed) + (s.recordingPaused ? " (paused)" : "") : "-")")
            Text("clip: \(String(s.lastClipboard.prefix(80)))").lineLimit(2)
            Text("freeze latency: \(s.latencyText)").foregroundStyle(.secondary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .background(Color(nsColor: NSColor(calibratedWhite: 1, alpha: 0.94)))
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
            ProtoLog.line("hotkey \(tool.title): \(err == noErr ? "registered" : "FAILED (\(err))")")
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
