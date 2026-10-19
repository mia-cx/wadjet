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

    /// true for the screen's shared Markup; an Editor's draws on its own surface
    private let isScreen: Bool
    private(set) var stack = LayerStack()
    private(set) var armed: Tool?
    /// a drag in flight; the Annotation payload is the state at drag start, so long drags don't drift
    @ObservationIgnored private var gesture: Gesture?
    /// every committed change is one undo step
    @ObservationIgnored private var history = LayerHistory()
    /// an Editor's canvas view; the screen draws on its per-display panels instead
    @ObservationIgnored weak var surface: MarkupView?
    /// an Editor's undo steps go to its document; the screen keeps LayerHistory
    @ObservationIgnored weak var undoManager: UndoManager?
    /// on-screen points per Annotation point — the Editor's zoom; grips and hit
    /// slop divide by it so they keep their on-screen size
    @ObservationIgnored var zoom: CGFloat = 1
    /// an Editor's snap targets end at the Canvas bounds; nil snaps against the live screen
    @ObservationIgnored var snapBounds: CGRect?

    /// the rect a Magnify places its magnifier against — the Editor's Canvas
    /// bounds when set, else the display under `p`
    private func placementBounds(around p: CGPoint) -> CGRect {
        snapBounds ?? NSScreen.screens.first { $0.frame.contains(p) }?.frame
            ?? NSScreen.main?.frame ?? .zero
    }
    /// the stack when the drag in flight began — its one undo step
    @ObservationIgnored private var gestureStart: LayerStack?
    enum Gesture {
        case drawing(Annotation, from: CGPoint)
        case pen
        case moving(Annotation, from: CGPoint)
        /// a Magnify grabbed outside its magnifier box: the source moves, the
        /// magnifier stays put
        case movingSource(Annotation, from: CGPoint)
        case handle(SelectionHandle, Annotation, from: CGPoint)
    }
    /// an in-progress Pen path and the pointer's latest position for its preview
    @ObservationIgnored private var pen: (builder: PenBuilder, id: Annotation.ID, style: AnnotationStyle)?
    @ObservationIgnored private var penHover: CGPoint?
    /// the in-progress stroke or Pen path, for syncPanels/render
    var draft: Annotation? {
        if case let .drawing(a, _) = gesture { return a }
        guard let pen else { return nil }
        // mid-press the handles are being pulled — a stale hover node would
        // draw a phantom segment; the hover preview only matters between presses
        if case .pen = gesture {
            return Annotation(id: pen.id, kind: .path(pen.builder.path), style: pen.style)
        }
        let hover = penHover ?? pen.builder.path.nodes.last?.anchor ?? .zero
        return Annotation(id: pen.id, kind: .path(pen.builder.preview(to: hover)), style: pen.style)
    }
    /// set by Option-click on a counter: the value the next click places
    @ObservationIgnored private var counterNext: Int?
    private(set) var selection: Annotation.ID? {
        didSet {
            if isScreen, selection == nil, AppState.shared.openMenu?.kind == .markup {
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
    /// what the panels drew last — the Recording reads it off the main actor for window-frame compositing
    nonisolated static let onScreen = AnnotationSnapshot()

    private init() {
        isScreen = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensChanged() }
        }
        ScreenSamples.shared.onChange = { [weak self] in self?.syncSampled() }
    }
    /// a fresh sample or a lost stream: every panel re-syncs its sampled layers
    private func syncSampled() { for p in panels { p.view.syncSampled() } }

    /// an Editor's Markup over one Canvas's stack: it draws on `surface` and
    /// records undo steps in `undoManager` (its document's), never the screen panels
    init(editing stack: LayerStack) {
        isScreen = false
        self.stack = stack
    }

    /// one action = one undo step; every mutation of `stack` goes through here
    private func edit(_ change: (inout LayerStack) -> Void) {
        let before = stack
        change(&stack)
        record(from: before)
        render()
    }
    /// the drag in flight becomes its one undo step, if it changed anything
    private func commitGesture() {
        if let gestureStart { record(from: gestureStart) }
        gestureStart = nil
    }
    /// one undo step: the screen's LayerHistory, or the Editor document's undo manager
    private func record(from before: LayerStack) {
        guard isScreen else { return registerUndo(restoring: before) }
        history.record(from: before, to: stack)
        endHistoryIfClosed()
    }
    private func registerUndo(restoring before: LayerStack) {
        guard before != stack, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { c in
            MainActor.assumeIsolated {
                let after = c.stack
                c.restore(before)
                c.registerUndo(restoring: after)
            }
        }
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
        closeScroll()
        guard gesture == nil, let s = history.undo(from: stack) else { return }
        restore(s); AppLog.line("markup: undo")
    }
    func redo() {
        closeScroll()
        guard gesture == nil, let s = history.redo(from: stack) else { return }
        restore(s); AppLog.line("markup: redo")
    }
    private func restore(_ s: LayerStack) {
        stack = s
        // gone, hidden, or locked: none of those can stay the selection
        if selected.map({ $0.hidden || $0.locked }) ?? true { selection = nil }
        syncPanels(); render()
    }
    /// replaces the whole stack — a reverted document
    func load(_ s: LayerStack) { gesture = nil; gestureStart = nil; restore(s) }

    /// arms a Tool on an Editor; the screen follows AppState through syncArmed
    func arm(_ tool: Tool?) {
        commitGesture(); gesture = nil
        if tool != armed { finishPen() } // a Tool switch commits any Pen path in progress
        if tool == nil { selection = nil; cmdHeld = false }
        armed = tool
        render()
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
        finishPen() // a Tool switch commits any Pen path in progress
        let was = armed
        armed = want
        if let want { MarkupToolbar.shared.armed(want) } // arming is the one recorded use
        if want == nil {
            commitGesture() // a drag cut short by disarming is still one step
            closeScroll() // an open phased scroll is its own step too
            gesture = nil; selection = nil; cmdHeld = false; snapper = nil; counterNext = nil
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
                guard let self else { return e }
                // Return finishes a Pen path in progress (and only then eats the key)
                if e.keyCode == 36 || e.keyCode == 76, self.finishPen() { return nil }
                guard e.keyCode == 51 || e.keyCode == 117, self.selection != nil else { return e }
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
        guard isScreen else { return }
        guard armed != nil || draft != nil || !stack.isEmpty else {
            panels.forEach { $0.close() }; panels = []; ScreenSamples.shared.stop(); return
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
        ScreenSamples.shared.stop()
        syncPanels()
        for p in panels { p.ignoresMouseEvents = armed == nil }
        render(); raise()
    }

    func clear() {
        commitGesture()
        gesture = nil; snapper = nil; selection = nil; counterNext = nil
        // the Pen preview dies with the stack it wasn't part of — clear it
        // before the edit renders
        pen = nil; penHover = nil
        edit { $0.clear() }
        syncPanels()
    }

    /// adds Annotations as one undo step — Smart Redact's Censors
    func add(_ annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        edit { s in annotations.forEach { s.add($0) } }
        syncPanels(); render()
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
        update(id) { change(&$0.style) }
    }

    /// edits one Annotation by id as a single undo step — for changes that
    /// touch the kind, like a Magnify's border through the eyedropper
    func update(_ id: Annotation.ID, _ change: (inout Annotation) -> Void) {
        guard var a = stack.annotations.first(where: { $0.id == id }) else { return }
        change(&a)
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
        if armed == nil { isScreen ? AppDelegate.shared?.trigger(.select) : arm(.select) }
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

    // strokes arrive as global screen points from MarkupView; `command` =
    // temporary Select, `constrained` = Shift (45° snaps)
    func begin(at p: CGPoint, command: Bool, constrained: Bool = false) {
        closeScroll() // an open phased scroll is its own undo step
        gestureStart = stack
        if armed == .select || command {
            if let sel = selected {
                if let h = sel.handle(at: p, radius: Self.handleHitRadius / zoom,
                                      minExtent: Self.handleMinExtent / zoom,
                                      rotateOffset: Self.rotateOffset / zoom) {
                    snapper = MarkupSnapper(stack: stack, excluding: sel.id, canvasBounds: snapBounds)
                    gesture = .handle(h, sel, from: p)
                    return
                }
                if PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance / zoom) {
                    snapper = MarkupSnapper(stack: stack, excluding: sel.id, canvasBounds: snapBounds)
                    gesture = Self.moveGesture(sel, at: p)
                    return
                }
            }
            if let hit = stack.topmost(at: p, tolerance: Self.hitTolerance / zoom) {
                selection = hit.id
                AppLog.line("markup: selected")
                snapper = MarkupSnapper(stack: stack, excluding: hit.id, canvasBounds: snapBounds)
                gesture = Self.moveGesture(hit, at: p)
            } else {
                selection = nil
            }
            return
        }
        if armed == .draw, MarkupStyles.shared.drawVariant == .pen {
            // Pen: a press adds a node (or closes on the first), a press-drag
            // pulls its handles — the path lives in `pen` until finishPen
            if pen == nil {
                pen = (PenBuilder(), Annotation.ID(), MarkupStyles.shared.style(for: .draw))
            }
            _ = pen?.builder.press(at: p, closeRadius: Self.handleHitRadius, constrained: constrained)
            selection = nil
            gesture = .pen
            render()
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
        case .counter:
            placeCounter(at: p)
            return
        case .magnify:
            a = Annotation(kind: .magnify(.placed(source: CGRect(origin: p, size: .zero),
                                                 options: MarkupMagnify.options,
                                                 on: placementBounds(around: p))),
                           style: MarkupStyles.shared.style(for: .magnify))
        default:
            return
        }
        snapper = MarkupSnapper(stack: stack, excluding: nil, canvasBounds: snapBounds)
        let so = snapper?.offset(points: [p]) ?? .zero
        gesture = .drawing(a.moved(by: so), from: CGPoint(x: p.x + so.dx, y: p.y + so.dy))
        render()
    }

    /// a Step counter click places on the spot — there's no drag. ⌥-click on a
    /// counter makes the next click continue from it; ⌥-click elsewhere starts
    /// a new sequence at 1/A.
    private func placeCounter(at p: CGPoint) {
        let option = NSEvent.modifierFlags.contains(.option)
        if option, case let .counter(_, _, v, f)? = stack.topmost(at: p, tolerance: Self.hitTolerance)?.kind {
            counterNext = v + 1
            // nothing is selected here, so this writes the Tool's format
            AppState.shared.config.update { $0.markup.tools["counter", default: .init()].format = f }
            AppLog.line("markup: counter continues from \(f.label(v))")
            return
        }
        let format = MarkupCounter.format
        let value = option ? 1 : counterNext ?? stack.nextCounterValue(format)
        counterNext = nil
        // the click's own gesture snapshot (begin → end) makes this one undo step
        stack.add(Annotation(kind: .counter(center: p, radius: MarkupCounter.size / 2,
                                          value: value, format: format),
                             style: MarkupStyles.shared.style(for: .counter)))
        render()
        AppLog.line("markup: placed counter \(format.label(value))")
    }
    /// `constrained` = Shift held: drawing and end drags snap to 45°
    func drag(to p: CGPoint, constrained: Bool = false) {
        switch gesture {
        case let .drawing(d, from):
            let so = snapper?.offset(points: [p]) ?? .zero
            let p = CGPoint(x: p.x + so.dx, y: p.y + so.dy)
            var a = d
            switch d.kind {
            case let .line(_, _, bend):
                a.kind = .line(start: from,
                               end: constrained ? PathGeometry.snapAngle(p, from: from) : p,
                               bend: bend)
            case .path: // Pen paths drag through the .pen gesture
                break
            case let .shape(kind, _):
                // ⇧ constrains to a square, ⌥ draws from the centre
                let f = NSEvent.modifierFlags
                a.kind = .shape(kind, rect: CGRect(dragFrom: from, to: p,
                                                   square: f.contains(.shift), fromCentre: f.contains(.option)))
            case let .censor(_, method):
                a.kind = .censor(rect: CGRect(x: from.x, y: from.y, width: p.x - from.x,
                                              height: p.y - from.y).standardized, method: method)
            case .counter: break // counters place on the click — never a draft
            case let .magnify(m):
                // the drag sizes the source; the magnifier re-places beside it
                let source = CGRect(x: from.x, y: from.y, width: p.x - from.x,
                                    height: p.y - from.y).standardized
                let centre = CGPoint(x: source.midX, y: source.midY)
                a.kind = .magnify(.placed(source: source, options: m.options,
                                          on: placementBounds(around: centre)))
            }
            gesture = .drawing(a, from: from)
        case .pen:
            pen?.builder.drag(to: p, constrained: constrained)
            penHover = p // the next hover preview starts from the pointer
        case let .moving(start, from):
            let moved = start.moved(by: CGVector(dx: p.x - from.x, dy: p.y - from.y))
            // a Magnify snaps its magnifier frame, not its whole path's box
            let snapRect = if case .magnify = moved.kind { moved.kind.bounds }
                else { PathGeometry.path(for: moved).boundingBoxOfPath }
            let snapped = snapper?.offset(rect: snapRect) ?? .zero
            stack.replace(moved.moved(by: snapped))
        case let .movingSource(start, from):
            // only the source re-aims; the magnifier box stays where it is
            guard case var .magnify(m) = start.kind else { return }
            let d = CGVector(dx: p.x - from.x, dy: p.y - from.y)
            m.source = m.source.offsetBy(dx: d.dx, dy: d.dy)
            let snapped = snapper?.offset(rect: m.source) ?? .zero
            m.source = m.source.offsetBy(dx: snapped.dx, dy: snapped.dy)
            var a = start
            a.kind = .magnify(m)
            stack.replace(a)
        case let .handle(h, start, from):
            // Shift's 45° constraint wins on point handles: a point snap
            // would leave the ray — vertex ends and Pen tangents both
            let shiftConstrained = switch h { case .vertex, .tangent: true; default: false }
            if constrained, shiftConstrained {
                stack.replace(start.dragging(h, from: from, to: p, constrained: true))
            } else {
                // the grip follows the pointer's delta whether or not it snaps
                stack.replace(snapper?.dragging(start, h, from: from, to: p)
                    ?? start.dragging(h, from: from, to: p,
                                      minExtent: Self.handleMinExtent, rotateOffset: Self.rotateOffset,
                                      targets: [], range: 0, skip: true).annotation)
            }
        case nil:
            return
        }
        render()
    }
    /// commits a Pen path that just closed; other paths wait for Return/Escape
    func end() {
        if case .pen = gesture {
            gesture = nil
            if pen?.builder.path.closed == true { finishPen() } else { render() }
            return
        }
        if case let .drawing(d, _) = gesture {
            let drawn: Bool = switch d.kind {
            case let .line(start, end, _):
                hypot(end.x - start.x, end.y - start.y) >= Self.minDraftSize
            case .path: // Pen paths commit through finishPen, not this gesture
                false
            case let .shape(_, rect), let .censor(rect, _):
                rect.width >= Self.minDraftSize && rect.height >= Self.minDraftSize
            case .counter:
                false // counters place on the click — never a draft
            case let .magnify(m):
                m.source.width >= Self.minDraftSize && m.source.height >= Self.minDraftSize
            }
            if drawn { stack.add(d) }
        }
        commitGesture()
        gesture = nil
        snapper = nil
        render()
    }

    /// ends an in-progress Pen path, keeping it when it has ≥ 2 nodes;
    /// true when one was in progress
    @discardableResult
    func finishPen() -> Bool {
        guard let pen else { return false }
        self.pen = nil; penHover = nil
        // a temporary-Select drag may still be in flight — commit it first so
        // it stays its own undo step and the path inserts above it
        switch gesture {
        case nil, .pen: break
        case .drawing, .moving, .movingSource, .handle: commitGesture()
        }
        if let data = pen.builder.finished {
            let a = Annotation(id: pen.id, kind: .path(data), style: pen.style)
            // the insertion is its own undo step — temporary Select presses
            // mid-path are separate gestures, so the gesture snapshot can't
            // carry this one
            edit { $0.add(a) }
            AppLog.line("markup: finished pen path (\(data.nodes.count) nodes)")
        }
        gestureStart = nil // the path's presses left no drag to commit
        gesture = nil
        syncPanels()
        render()
        return true
    }

    /// the pointer moved: only the Pen rubber-band preview cares
    func hover(at p: CGPoint) {
        guard pen != nil else { return }
        penHover = p
        render()
    }

    /// a press on a Magnify outside its magnifier box drags the source, not the frame
    private static func moveGesture(_ a: Annotation, at p: CGPoint) -> Gesture {
        guard case let .magnify(m) = a.kind,
              !m.options.shape.path(in: m.frame).contains(p) else { return .moving(a, from: p) }
        return .movingSource(a, from: p)
    }

    /// scroll over a selected Magnify's magnifier steps its zoom — a trackpad
    /// gesture is one undo step, each wheel tick its own. A phased scroll
    /// stays with the magnifier it began on even when the pointer leaves it
    /// (Magic Mouse reports events to the view under the resting pointer).
    /// Returns false when it isn't ours so the view can take the event
    @ObservationIgnored private var scrollResidual: CGFloat = 0
    /// the phased scroll in flight, if any — set on `.began`, cleared on end
    @ObservationIgnored private var scrolling: Annotation.ID?
    func scroll(_ e: NSEvent, at p: CGPoint) -> Bool {
        if scrolling != nil, e.phase == .began {
            // a fresh sequence began while ours was still open: the stale
            // one closes as its undo step, then the guard below re-qualifies
            closeScroll()
        }
        if let id = scrolling {
            if e.momentumPhase != [] { return true }
            if e.phase == .ended || e.phase == .cancelled {
                scrolling = nil
                commitGesture()
                return true
            }
            guard let a = stack.annotations.first(where: { $0.id == id }) else {
                scrolling = nil
                commitGesture()
                return true
            }
            return applyScroll(e, to: a)
        }
        guard gesture == nil, let a = selected, case .magnify(let m) = a.kind,
              m.options.shape.path(in: m.frame).contains(p) else { return false }
        if e.momentumPhase != [] { return true } // a trackpad fling isn't input — swallow it
        if e.phase == .began { gestureStart = stack; scrollResidual = 0; scrolling = a.id }
        return applyScroll(e, to: a)
    }
    /// accumulate to whole steps, then step `a`'s zoom — through the open
    /// gesture while a phase sequence is in flight, as its own edit otherwise
    private func applyScroll(_ e: NSEvent, to a: Annotation) -> Bool {
        scrollResidual += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 8 : e.scrollingDeltaY
        let steps = Int(scrollResidual)
        guard steps != 0 else { return true }
        scrollResidual -= CGFloat(steps)
        var a = a
        guard case var .magnify(m) = a.kind else { return true }
        m.zoom = MagnifyZoom.stepped(m.effectiveZoom, by: steps)
        a.kind = .magnify(m)
        if e.phase == [] {
            edit { $0.replace(a) } // a wheel tick is its own undo step
        } else {
            if gestureStart == nil { gestureStart = stack }
            stack.replace(a)
            render()
        }
        return true
    }
    /// an open phased scroll commits as its undo step before anything else
    /// starts — begin/undo/redo would otherwise overwrite `gestureStart`
    private func closeScroll() {
        guard scrolling != nil else { return }
        scrolling = nil
        commitGesture()
    }

    func render() {
        let shown = stack.annotations.filter { !$0.hidden } + [draft].compactMap { $0 }
        guard isScreen else { surface?.show(shown, selection: selected); surface?.showGuides(guides); return }
        Self.onScreen.annotations = shown
        AppDelegate.shared?.recOutput?.overlay?.refresh() // a still recorded window sends no new frame
        ScreenSamples.shared.watch(shown.compactMap(\.sampledRect))
        for p in panels { p.view.show(shown, selection: selected); p.view.showGuides(guides) }
        PeerThrough.shared.sync()
    }

    /// the feathered peer-through hole under the pointer, per panel
    func showPeer(at p: CGPoint?) { for panel in panels { panel.view.peer(at: p) } }
}
