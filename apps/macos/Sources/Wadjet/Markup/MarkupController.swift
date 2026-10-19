import AppKit
import Observation
import WadjetKit

/// Owns the Annotations on screen and the Markup panels that draw them —
/// one per display, above apps and the Freeze Frame, below the toolbar.
/// Panels ignore the mouse unless a Markup Tool is armed; an armed Tool takes every click.
@MainActor @Observable
final class MarkupController {
    static let shared = MarkupController()
    /// a press that drags less than this draws nothing
    static let minDraftSize: CGFloat = 1
    static let handleSize: CGFloat = 7      // grip diameter, on-screen points
    static let handleHitRadius: CGFloat = 6
    static let rotateOffset: CGFloat = 20   // rotate grip's distance above the frame
    static let handleMinExtent: CGFloat = 12
    static let hitTolerance: CGFloat = 4

    private(set) var stack = LayerStack()
    private(set) var armed: Tool?
    /// a drag in flight; the Annotation payload is the state at drag start, so long drags don't drift
    @ObservationIgnored private var gesture: Gesture?
    /// every committed change is one undo step
    @ObservationIgnored private var history = LayerHistory()
    /// the stack when the drag in flight began — its one undo step
    @ObservationIgnored private var gestureStart: LayerStack?
    enum Gesture {
        case drawing(Annotation, from: CGPoint)
        case moving(Annotation, from: CGPoint)
        case handle(SelectionHandle, Annotation, from: CGPoint)
    }
    /// the in-progress stroke, for syncPanels/render
    var draft: Annotation? { if case let .drawing(a, _) = gesture { a } else { nil } }
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

    /// the gesture's snapping state; nil between gestures and while Snapping is off
    @ObservationIgnored private var snapper: MarkupSnapper?
    var guides: [SnapGuide] { snapper?.guides ?? [] }

    @ObservationIgnored private var panels: [MarkupPanel] = []
    @ObservationIgnored private var flagsMon: Any?
    @ObservationIgnored private var keyMon: Any?
    var windowNumbers: [Int] {
        panels.map(\.windowNumber) + (LayersWindow.shared.windowNumber.map { [$0] } ?? [])
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensChanged() }
        }
    }

    /// one action = one undo step; every mutation of `stack` goes through here
    private func edit(_ change: (inout LayerStack) -> Void) {
        let before = stack
        change(&stack)
        history.record(from: before, to: stack)
        endHistoryIfClosed()
        render()
    }
    /// the drag in flight becomes its one undo step, if it changed anything
    private func commitGesture() {
        if let gestureStart { history.record(from: gestureStart, to: stack) }
        gestureStart = nil
    }
    /// history ends once the stack is empty and the session is closed — Clear
    /// can run after the toolbar closes (Clear after Screenshot), so edits check too
    private func endHistoryIfClosed() {
        if !AppState.shared.toolbarOpen { history.end(ifCleared: stack) }
    }
    /// Carbon command keys and the Layers window track the toolbar; call on
    /// every phase/tool change
    func syncSession() {
        MarkupKeys.shared.sync(active: AppState.shared.toolbarOpen)
        LayersWindow.shared.sync()
        endHistoryIfClosed()
    }

    func undo() {
        guard gesture == nil, let s = history.undo(from: stack) else { return }
        restore(s); AppLog.line("markup: undo")
    }
    func redo() {
        guard gesture == nil, let s = history.redo(from: stack) else { return }
        restore(s); AppLog.line("markup: redo")
    }
    private func restore(_ s: LayerStack) {
        stack = s
        // gone, hidden, or locked: none of those can stay the selection
        if selected.map({ $0.hidden || $0.locked }) ?? true { selection = nil }
        syncPanels(); render()
    }

    /// the want from AppState: a Markup Tool armed while the toolbar is up —
    /// called from the phase/tool didSets, so it runs on every state change
    func syncArmed() {
        syncSession()
        PeerThrough.shared.sync()
        let s = AppState.shared
        let want: Tool? = s.toolbarOpen && s.tool?.kind == .markup && s.tool?.isAction != true ? s.tool : nil
        guard want != armed else {
            // same Tool but the phase may have changed: sampling Censors swap
            // between the Freeze Frame and the live stream on every render
            render()
            return
        }
        let was = armed
        armed = want
        if let want { MarkupToolbar.shared.armed(want) } // arming is the one recorded use
        if want == nil {
            commitGesture() // a drag cut short by disarming is still one step
            gesture = nil; selection = nil; cmdHeld = false; snapper = nil
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
                // ⇧/⌥ mid-drag reshape a Shapes draft without the pointer moving
                if case .drawing = self.gesture { self.drag(to: NSEvent.mouseLocation) }
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
        commitGesture()
        edit { $0.clear() }
        gesture = nil; snapper = nil; selection = nil; syncPanels()
    }

    /// the selected Annotation's style; setting restyles it alone — the seam the
    /// Tool menu's style tiles hook into
    var selectedStyle: AnnotationStyle? {
        get { selected?.style }
        set {
            guard var a = selected, let newValue else { return }
            a.style = newValue
            edit { $0.replace(a) }
            AppLog.line("markup: restyled selection")
        }
    }

    /// restyles one Annotation by id — the eyedropper's target, whose selection Pick Colour's disarm cleared
    func restyle(_ id: Annotation.ID, _ change: (inout AnnotationStyle) -> Void) {
        guard var a = stack.annotations.first(where: { $0.id == id }) else { return }
        change(&a.style)
        edit { $0.replace(a) }
        AppLog.line("markup: restyled selection")
    }

    /// apply a value transform (rotate/flip) to the selection
    func transformSelection(_ f: (Annotation) -> Annotation) {
        guard let a = selected else { return }
        edit { $0.replace(f(a)) }
        AppLog.line("markup: transformed selection")
    }

    /// ⌘] / ⌘[ / ⇧⌘] / ⇧⌘[ move the selection through the stack
    func restackSelection(_ move: LayerStack.Restack) {
        guard let id = selection else { return }
        edit { $0.restack(id, move) }
        AppLog.line("markup: restacked selection \(move)")
    }

    /// the Layers window's drag: `index` is back-to-front
    func moveLayer(_ id: Annotation.ID, to index: Int) {
        edit { $0.move(id, to: index) }
    }

    /// hide/lock from the Layers window — a hidden or locked selection can't stay selected
    func update(_ a: Annotation) {
        edit { $0.replace(a) }
        if a.hidden || a.locked, selection == a.id { selection = nil }
    }

    /// the Layers window's row tap: nil deselects; a real id arms Select first
    /// if nothing is armed, then selects — hidden and locked Annotations refuse
    func select(_ id: Annotation.ID?) {
        guard let id else { deselect(); return }
        guard let a = stack.annotations.first(where: { $0.id == id }), !a.hidden, !a.locked else { return }
        if armed == nil { AppDelegate.shared?.trigger(.select) }
        if armed != nil { selection = id }
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
        edit { $0.remove(id: id) }
        selection = nil
        AppLog.line("markup: deleted selection")
    }

    // strokes arrive as global screen points from MarkupView; `command` = temporary Select
    func begin(at p: CGPoint, command: Bool) {
        gestureStart = stack
        if armed == .select || command {
            if let sel = selected {
                if let h = sel.handle(at: p, radius: Self.handleHitRadius,
                                      minExtent: Self.handleMinExtent, rotateOffset: Self.rotateOffset) {
                    snapper = MarkupSnapper(stack: stack, excluding: sel.id)
                    gesture = .handle(h, sel, from: p)
                    return
                }
                if PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance) {
                    snapper = MarkupSnapper(stack: stack, excluding: sel.id)
                    gesture = .moving(sel, from: p)
                    return
                }
            }
            if let hit = stack.topmost(at: p, tolerance: Self.hitTolerance) {
                selection = hit.id
                AppLog.line("markup: selected")
                snapper = MarkupSnapper(stack: stack, excluding: hit.id)
                gesture = .moving(hit, from: p)
            } else {
                selection = nil
            }
            return
        }
        selection = nil // a new Annotation takes the Tool's style and options, not the selection's
        let a: Annotation
        switch armed {
        case .draw:
            a = Annotation(kind: .line(start: p, end: p), style: MarkupStyles.shared.style(for: .draw))
        case .shapes:
            a = Annotation(kind: .shape(MarkupShapes.shape(for: MarkupShapes.variant), rect: CGRect(origin: p, size: .zero)),
                           style: MarkupStyles.shared.style(for: .shapes))
        case .censor:
            a = Annotation(kind: .censor(rect: CGRect(origin: p, size: .zero),
                                         method: MarkupStyles.shared.censorMethod),
                           style: MarkupStyles.shared.style(for: .censor))
        default:
            return
        }
        snapper = MarkupSnapper(stack: stack, excluding: nil)
        let so = snapper?.offset(points: [p]) ?? .zero
        gesture = .drawing(a.moved(by: so), from: CGPoint(x: p.x + so.dx, y: p.y + so.dy))
        render()
    }
    func drag(to p: CGPoint) {
        switch gesture {
        case let .drawing(d, from):
            let so = snapper?.offset(points: [p]) ?? .zero
            let p = CGPoint(x: p.x + so.dx, y: p.y + so.dy)
            var a = d
            switch d.kind {
            case .line:
                a.kind = .line(start: from, end: p)
            case let .shape(kind, _):
                // ⇧ constrains to a square, ⌥ draws from the centre
                let f = NSEvent.modifierFlags
                a.kind = .shape(kind, rect: CGRect(dragFrom: from, to: p,
                                                   square: f.contains(.shift), fromCentre: f.contains(.option)))
            case let .censor(_, method):
                a.kind = .censor(rect: CGRect(x: from.x, y: from.y, width: p.x - from.x,
                                              height: p.y - from.y).standardized, method: method)
            }
            gesture = .drawing(a, from: from)
        case let .moving(start, from):
            let moved = start.moved(by: CGVector(dx: p.x - from.x, dy: p.y - from.y))
            let snapped = snapper?.offset(rect: PathGeometry.path(for: moved).boundingBoxOfPath) ?? .zero
            stack.replace(moved.moved(by: snapped))
        case let .handle(h, start, from):
            // the grip follows the pointer's delta whether or not it snaps
            stack.replace(snapper?.dragging(start, h, from: from, to: p)
                ?? start.dragging(h, from: from, to: p,
                                  minExtent: Self.handleMinExtent, rotateOffset: Self.rotateOffset,
                                  targets: [], range: 0, skip: true).annotation)
        case nil:
            return
        }
        render()
    }
    func end() {
        if case let .drawing(d, _) = gesture {
            let drawn: Bool = switch d.kind {
            case let .line(start, end):
                hypot(end.x - start.x, end.y - start.y) >= Self.minDraftSize
            case let .shape(_, rect), let .censor(rect, _):
                rect.width >= Self.minDraftSize && rect.height >= Self.minDraftSize
            }
            if drawn { stack.add(d) }
        }
        commitGesture()
        gesture = nil
        snapper = nil
        render()
    }

    func render() {
        let shown = stack.annotations.filter { !$0.hidden } + [draft].compactMap { $0 }
        for p in panels { p.view.show(shown, selection: selected); p.view.showGuides(guides) }
        PeerThrough.shared.sync()
    }

    /// the feathered peer-through hole under the pointer, per panel
    func showPeer(at p: CGPoint?) { for panel in panels { panel.view.peer(at: p) } }
}
