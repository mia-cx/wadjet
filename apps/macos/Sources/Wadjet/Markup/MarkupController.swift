import AppKit
import WadjetKit

/// Owns the Annotations on screen and the Markup panels that draw them —
/// one per display, above apps and the Freeze Frame, below the toolbar.
/// Panels ignore the mouse unless a Markup Tool is armed; an armed Tool takes every click.
@MainActor
final class MarkupController {
    static let shared = MarkupController()
    /// fixed until per-Tool styles land: opaque red, 4 pt
    static let lineStyle = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)
    /// a press shorter than this draws nothing
    static let minLineLength: CGFloat = 1
    private(set) var stack = LayerStack()
    private var draft: Annotation?
    private(set) var armed: Tool?
    private var panels: [MarkupPanel] = []
    var windowNumbers: [Int] { panels.map(\.windowNumber) }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensChanged() }
        }
    }

    /// the want from AppState: a Markup Tool armed while the toolbar is up —
    /// called from the phase/tool didSets, so it runs on every state change
    func syncArmed() {
        let s = AppState.shared
        let want: Tool? = s.toolbarOpen && s.tool?.kind == .markup && s.tool?.isAction != true ? s.tool : nil
        guard want != armed else { return }
        let was = armed
        armed = want
        if want == nil { draft = nil }
        syncPanels()
        for p in panels { p.ignoresMouseEvents = want == nil }
        if let want {
            raise()
            // arming on the live toolbar: remember whose focus we took, and
            // take activation the same way showPanels does — only the ACTIVE
            // app's cursor changes reach the screen
            if s.phase == .toolbar, let oc = AppDelegate.shared?.overlayCtrl,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
                if oc.prevFrontmost == nil { oc.prevFrontmost = NSWorkspace.shared.frontmostApplication }
                NSApp.activate(ignoringOtherApps: true)
                AppLog.line("active for markup (was \(oc.prevFrontmost?.localizedName ?? "?"))")
            }
            panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.makeKey()
            WadjetCursors.cursor(for: want).set()
            AppLog.line("markup: armed \(want.title)")
        } else {
            if s.phase == .frozen, let oc = AppDelegate.shared?.overlayCtrl {
                // the Freeze Frame owns the pointer's cursor again
                oc.panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.makeKey()
                oc.refreshCursors()
            } else {
                AppDelegate.shared?.overlayCtrl.handBackActivation()
            }
            AppLog.line("markup: disarmed\(was.map { " \($0.title)" } ?? "")")
        }
        render()
    }

    /// panels exist only while there's something to show or take clicks for
    func syncPanels() {
        guard armed != nil || draft != nil || !stack.isEmpty else {
            panels.forEach { $0.close() }; panels = []; return
        }
        guard panels.isEmpty else { return }
        panels = NSScreen.screens.map { sc in
            let p = MarkupPanel(screen: sc)
            p.ignoresMouseEvents = armed == nil
            p.orderFrontRegardless()
            return p
        }
    }

    /// above whatever is up — the Freeze Frame included
    func raise() { panels.forEach { $0.orderFrontRegardless() } }

    /// display hotplug: rebuild the panels on the new screen set
    func screensChanged() {
        panels.forEach { $0.close() }; panels = []
        syncPanels()
        for p in panels { p.ignoresMouseEvents = armed == nil }
        render(); raise()
    }

    func clear() {
        stack.clear(); draft = nil; syncPanels(); render()
    }

    // strokes arrive as global screen points from MarkupView
    func begin(at p: CGPoint) {
        guard armed == .draw else { return }
        draft = Annotation(kind: .line(start: p, end: p), style: Self.lineStyle)
        render()
    }
    func drag(to p: CGPoint) {
        guard case let .line(start, _) = draft?.kind else { return }
        draft?.kind = .line(start: start, end: p)
        render()
    }
    func end() {
        if let d = draft, case let .line(start, end) = d.kind,
           hypot(end.x - start.x, end.y - start.y) >= Self.minLineLength {
            stack.add(d)
        }
        draft = nil
        render()
    }

    func render() {
        let shown = stack.annotations + [draft].compactMap { $0 }
        for p in panels { p.view.show(shown) }
    }
}
