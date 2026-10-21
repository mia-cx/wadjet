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
    /// pasted/dropped images: white (the Auto border is difference anyway), one point
    static let imageStyle = AnnotationStyle(colour: RGBAColour(red: 1, green: 1, blue: 1, alpha: 1),
                                            width: ImagePlacement.borderWidth)

    /// true for the screen's shared Markup; an Editor's draws on its own surface
    let isScreen: Bool
    private(set) var stack = LayerStack()
    private(set) var armed: Tool?
    /// a drag in flight; the Annotation payload is the state at drag start, so long drags don't drift
    @ObservationIgnored var gesture: Gesture?
    /// the pixels and Canvases this Markup's image kinds draw from
    let assets = MarkupAssets()
    /// every committed change is one undo step
    @ObservationIgnored private var history = LayerHistory()
    /// what a Clear left undoable, and for how long (MarkupClear.swift)
    var clearUndo = ClearUndo()
    /// the toolbar's Clear cell reads Undo; refreshed at each change of clearUndo
    var undoOffered = false
    /// the collapsed island shows the Clear's draining Undo ring
    var undoRingShown = false
    @ObservationIgnored var clearUndoWake: Task<Void, Never>?
    /// the displays whose island or toolbar has the pointer on it
    @ObservationIgnored var hoveredIslands: Set<Int> = []
    /// a Clear's fade is running; its clear lands when the fade ends
    @ObservationIgnored var clearInFlight = false
    /// an Editor's canvas view; the screen draws on its per-display panels instead
    @ObservationIgnored weak var surface: MarkupView?
    /// an Editor's undo steps go to its document; the screen keeps LayerHistory
    @ObservationIgnored weak var undoManager: UndoManager?
    /// the Editor document this controller feeds — set with `undoManager`;
    /// lets unrecorded text edits dirty it so an unsaved close can't lose them
    @ObservationIgnored weak var document: NSDocument?
    /// on-screen points per Annotation point — the Editor's zoom; grips and hit
    /// slop divide by it so they keep their on-screen size
    @ObservationIgnored var zoom: CGFloat = 1
    /// an Editor's snap targets end at the Canvas bounds; nil snaps against the live screen
    @ObservationIgnored var snapBounds: CGRect?
    /// An Editor supplies its Canvas display pixels at gesture start.
    @ObservationIgnored var snapPixelSources: (() -> [MarkupPixelEdges])?

    /// the rect a Magnify places its magnifier against — the Editor's Canvas
    /// bounds when set, else the display under `p`
    private func placementBounds(around p: CGPoint) -> CGRect {
        snapBounds ?? NSScreen.screens.first { $0.frame.contains(p) }?.frame
            ?? NSScreen.main?.frame ?? .zero
    }
    /// an Editor's window layers by id: `.window` Annotations draw their image,
    /// the Layers window names them; the screen's stays empty
    @ObservationIgnored var windowLayers: [UUID: CanvasWindowLayer] = [:]
    /// the stack when the drag in flight began — its one undo step
    @ObservationIgnored var gestureStart: LayerStack?
    enum Gesture {
        case drawing(Annotation, from: CGPoint)
        case pen
        /// a Brush stroke collecting samples; the Annotation is its live preview
        case brush(Annotation, raw: [CGPoint])
        /// an Eraser drag; the sweep's `marked` is what release removes
        case erasing(EraserSweep)
        /// a Knife cut in flight; release cuts along the segment
        case cutting(from: CGPoint, to: CGPoint)
        case moving(Annotation, from: CGPoint)
        /// a Magnify grabbed outside its magnifier box: the source moves, the
        /// magnifier stays put
        case movingSource(Annotation, from: CGPoint)
        case handle(SelectionHandle, Annotation, from: CGPoint)
        /// ⌥ on anchor `i`: release converts it unless the drag `pulled`
        /// handles out — MarkupAnchorConvert.swift
        case convertAnchor(Int, Annotation, from: CGPoint, pulled: Bool)
        /// a recrop grip drag: frame and crop edges move together
        case recrop(SelectionHandle, Annotation, from: CGPoint)
        /// a drag inside while recropping: the crop slides within the source
        case pan(Annotation, from: CGPoint)
        /// Direct Select carrying anchors (or a segment's two) across
        /// Annotations: each start state and the anchor indices it moves
        case anchors([Annotation.ID: (start: Annotation, indices: Set<Int>)], from: CGPoint)
        /// Direct Select's marquee; release selects the anchors inside
        case marquee(from: CGPoint, to: CGPoint, adding: Bool)
        /// selected Annotations dragged together, each at its drag-start state;
        /// `duplicate` (⌥ at the press) copies them once the pointer moves
        case group([Annotation], from: CGPoint, duplicate: Bool)
        /// a grip on a multi-selection's shared bounding box
        case groupHandle(SelectionHandle, [Annotation], from: CGPoint)
        /// Select's marquee over empty canvas; release selects what it touches
        case marqueeSelect(from: CGPoint, to: CGPoint, adding: Bool)
    }
    /// an in-progress Pen path and the pointer's latest position for its preview
    @ObservationIgnored private var pen: (builder: PenBuilder, id: Annotation.ID, style: AnnotationStyle)?
    @ObservationIgnored private var penHover: CGPoint?
    /// the in-progress stroke or Pen path, for syncPanels/render
    var draft: Annotation? {
        if case let .drawing(a, _) = gesture { return a }
        if case let .brush(a, _) = gesture { return a }
        if case let .cutting(from, to) = gesture {
            // the cut line previews dashed in malachite at screen weight
            return Annotation(kind: .line(start: from, end: to),
                              style: AnnotationStyle(colour: MarkupEraser.cutLineColour,
                                                     width: 1 / zoom, dash: .dashed))
        }
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
    /// the image-kind Annotation in recrop mode — a double-click enters, Escape
    /// or a click outside ends; `nil` unless it is also the selection
    private(set) var cropping: Annotation.ID?
    /// the selected Annotations' ids, in the order they joined — a click,
    /// Shift-click, marquee, Select All, or the Layers window builds it.
    /// Every change re-renders and reaches `observeSelection` handlers.
    private(set) var selection = AnnotationSelection() {
        didSet {
            if selection != oldValue { cropping = nil; drawAnchor = nil }
            if selection.isEmpty { nodes.clear() }
            if isScreen, selection.isEmpty, AppState.shared.openMenu?.kind == .markup {
                AppState.shared.openMenu = nil
                AppDelegate.shared?.overlayCtrl.syncMenu()
            } else if isScreen, !selection.isEmpty, selection != oldValue,
                      AppState.shared.openMenu?.kind == .markup {
                // the menu's rows follow the new selection's kinds — refit the panel
                AppDelegate.shared?.overlayCtrl.fitMenu()
            }
            if selection != oldValue { selectionChanged() }
            render()
        }
    }
    /// the Draw Tool's active anchor on the single selection, after
    /// Illustrator's Pen with a path selected: it fills and its curve
    /// handles show. A press on an anchor sets it; one elsewhere clears it
    /// (`DrawPress.activeAnchor`). nil once out of the selection's range.
    var drawAnchor: Int? {
        get {
            guard armed == .draw, let i = _drawAnchor, let a = single, i < a.anchorGrips.count else { return nil }
            return i
        }
        set { _drawAnchor = newValue }
    }
    @ObservationIgnored private var _drawAnchor: Int?
    /// Direct Select's shown and selected anchors — MarkupDirectSelect.swift
    @ObservationIgnored var nodes = NodeSelection()
    /// selection observers by token — `observeSelection` in MarkupSelection.swift
    @ObservationIgnored var selectionObservers: [UUID: (AnnotationSelection) -> Void] = [:]
    /// the first selected Annotation — what a Tool menu seeds its controls
    /// from; with several selected, `shared` tells where they disagree
    var selected: Annotation? { selection.ids.first.flatMap { id in stack.annotations.first { $0.id == id } } }
    /// the one selected Annotation, nil when none or several are — grips,
    /// recrop, re-editing text, and Magnify's scroll work on one at a time
    var single: Annotation? { selection.single.flatMap { id in stack.annotations.first { $0.id == id } } }
    /// the text Annotation being edited in place, if any — the editor logic
    /// lives in MarkupTextEditor.swift; the menu reads this
    private(set) var editing: Annotation.ID?
    @ObservationIgnored var editor: TextEditorView?
    /// Select or Direct Select is armed: presses pick Annotations rather than place them
    var selecting: Bool { armed == .select || armed == .directSelect }
    /// Direct Select is armed
    var directSelecting: Bool { armed == .directSelect }
    /// the grips the selection shows and takes presses on: Direct Select's
    /// points, Select's bounding box, or the bounding box and a Line's bend
    /// for what a placing Tool just placed — the Draw Tool's adds every
    /// anchor of a Line or path, so a node it inserted drags later too
    var gripSet: GripSet { directSelecting ? .points : selecting ? .frame : armed == .draw ? .drawing : .placed }

    /// the gesture's snapping state; nil between gestures and while Snapping is off
    @ObservationIgnored var snapper: MarkupSnapper?
    /// what a dragged end is over and would attach to (MarkupAttach.swift)
    @ObservationIgnored var attachHover: AttachHover?
    var guides: [SnapGuide] { snapper?.guides ?? [] }

    @ObservationIgnored private(set) var panels: [MarkupPanel] = []
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
    func edit(_ change: (inout LayerStack) -> Void) {
        let before = stack
        change(&stack)
        record(from: before)
        // a layer hidden, locked, or gone takes its anchors out of Direct Select
        nodes.prune(to: stack.annotations)
        render()
        dismissIdleToolbarIfEmpty()
    }
    /// the last Annotation gone with no Tool armed ends the live toolbar
    private func dismissIdleToolbarIfEmpty() {
        if isScreen, stack.isEmpty { AppDelegate.shared?.overlayCtrl.scheduleIdleToolbarCheck() }
    }
    /// the drag in flight becomes its one undo step, if it changed anything
    func commitGesture() {
        if let gestureStart { record(from: gestureStart) }
        gestureStart = nil
    }
    /// one undo step: the screen's LayerHistory, or the Editor document's undo manager
    private func record(from before: LayerStack) {
        guard isScreen else { return registerUndo(restoring: before) }
        history.record(from: before, to: stack)
        if before != stack { editedAfterClear() }
        endHistoryIfClosed()
    }
    /// the Editor's undo manager groups by event, so two actions recorded in one
    /// event undo together — close the open group so the next step stands alone
    private func separateUndoGroup() {
        guard !isScreen, let undoManager, undoManager.groupingLevel > 0 else { return }
        undoManager.endUndoGrouping()
        undoManager.beginUndoGrouping()
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
        if isScreen, !AppState.shared.toolbarOpen, !clearUndo.offersUndo(at: .now) {
            history.end(ifCleared: stack)
            if stack.isEmpty { assets.removeAll() }
        }
    }
    /// true while typing lives on a Markup surface — the in-place editor or a
    /// Tool-menu text field — suspending Markup's command keys so ⌘Z/⌘V/⌘]
    /// reach it; the field's focus/blur re-runs syncSession()
    var textHasFocus: Bool {
        editing != nil || (NSApp.keyWindow === AppDelegate.shared?.overlayCtrl.menuPanel
                           && NSApp.keyWindow?.firstResponder is NSText)
    }
    /// Carbon command keys, the Markup Tool Key letters, and the Layers
    /// window track the toolbar; call on every phase/tool change. The letters
    /// are live only while a Freeze Frame is up or a Markup Tool is armed —
    /// a bare toolbar (phase .toolbar, tool nil) never swallows typing
    func syncSession() {
        let s = AppState.shared, typing = textHasFocus
        MarkupKeys.shared.sync(commands: s.toolbarOpen && !typing,
                               undo: MarkupController.shared.clearUndo.takesShortcut(at: .now) && !typing,
                               tools: !typing && (s.phase == .frozen || (s.toolbarOpen && s.tool?.kind == .markup)))
        LayersWindow.shared.sync()
        endHistoryIfClosed()
    }

    func undo() {
        closeScroll()
        // while a text is being typed ⌘Z is the editor's own undo
        if editing != nil { editor?.undoManager?.undo(); return }
        // a Clear's fade is about to land: undo it once it has
        guard gesture == nil, !clearInFlight, let s = history.undo(from: stack) else { return }
        restore(s); AppLog.line("markup: undo")
        undidClear()
    }
    func redo() {
        closeScroll()
        if editing != nil { editor?.undoManager?.redo(); return }
        guard gesture == nil, !clearInFlight, let s = history.redo(from: stack) else { return }
        restore(s); AppLog.line("markup: redo")
    }
    private func restore(_ s: LayerStack) {
        stack = s
        // gone, hidden, or locked: none of those can stay selected
        let kept = selection.pruned(to: s.annotations)
        if kept != selection { selection = kept }
        if let id = cropping, !s.annotations.contains(where: { $0.id == id }) { cropping = nil }
        nodes.prune(to: s.annotations)
        syncPanels(); render()
        dismissIdleToolbarIfEmpty()
    }
    /// replaces the whole stack — a reverted document
    func load(_ s: LayerStack) { gesture = nil; gestureStart = nil; restore(s) }

    /// arms a Tool on an Editor; the screen follows AppState through syncArmed
    func arm(_ tool: Tool?) {
        commitGesture(); gesture = nil
        // a Tool switch commits a Pen path or a text session in progress
        if tool != armed { finishPen(); commitEditing() }
        if tool == nil { selection = [] }
        if tool != armed { nodes.clear(); drawAnchor = nil } // anchors belong to Direct Select
        armed = tool
        showSelectionAnchors()
        render()
    }

    /// the want from AppState: a Markup Tool armed while the toolbar is up —
    /// called from the phase/tool didSets, so it runs on every state change
    func syncArmed() {
        syncSession()
        PeerThrough.shared.sync()
        // any disarm with no Annotations left ends the live toolbar
        if isScreen { AppDelegate.shared?.overlayCtrl.scheduleIdleToolbarCheck() }
        let s = AppState.shared
        // Freeze region picks on the Freeze Frame, never on the panels — excluding it lets the clicks through
        let want: Tool? = s.toolbarOpen && s.tool?.kind == .markup && s.tool?.isAction != true
            && s.tool != .freezeRegion ? s.tool : nil
        guard want != armed else {
            // same Tool but the phase may have changed: sampling Censors swap
            // between the Freeze Frame and the live stream on every render
            render()
            return
        }
        finishPen() // a Tool switch commits any Pen path in progress
        commitEditing()
        let was = armed
        nodes.clear() // anchors belong to Direct Select
        drawAnchor = nil // a re-armed Draw Tool starts with no active anchor
        armed = want
        showSelectionAnchors()
        if let want { MarkupToolbar.shared.armed(want) } // arming is the one recorded use
        if want == nil {
            commitGesture() // a drag cut short by disarming is still one step
            closeScroll() // an open phased scroll is its own step too
            gesture = nil; selection = []; snapper = nil
            counterNext = nil; cropping = nil
            if let m = flagsMon { NSEvent.removeMonitor(m); flagsMon = nil }
            if let m = keyMon { NSEvent.removeMonitor(m); keyMon = nil }
        } else if flagsMon == nil {
            // modifiers re-run a drag in flight; Delete removes the selection —
            // installed on entering the armed session, kept across Tool switches within it
            flagsMon = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                guard let self else { return e }
                if AppDelegate.shared?.overlayCtrl.pointerOverUI != true {
                    self.panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.view.setToolCursor()
                }
                // ⇧ ⌥ ⌘ ⌃ change what a drag does without the pointer moving
                if self.reactsToModifiers {
                    self.drag(to: NSEvent.mouseLocation, constrained: DragModifiers(e.modifierFlags).constrains)
                }
                return e
            }
            keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                // Return finishes a Pen path in progress (and only then eats the key)
                if e.keyCode == 36 || e.keyCode == 76, self.finishPen() { return nil }
                // arrows nudge Direct Select's anchors
                if let d = Self.nudge(for: e), self.editing == nil, self.nudgeAnchors(by: d) { return nil }
                                // ⌘A, ⌘C/⌘X/⌘D, arrows nudging — MarkupSelection.swift
                if self.editing == nil, self.handleSelectionKey(e) { return nil }
                guard e.keyCode == 51 || e.keyCode == 117, !self.selection.isEmpty, self.editing == nil else { return e }
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
            syncSession() // the key window just moved off any suspended field
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

    /// for the log: whether this display's Markup panel sits in front of the
    /// Freeze panel `freeze`, read from the window server's front-to-back
    /// order; nil while no Markup panel is up
    func stackingNote(over freeze: NSWindow) -> String? {
        guard let mp = panels.first(where: { $0.frame == freeze.frame }) else { return nil }
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
        let m = order.firstIndex(of: mp.windowNumber), f = order.firstIndex(of: freeze.windowNumber)
        let above = m.flatMap { m in f.map { m < $0 } }
        return "markup stacking: annotations \(above.map { $0 ? "above" : "BELOW" } ?? "unlisted") the Freeze Frame"
            + " (levels \(mp.level.rawValue)/\(freeze.level.rawValue), visible=\(mp.isVisible), key=\(NSApp.keyWindow === freeze ? "freeze" : NSApp.keyWindow === mp ? "markup" : "other"))"
    }

    /// display hotplug: rebuild the panels on the new screen set
    func screensChanged() {
        commitEditing()
        panels.forEach { $0.close() }; panels = []
        ScreenSamples.shared.stop()
        syncPanels()
        for p in panels { p.ignoresMouseEvents = armed == nil }
        render(); raise()
    }

    /// `keeping` spares Annotations added while a Clear's fade ran (MarkupClear.swift)
    func clear(keeping: Set<Annotation.ID> = []) {
        // a live text session commits as its own step before Clear's
        commitEditing()
        textEditStart = nil; textSavedDuringSession = false
        commitGesture()
        gesture = nil; snapper = nil; selection = []; counterNext = nil
        // the Pen preview dies with the stack it wasn't part of — clear it
        // before the edit renders
        pen = nil; penHover = nil
        edit { s in
            if keeping.isEmpty { s.clear() }
            else { for a in s.annotations where !keeping.contains(a.id) { s.remove(id: a.id) } }
        }
        syncPanels()
    }

    /// adds Annotations as one undo step — Smart Redact's Censors
    func add(_ annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        edit { s in annotations.forEach { s.add($0) } }
        syncPanels(); render()
    }

    /// the first selected Annotation's style — the seam the Tool menu's
    /// style tiles read; `sharedStyle` says which fields the selection disagrees on
    var selectedStyle: AnnotationStyle? { selected?.style }

    /// restyles one Annotation by id — the eyedropper's target, whose selection
    /// Pick Colour's disarm cleared; `colourPicked` turns an image kind's border on
    func restyle(_ id: Annotation.ID, colourPicked: Bool = false, _ change: (inout AnnotationStyle) -> Void) {
        update(id) {
            var style = $0.style
            change(&style)
            $0 = $0.restyled(style, colourPicked: colourPicked)
        }
        AppLog.line("markup: restyled selection")
    }

    /// edits one Annotation by id as a single undo step — for changes that
    /// touch the kind, like a Magnify's border through the eyedropper
    func update(_ id: Annotation.ID, _ change: (inout Annotation) -> Void) {
        guard var a = stack.annotations.first(where: { $0.id == id }) else { return }
        change(&a)
        // a mid-edit restyle folds into the text session's one undo step
        if id == editing { mutateUnrecorded { $0.replace(a) } }
        else { edit { $0.replace(a) } }
        AppLog.line("markup: restyled selection")
    }

    /// edits every selected image kind's ImagePlacement (corner radius, border) — one undo step
    func updateSelectedPlacement(_ change: (inout ImagePlacement) -> Void) {
        transformSelection { a in
            guard var p = a.placement else { return a }
            var a = a
            change(&p)
            a.placement = p
            return a
        }
    }

    /// applies a value change to each selected Annotation on its own — one undo step
    func transformSelection(_ f: (Annotation) -> Annotation) {
        let changed = selectedAnnotations.map(f)
        guard !changed.isEmpty else { return }
        edit { s in changed.forEach { s.replace($0) } }
        AppLog.line("markup: transformed selection")
    }

    /// ⌘] / ⌘[ / ⇧⌘] / ⇧⌘[ move the selection through the stack, keeping
    /// the selected Annotations' order among themselves
    func restackSelection(_ move: LayerStack.Restack) {
        guard !selection.isEmpty else { return }
        edit { $0.restack(selection.set, move) }
        AppLog.line("markup: restacked selection \(move)")
    }

    /// the Layers window's drag: the stack's new back-to-front order, one undo step
    func reorderLayers(_ order: [Annotation.ID]) {
        edit { s in for (i, id) in order.enumerated() { s.move(id, to: i) } }
    }

    /// hide/lock from the Layers window — a hidden or locked Annotation can't stay selected
    func update(_ a: Annotation) {
        edit { $0.replace(a) }
        if a.hidden || a.locked, selection.contains(a.id) { selection = selection.removing(a.id) }
    }

    /// the clipboard's image or Canvas centred on `p`, selected, Select armed —
    /// ⌘V routes here while the toolbar is open; the panels forward drops too
    @discardableResult
    func paste(from pb: NSPasteboard, at p: CGPoint) -> Bool {
        guard isScreen ? AppState.shared.toolbarOpen : true else { return false }
        // Annotations copied with ⌘C come back as Annotations
        if pasteAnnotations(from: pb, at: p) { return true }
        guard let content = MarkupPasteboard.read(pb) else {
            AppLog.line("markup: nothing readable on the clipboard")
            return false
        }
        // natural size scaled down (never up) to fit the surface under `p`
        let limit = isScreen ? (NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
            ?? NSScreen.main)?.frame.size
            : snapBounds?.size
        // a Text or Pen session in flight is its own undo step, before the paste's
        let penDone = finishPen(), textDone = commitEditing()
        if penDone || textDone { separateUndoGroup() }
        let size: CGSize
        switch content {
        case let .canvas(doc, _): size = doc.crop.size
        case let .image(_, s): size = s
        }
        let a = imageAnnotation(content, frame: Self.centred(size, at: p, within: limit))
        edit { $0.add(a) }
        syncPanels()
        selection = [a.id]
        if armed != .select { isScreen ? AppDelegate.shared?.trigger(.select) : arm(.select) }
        AppLog.line("markup: pasted \(content.label)")
        return true
    }

    /// `size` scaled down (never up) to fit `limit`, centred on `p`
    private static func centred(_ size: CGSize, at p: CGPoint, within limit: CGSize?) -> CGRect {
        var s = size
        if let limit, size.width > 0, size.height > 0 {
            let k = min(1, limit.width / size.width, limit.height / size.height)
            s = CGSize(width: size.width * k, height: size.height * k)
        }
        return CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height)
    }

    /// the image-kind Annotation showing `content` at `frame`; its pixels or
    /// Canvas join `assets`
    private func imageAnnotation(_ content: MarkupPasteboard.Content, frame: CGRect) -> Annotation {
        switch content {
        case let .canvas(doc, link):
            assets.canvases[link.url] = doc
            return Annotation(kind: .canvas(.linked(link), ImagePlacement(frame: frame,
                crop: doc.crop, cornerRadius: doc.cornerRadius)), style: Self.imageStyle)
        case let .image(image, _):
            let asset = UUID()
            assets.images[asset] = image
            return Annotation(kind: .image(asset: asset, ImagePlacement(frame: frame,
                crop: CGRect(x: 0, y: 0, width: image.width, height: image.height))), style: Self.imageStyle)
        }
    }

    /// Pin to screen: a Screenshot's Canvas exactly over the crop it was captured
    /// from while that is on a current display, else (and for an image without a
    /// Canvas) centred on the main display — on top, not selected, nothing armed,
    /// so it stays like any Annotation until erased or cleared
    func pin(_ content: MarkupPasteboard.Content) {
        var captured: CGRect?
        let size: CGSize
        switch content {
        case let .canvas(doc, _):
            size = doc.crop.size
            if NSScreen.screens.contains(where: { $0.frame.intersects(doc.crop) }) { captured = doc.crop }
        case let .image(_, s): size = s
        }
        let screen = NSScreen.main?.frame ?? .zero
        let frame = captured ?? Self.centred(size, at: CGPoint(x: screen.midX, y: screen.midY), within: screen.size)
        edit { $0.add(imageAnnotation(content, frame: frame)) }
        // a first pin's panels are new, and no selection change renders them
        syncPanels(); render()
        AppLog.line("markup: pinned \(content.label)")
    }

    /// Freeze region's result: `canvas` embedded beneath every Annotation at exactly its crop — one undo
    /// step — then selected when Select is armed (Freeze region arms it at confirm; a later Tool choice
    /// wins, and the frozen region still lands). An open step in flight (a drag, a Counter press, a
    /// phased scroll, a text session) keeps its own undo step and selection: the region lands at once beneath everything, as the step before it.
    func freeze(_ canvas: CanvasDocument) {
        let name = "\(UUID().uuidString).wadjet"
        assets.embedded[name] = canvas
        let a = Annotation.frozenRegion(embedding: name, canvas, style: Self.imageStyle)
        // an open step (drag, Counter press, phased scroll, text session) changes the
        // stack as it goes: the region joins its baseline and records as the step
        // before it. A Pen path keeps its nodes off the stack, so between presses its
        // lingering snapshot may be stale and the stack itself is the baseline.
        let penIdle = pen != nil && gesture == nil
        let open = textEditStart ?? (penIdle ? nil : gestureStart)
        guard let open else {
            edit { $0.addAtBottom(a) }
            // a Pen snapshot lingers between presses — keep the region inside it
            // so its commitGesture can't re-record the region into the path's step
            gestureStart?.addAtBottom(a)
            syncPanels()
            if armed == .select { selection = [a.id] }
            AppLog.line("markup: froze region \(canvas.crop.debugDescription) as \(name)")
            return
        }
        var after = open; after.addAtBottom(a)
        history.record(from: open, to: after) // screen-only: Freeze region never runs in an Editor
        editedAfterClear()
        endHistoryIfClosed()
        gestureStart?.addAtBottom(a)
        textEditStart?.addAtBottom(a)
        stack.addAtBottom(a)
        syncPanels(); render()
        AppLog.line("markup: froze region \(canvas.crop.debugDescription) as \(name)")
    }

    /// ends recrop mode; true when one was in flight — Escape consumes it first
    @discardableResult
    func endRecrop() -> Bool {
        guard cropping != nil else { return false }
        cropping = nil
        render()
        return true
    }

    /// true when there was a selection to drop
    @discardableResult
    func deselect() -> Bool {
        guard !selection.isEmpty || !nodes.isEmpty else { return false }
        nodes.clear()
        selection = []
        AppLog.line("markup: deselected")
        return true
    }

    func deleteSelection() {
        if deleteAnchors() { return }
        guard !selection.isEmpty else { return }
        edit { $0.remove(ids: selection.ids) }
        selection = []
        AppLog.line("markup: deleted selection")
    }

    // MARK: text-editor write hooks — the logic lives in MarkupTextEditor.swift

    /// the stack when the in-place text session began — the session's one
    /// undo step is recorded from it on commit (keystrokes aren't steps)
    @ObservationIgnored var textEditStart: LayerStack?
    /// this session's unrecorded edits already dirtied the document — the
    /// recorded step then marks it the normal way, so commit balances it
    @ObservationIgnored var textDirtyMarked = false
    /// a save happened inside this session — its disk image carries the
    /// unrecorded edits, so a net-zero session can't go clean again
    @ObservationIgnored var textSavedDuringSession = false
    /// changes the stack without a history step — only the in-place text
    /// editor uses it; its session's one step is recorded by recordTextEdit()
    func mutateUnrecorded(_ change: (inout LayerStack) -> Void) {
        let before = stack
        change(&stack)
        // a change that altered nothing dirties nothing
        if !isScreen, !textDirtyMarked, textEditStart != nil, stack != before {
            document?.updateChangeCount(.changeDone)
            textDirtyMarked = true
        }
        // a Text placed or typed after a Clear: Undo would take that, not the Clear
        if isScreen, stack != before { editedAfterClear() }
        render()
    }
    /// records the whole text session's net change as one undo step — a
    /// discarded empty box records nothing (LayerHistory skips no-ops)
    func recordTextEdit() {
        guard let before = textEditStart else { return }
        if textDirtyMarked {
            // the recorded step re-dirties via its undo registration; a net-zero
            // session registers nothing, so a mark made after a save must stay
            if before != stack || !textSavedDuringSession {
                document?.updateChangeCount(.changeUndone)
            }
            textDirtyMarked = false
        }
        record(from: before)
        textEditStart = nil
        textSavedDuringSession = false
    }
    /// a save (explicit or autosave) consumed this session's dirty mark — the
    /// next unrecorded keystroke must mark again, and commit balances only a
    /// mark made since
    func textSessionSaved() {
        guard textEditStart != nil else { return }
        textDirtyMarked = false
        textSavedDuringSession = true
    }
    func setEditing(_ id: Annotation.ID?) { editing = id }
    func setSelection(_ ids: AnnotationSelection) { selection = ids }
    /// a drag in flight rewrites these Annotations; its gesture snapshot records the step
    func replaceDuringGesture(_ annotations: [Annotation]) { stack.replaceGroup(annotations) }
    /// the panel whose screen holds `p`
    func panel(containing p: CGPoint) -> MarkupPanel? {
        panels.first { $0.screen?.frame.contains(p) == true }
    }

    // strokes arrive as Canvas (global screen) points from MarkupView;
    // `constrained` = Shift (adds to a selection, 45° Pen nodes),
    // `clickCount` for a double-click's re-edit (Text) or recrop (image kinds)
    func begin(at p: CGPoint, constrained: Bool = false, clickCount: Int = 1) {
        closeScroll() // an open phased scroll is its own undo step
        // a click anywhere commits the open text editor and places nothing
        if editing != nil {
            commitEditing()
            return
        }
        gestureStart = stack
        if cropping != nil {
            // recrop in flight: grips resize the crop, inside pans, outside ends it
            if let sel = single, let h = sel.handle(at: p, radius: Self.handleHitRadius,
                    minExtent: Self.handleMinExtent, rotateOffset: Self.rotateOffset), case .resize = h {
                gesture = .recrop(h, sel, from: p)
                return
            }
            if let sel = single, PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance) {
                gesture = .pan(sel, from: p)
                return
            }
            endRecrop()
            // then the click is handled normally
        }
        // a double-click on Text or an image re-edits or recrops it, as under Select
        if directSelecting,
           !(clickCount == 2 && stack.topmost(at: p, tolerance: Self.hitTolerance / zoom)
               .map { !$0.kind.hasAnchors } == true) {
            beginDirect(at: p, adding: constrained)
            return
        }
        // Direct Select reaches here only for a double-click on Text or an image
        if selecting {
            if clickCount == 2, let hit = stack.topmost(at: p, tolerance: Self.hitTolerance / zoom),
               case .text = hit.kind {
                gestureStart = nil // the text session records its own one step
                startEditing(hit.id)
                return
            }
            if let sel = single {
                // a double-click inside an image kind enters recrop — unless
                // its source is gone and only the persisted snapshot shows
                if clickCount == 2, sel.placement != nil, assets.canRecrop(sel),
                   PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance / zoom) {
                    cropping = sel.id
                    render()
                    return
                }
                // a grip; ⇧ constrains its drag
                if sel.handle(at: p, radius: Self.handleHitRadius / zoom,
                              minExtent: Self.handleMinExtent / zoom,
                              rotateOffset: Self.rotateOffset / zoom, set: gripSet) != nil,
                   grabSelection(at: p) { return }
            }
            // the shared box's grips
            if grabGroupHandle(at: p) { return }
            pressSelect(at: p, shift: constrained)
            return
        }
        // what a placing Tool just placed stays selected: a press on its grips
        // or body adjusts it; a press anywhere else deselects and places anew
        if editsSelection() {
            if clickCount == 2, let sel = single, case .text = sel.kind,
               PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance / zoom) {
                gestureStart = nil // the text session records its own one step
                startEditing(sel.id)
                return
            }
            if grabSelection(at: p, insertingNodes: armed == .draw) || grabGroup(at: p, shift: false) { return }
        }
        // a new Annotation takes the Tool's style and options, not the selection's
        selection = []
        if armed == .draw, MarkupStyles.shared.drawVariant.isBrush {
            // Brush: collect samples while the pointer is down; the preview
            // draws them as an open polyline of corner nodes
            let style = MarkupStyles.shared.style(for: .draw)
            let a = Annotation(kind: .path(PathData(nodes: [PathNode(anchor: p)])), style: style)
            gesture = .brush(a, raw: [p])
            render()
            return
        }
        if armed == .draw, MarkupStyles.shared.drawVariant == .pen {
            // Pen: a press adds a node (or closes on the first), a press-drag
            // pulls its handles — the path lives in `pen` until finishPen
            if pen == nil {
                pen = (PenBuilder(), Annotation.ID(), MarkupStyles.shared.style(for: .draw))
            }
            _ = pen?.builder.press(at: p, closeRadius: Self.handleHitRadius, constrained: constrained)
            gesture = .pen
            render()
            return
        }
        if armed == .eraser {
            gesture = MarkupEraser.variant == .knife
                ? .cutting(from: p, to: p)
                : .erasing(EraserSweep(stack: stack, at: p, radius: MarkupEraser.width / 2))
            render()
            return
        }
        if armed == .text {
            gestureStart = nil // the text session records its own one step
            textEditStart = stack; textDirtyMarked = false; textSavedDuringSession = false
            let a = Annotation(
                kind: .text(TextData(string: "", origin: p,
                                     format: AppState.shared.config.value.markup.textFormat)),
                style: MarkupStyles.shared.style(for: .text))
            mutateUnrecorded { $0.add(a) }
            startEditing(a.id)
            return
        }
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
        snapper = MarkupSnapper(stack: stack, excluding: nil, canvasBounds: snapBounds, pixelSources: snapPixelSources)
        let so = snapper?.offset(points: [p]) ?? .zero
        gesture = .drawing(a.moved(by: so), from: CGPoint(x: p.x + so.dx, y: p.y + so.dy))
        render()
    }

    /// whether a press with the armed placing Tool may grab the selection —
    /// not mid Pen path (its presses add nodes), not for the Eraser (it places
    /// nothing), and not for a Counter's ⌥-click (it picks a sequence)
    private func editsSelection() -> Bool {
        guard !selection.isEmpty, pen == nil, armed != nil, armed != .eraser else { return false }
        return !(armed == .counter && NSEvent.modifierFlags.contains(.option))
    }

    /// a press on the selection's grips or body starts the drag that adjusts
    /// it; false when the press missed it. `insertingNodes` (the Draw Tool):
    /// an anchor (⌥ converts it), then a curve handle, then a bend grip, then
    /// the stroke — where the press adds a node and drags it — then a frame
    /// grip (`Annotation.drawPress`)
    func grabSelection(at p: CGPoint, insertingNodes: Bool = false) -> Bool {
        guard let sel = single else { return false }
        let press: DrawPress? = if insertingNodes {
            sel.drawPress(at: p, radius: Self.handleHitRadius / zoom, tolerance: Self.hitTolerance / zoom,
                          minExtent: Self.handleMinExtent / zoom, rotateOffset: Self.rotateOffset / zoom,
                          active: drawAnchor)
        } else {
            sel.handle(at: p, radius: Self.handleHitRadius / zoom, minExtent: Self.handleMinExtent / zoom,
                       rotateOffset: Self.rotateOffset / zoom, set: gripSet).map { .grip($0) }
        }
        if insertingNodes {
            let was = drawAnchor
            drawAnchor = DrawPress.activeAnchor(after: press, was: was)
            if drawAnchor != was { render() } // the anchor fills on the press
        }
        switch press {
        case let .grip(.vertex(i))? where insertingNodes && beginConvertingAnchor(i, of: sel, at: p):
            return true
        case let .grip(h)?:
            snapper = MarkupSnapper(stack: stack, excluding: sel.id, canvasBounds: snapBounds, pixelSources: snapPixelSources)
            // dragging an attached end carries it away; the drop may attach it again
            gesture = .handle(h, sel.attachPoint(for: h).map { sel.detaching($0) } ?? sel, from: p)
            return true
        case let .insert(a, i, t)?:
            snapper = MarkupSnapper(stack: stack, excluding: sel.id, canvasBounds: snapBounds, pixelSources: snapPixelSources)
            // the node joins the stack now; the press's gesture snapshot makes
            // the insertion and its drag one undo step. The new node
            // renumbers the path: attachments move with it
            stack.replaceInsertingNode(a, at: i, splitAt: t)
            gesture = .handle(.vertex(i), stack.annotations.first { $0.id == a.id } ?? a, from: p)
            render()
            AppLog.line("markup: added a node")
            return true
        case nil:
            break
        }
        if PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance / zoom) {
            snapper = MarkupSnapper(stack: stack, excluding: sel.id, canvasBounds: snapBounds, pixelSources: snapPixelSources)
            gesture = (selecting ? optionDuplicateGesture([sel], at: p) : nil) ?? Self.moveGesture(sel, at: p)
            return true
        }
        return false
    }

    /// the cursor over the selection where a placing Tool's press adjusts it
    /// rather than placing: the arrow on its grips and body (a multi-selection's
    /// shared box and members included), the open hand on a stroke the Draw
    /// Tool adds nodes to; nil elsewhere
    func selectionCursor(at p: CGPoint) -> NSCursor? {
        guard !selecting, editing == nil, editsSelection() else { return nil }
        guard let sel = single else { return overGroup(at: p) ? .arrow : nil }
        if armed == .draw {
            switch sel.drawPress(at: p, radius: Self.handleHitRadius / zoom, tolerance: Self.hitTolerance / zoom,
                                 minExtent: Self.handleMinExtent / zoom, rotateOffset: Self.rotateOffset / zoom,
                                 active: drawAnchor) {
            case .grip?: return .arrow
            case .insert?: return .openHand
            case nil: break
            }
        } else if sel.handle(at: p, radius: Self.handleHitRadius / zoom, minExtent: Self.handleMinExtent / zoom,
                             rotateOffset: Self.rotateOffset / zoom, set: gripSet) != nil { return .arrow }
        return PathGeometry.hitTest(sel, at: p, tolerance: Self.hitTolerance / zoom) ? .arrow : nil
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
        let a = Annotation(kind: .counter(center: p, radius: MarkupCounter.size / 2,
                                          value: value, format: format),
                           style: MarkupStyles.shared.style(for: .counter))
        stack.add(a)
        selection = [a.id] // stays selected for editing; selection's didSet renders
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
                                                   square: DragModifiers(f).constrains, fromCentre: f.contains(.option)))
            case let .censor(_, method):
                a.kind = .censor(rect: CGRect(x: from.x, y: from.y, width: p.x - from.x,
                                              height: p.y - from.y).standardized, method: method)
            case .counter, .window: break // counters place on the click; windows are never drafted
            case let .magnify(m):
                // the drag sizes the source; the magnifier re-places beside it
                let source = CGRect(x: from.x, y: from.y, width: p.x - from.x,
                                    height: p.y - from.y).standardized
                let centre = CGPoint(x: source.midX, y: source.midY)
                a.kind = .magnify(.placed(source: source, options: m.options,
                                          on: placementBounds(around: centre)))
            case .text: break // Text edits in place, never a draft
            case .image, .canvas: // images are never drafts
                break
            }
            gesture = .drawing(a, from: from)
        case .pen:
            pen?.builder.drag(to: p, constrained: constrained)
            penHover = p // the next hover preview starts from the pointer
        case let .brush(d, raw):
            var a = d, raw = raw
            raw.append(p)
            a.kind = .path(PathData(nodes: raw.map { PathNode(anchor: $0) }))
            gesture = .brush(a, raw: raw)
        case var .erasing(sweep):
            sweep.drag(to: p)
            gesture = .erasing(sweep)
        case let .cutting(from, _):
            gesture = .cutting(from: from,
                               to: constrained ? PathGeometry.snapAngle(p, from: from) : p)
        case let .moving(start, from):
            let moved = start.moved(by: CGVector(dx: p.x - from.x, dy: p.y - from.y))
            // a Magnify snaps its magnifier frame, not its whole path's box
            let snapRect = moved.pixelSnapBounds
            let snapped = snapper?.offset(rect: snapRect) ?? .zero
            // with ⇧⌘ held, over another Annotation's spot or edge, the pointer snaps there to attach
            let (attached, hover) = attachingWhole(moved.moved(by: snapped), unsnapped: moved, pointer: p)
            attachHover = hover
            stack.replace(attached)
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
        case let .anchors(starts, from):
            dragAnchors(starts, from: from, to: p, constrained: constrained)
            return
        case let .marquee(from, _, adding):
            gesture = .marquee(from: from, to: p, adding: adding)
        case .convertAnchor:
            dragConvertingAnchor(to: p, constrained: constrained)
        case let .handle(.tangent(i, out), start, from):
            // ⌥ breaks a smooth node into a corner; a Shape reshapes into its
            // outline path as the handle moves. An Annotation attached whole
            // stays attached where the edit leaves it
            stack.replaceRebasing(start.outlinePath.dragging(.tangent(i, outgoing: out), from: from, to: p,
                                                             constrained: constrained,
                                                             breaking: NSEvent.modifierFlags.contains(.option)))
        case let .handle(h, start, from) where h.isShapeWidget:
            // a live Shape's option changes; nothing snaps, and the sides
            // step counts on-screen travel
            stack.replaceRebasing(start.draggingShapeWidget(h, from: from, to: p, zoom: zoom))
        case let .handle(h, start, from):
            // Shift's 45° constraint wins on point handles: a point snap
            // would leave the ray — vertex ends and Pen tangents both;
            // on an image kind's resize grip ⇧ stretches the aspect instead
            let shiftConstrained = switch h { case .vertex, .tangent: true; default: false }
            let moved = if constrained, shiftConstrained {
                start.dragging(h, from: from, to: p, constrained: true)
            } else {
                // the grip follows the pointer's delta whether or not it snaps
                snapper?.dragging(start, h, from: from, to: p, stretch: constrained)
                    ?? start.dragging(h, from: from, to: p, stretch: constrained,
                                      minExtent: Self.handleMinExtent, rotateOffset: Self.rotateOffset,
                                      targets: [], range: 0, skip: true).annotation
            }
            // an end over another Annotation snaps to its attach spot
            let (attached, hover) = attaching(moved, point: moved.attachPoint(for: h), constrained: constrained && shiftConstrained)
            attachHover = hover
            // an edit of an Annotation attached whole keeps it attached where it lands
            stack.replaceRebasing(attached)
        case let .recrop(h, start, from):
            guard assets.canRecrop(start),
                  let source = assets.source(for: start)?.bounds else { return }
            stack.replaceRebasing(start.recropping(h, from: from, to: p, source: source))
        case let .pan(start, from):
            guard assets.canRecrop(start),
                  let source = assets.source(for: start)?.bounds else { return }
            stack.replaceRebasing(start.panning(from: from, to: p, source: source))
        case .group, .groupHandle, .marqueeSelect:
            dragGroup(to: p, constrained: constrained)
        case nil:
            return
        }
        render()
    }
    /// commits a Pen path that just closed, or fits a Brush stroke — other
    /// paths wait for Return/Escape, a click without movement draws nothing
    func end() {
        if case let .brush(d, raw) = gesture {
            gesture = nil
            if let fitted = PathData.fitted(raw, smoothing: CGFloat(MarkupStyles.shared.smoothing(for: .draw))) {
                var a = d
                a.kind = .path(fitted)
                stack.add(a)
                selection = [a.id] // stays selected for editing, the Tool still armed
            }
            commitGesture() // the stroke's whole drag is its one undo step
            render()
            return
        }
        if case .pen = gesture {
            gesture = nil
            if pen?.builder.path.closed == true { finishPen() } else { render() }
            return
        }
        if case let .marqueeSelect(from, to, adding) = gesture {
            gesture = nil
            gestureStart = nil // a marquee changes the selection, not the stack
            endMarqueeSelect(from: from, to: to, adding: adding)
            return
        }
        if case let .erasing(sweep) = gesture {
            gesture = nil
            stack.erase(sweep.marked)
            commitGesture() // the sweep's whole drag is its one undo step
            syncPanels()
            render()
            return
        }
        if case let .cutting(from, to) = gesture {
            gesture = nil
            if hypot(to.x - from.x, to.y - from.y) >= Self.minDraftSize {
                stack.cut(from: from, to: to)
            }
            commitGesture()
            syncPanels()
            render()
            return
        }
        if case let .marquee(from, to, adding) = gesture {
            gesture = nil
            endMarquee(from: from, to: to, adding: adding)
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
            case .counter, .window:
                false // counters place on the click; windows are never drafted
            case let .magnify(m):
                m.source.width >= Self.minDraftSize && m.source.height >= Self.minDraftSize
            case .text:
                false
            case .image, .canvas: // images are never drafts
                false
            }
            if drawn {
                stack.add(d)
                selection = [d.id] // stays selected for editing, the Tool still armed
            }
        }
        endConvertingAnchor()
        // a dragged end dropped on an attach spot attaches there exactly, one
        // dropped inside a target loosely — in the drag's undo step
        dropAttaching()
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
        // a drag of the selection may still be in flight — commit it first so
        // it stays its own undo step and the path inserts above it
        switch gesture {
        case nil, .pen, .brush: break
        case .drawing, .moving, .movingSource, .handle, .convertAnchor, .recrop, .pan, .erasing, .cutting,
             .anchors, .marquee,
             .group, .groupHandle, .marqueeSelect: commitGesture()
        }
        if let data = pen.builder.finished {
            let a = Annotation(id: pen.id, kind: .path(data), style: pen.style)
            // the insertion is its own undo step — the path's presses are
            // separate gestures, so the gesture snapshot can't carry this one
            edit { $0.add(a) }
            // stays selected for editing while a Tool is armed
            if armed != nil { selection = [a.id] }
            AppLog.line("markup: finished pen path (\(data.nodes.count) nodes)")
        }
        gestureStart = nil // the path's presses left no drag to commit
        gesture = nil
        syncPanels()
        render()
        return true
    }

    /// the Smoothing slider's selection seam: refits a selected Brush stroke
    /// from its kept samples, in place
    func refitSelection(smoothing: CGFloat) {
        // a refit rebuilds the stroke's segments: attachments move with it
        let changed = selectedAnnotations.compactMap { a -> Annotation? in
            guard case let .path(d) = a.kind, d.rawPoints != nil else { return nil }
            return a.refitted(smoothing: smoothing)
        }
        guard !changed.isEmpty else { return }
        edit { s in changed.forEach { s.replaceReshaping($0) } }
    }

    /// the pointer moved: only the Pen rubber-band preview cares
    func hover(at p: CGPoint) {
        guard pen != nil else { return }
        penHover = p
        render()
    }

    /// a press on a Magnify outside its magnifier box drags the source, not the frame
    static func moveGesture(_ a: Annotation, at p: CGPoint) -> Gesture {
        guard case let .magnify(m) = a.kind,
              !m.options.shape.path(in: m.frame).contains(p) else {
            // moved on its own, an Annotation lets go of what it was attached to
            return .moving(a.freed, from: p)
        }
        return .movingSource(a, from: p)
    }

    /// scroll over a selected Magnify's magnifier steps its zoom, resizing the
    /// lens — a trackpad
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
        guard gesture == nil, let a = single, case .magnify(let m) = a.kind,
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
        guard case let .magnify(m) = a.kind else { return true }
        // the lens resizes about its centre; the source stays put
        a.kind = .magnify(m.zoomed(to: MagnifyZoom.stepped(m.effectiveZoom, by: steps)))
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
        // the Eraser dims what its sweep has marked for removal
        let dimmed: Set<Annotation.ID> = if case let .erasing(s) = gesture { s.marked } else { [] }
        let shown = stack.annotations.filter { !$0.hidden } + [draft].compactMap { $0 }
        guard isScreen else {
            surface?.show(shown, selection: single, editing: editing,
                          cropping: cropping, dimmed: dimmed, group: groupChrome)
            surface?.showGuides(guides)
            surface?.showAttach(attachHover)
            syncEditor()
            return
        }
        Self.onScreen.annotations = shown
        Self.onScreen.images = assets.images
        // the recorded window composites these per frame: cached flattens, not live documents
        var pixels: [NestedCanvas: CanvasPixels] = [:]
        for a in shown where a.placement != nil {
            if case let .canvas(nested, _) = a.kind, let px = assets.source(for: a) {
                pixels[nested] = px // two .canvas Annotations can share one source
            }
        }
        Self.onScreen.canvasPixels = pixels
        AppDelegate.shared?.recOutput?.overlay?.refresh() // a still recorded window sends no new frame
        ScreenSamples.shared.watch(shown.compactMap(\.sampledRect))
        for p in panels {
            p.view.show(shown, selection: single, editing: editing,
                        cropping: cropping, dimmed: dimmed, group: groupChrome)
            p.view.showGuides(guides)
            p.view.showAttach(attachHover)
        }
        PeerThrough.shared.sync()
        syncEditor()
    }

    /// the feathered peer-through hole under the pointer, per panel
    func showPeer(at p: CGPoint?) { for panel in panels { panel.view.peer(at: p) } }
}
