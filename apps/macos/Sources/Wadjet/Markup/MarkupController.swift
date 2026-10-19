import AppKit
import Observation
import WadjetKit

/// Owns the Annotations on screen and the Markup panels that draw them —
/// one per display, above apps and the Freeze Frame, below the toolbar.
/// Panels ignore the mouse unless a Markup Tool is armed; an armed Tool takes every click.
@MainActor @Observable
final class MarkupController {
    static let shared = MarkupController()
    /// a press shorter than this draws nothing
    static let minLineLength: CGFloat = 1
    static let handleSize: CGFloat = 7      // grip diameter, on-screen points
    static let handleHitRadius: CGFloat = 6
    static let rotateOffset: CGFloat = 20   // rotate grip's distance above the frame
    static let handleMinExtent: CGFloat = 12
    static let hitTolerance: CGFloat = 4

    private(set) var stack = LayerStack()
    private(set) var armed: Tool?
    /// a drag in flight; the Annotation payload is the state at drag start, so long drags don't drift
    @ObservationIgnored private var gesture: Gesture?
    enum Gesture {
        case drawing(Annotation)
        case moving(Annotation, from: CGPoint)
        case handle(SelectionHandle, Annotation, from: CGPoint)
    }
    /// the in-progress stroke, for syncPanels/render
    var draft: Annotation? { if case let .drawing(a) = gesture { a } else { nil } }
    private(set) var selection: Annotation.ID? {
        didSet {
            if selection == nil, AppState.shared.openMenu?.kind == .markup {
                AppState.shared.openMenu = nil
                AppDelegate.shared?.overlayCtrl.syncMenu()
            }
            render()
        }
    }
    var selected: Annotation? { selection.flatMap { id in stack.annotations.first { $0.id == id } } }
    /// ⌘ held turns any armed Markup Tool into Select until release
    @ObservationIgnored var cmdHeld = false
    var selecting: Bool { armed == .select || cmdHeld }

    @ObservationIgnored private var panels: [MarkupPanel] = []
    @ObservationIgnored private var flagsMon: Any?
    @ObservationIgnored private var keyMon: Any?
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
        PeerThrough.shared.sync()
        let s = AppState.shared
        let want: Tool? = s.toolbarOpen && s.tool?.kind == .markup && s.tool?.isAction != true ? s.tool : nil
        guard want != armed else { return }
        let was = armed
        armed = want
        if want == nil {
            gesture = nil; selection = nil; cmdHeld = false
            if let m = flagsMon { NSEvent.removeMonitor(m); flagsMon = nil }
            if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        } else if flagsMon == nil {
            // ⌘ = temporary Select; Delete removes the selection — installed on
            // entering the armed session, kept across Tool switches within it
            flagsMon = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                guard let self else { return e }
                self.cmdHeld = e.modifierFlags.contains(.command)
                if AppDelegate.shared?.overlayCtrl.pointerOverUI != true {
                    self.panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.view.setToolCursor()
                }
                return e
            }
            keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.keyCode == 51 || e.keyCode == 117, self.selection != nil else { return e }
                self.deleteSelection()
                return nil
            }
        }
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
        stack.clear(); gesture = nil; selection = nil; syncPanels(); render()
    }

    /// the selected Annotation's style; setting restyles it alone — the seam the
    /// Tool menu's style tiles hook into
    var selectedStyle: AnnotationStyle? {
        get { selected?.style }
        set {
            guard var a = selected, let newValue else { return }
            a.style = newValue
            stack.replace(a); render()
            AppLog.line("markup: restyled selection")
        }
    }

    /// restyles one Annotation by id — the eyedropper's target, whose selection Pick Colour's disarm cleared
    func restyle(_ id: Annotation.ID, _ change: (inout AnnotationStyle) -> Void) {
        guard var a = stack.annotations.first(where: { $0.id == id }) else { return }
        change(&a.style)
        stack.replace(a); render()
        AppLog.line("markup: restyled selection")
    }

    /// apply a value transform (rotate/flip) to the selection
    func transformSelection(_ f: (Annotation) -> Annotation) {
        guard let a = selected else { return }
        stack.replace(f(a)); render()
        AppLog.line("markup: transformed selection")
    }

    /// true when there was a selection to drop
    @discardableResult
    func deselect() -> Bool {
        guard selection != nil else { return false }
        selection = nil
        AppLog.line("markup: deselected")
        return true
    }

    func deleteSelection() {
        guard let id = selection else { return }
        stack.remove(id: id); selection = nil
        AppLog.line("markup: deleted selection")
    }

    // strokes arrive as global screen points from MarkupView; `command` = temporary Select
    func begin(at p: CGPoint, command: Bool) {
        if armed == .select || command {
            if let sel = selected {
                if let h = sel.handle(at: p, radius: Self.handleHitRadius,
                                      minExtent: Self.handleMinExtent, rotateOffset: Self.rotateOffset) {
                    gesture = .handle(h, sel, from: p)
                    return
                }
                if PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance) {
                    gesture = .moving(sel, from: p)
                    return
                }
            }
            if let hit = stack.topmost(at: p, tolerance: Self.hitTolerance) {
                selection = hit.id
                AppLog.line("markup: selected")
                gesture = .moving(hit, from: p)
            } else {
                selection = nil
            }
            return
        }
        guard armed == .draw else { return }
        selection = nil
        gesture = .drawing(Annotation(kind: .line(start: p, end: p), style: MarkupStyles.shared.style(for: .draw)))
        render()
    }
    func drag(to p: CGPoint) {
        switch gesture {
        case let .drawing(d):
            guard case let .line(start, _) = d.kind else { return }
            gesture = .drawing(Annotation(id: d.id, kind: .line(start: start, end: p), style: d.style))
        case let .moving(start, from):
            stack.replace(start.moved(by: CGVector(dx: p.x - from.x, dy: p.y - from.y)))
        case let .handle(h, start, from):
            stack.replace(start.dragging(h, from: from, to: p))
        case nil:
            return
        }
        render()
    }
    func end() {
        if case let .drawing(d) = gesture, case let .line(start, end) = d.kind,
           hypot(end.x - start.x, end.y - start.y) >= Self.minLineLength {
            stack.add(d)
        }
        gesture = nil
        render()
    }

    func render() {
        let shown = stack.annotations + [draft].compactMap { $0 }
        for p in panels { p.view.show(shown, selection: selected) }
        PeerThrough.shared.sync()
    }

    /// the feathered peer-through hole under the pointer, per panel
    func showPeer(at p: CGPoint?) { for panel in panels { panel.view.peer(at: p) } }
}
