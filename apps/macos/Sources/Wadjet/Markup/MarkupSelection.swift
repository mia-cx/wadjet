import AppKit
import WadjetKit

/// Multi-selection, after Illustrator's Selection tool: Shift-click and the
/// marquee build the selection, one shared bounding box moves, scales, and
/// rotates it, and Select All, nudges, copy, paste, duplicate, delete, and
/// restack act on every selected Annotation. The rules live in WadjetKit
/// (AnnotationSelection, AnnotationGroup, Mixed); this wires them to the
/// controller's gestures and keys.
extension MarkupController {
    /// a marquee smaller than this (on-screen points) is a click
    static let marqueeMinSize: CGFloat = 3
    /// Shift+arrow nudges this many points; a bare arrow one
    static let bigNudge: CGFloat = 10

    // MARK: observing

    /// calls `handler` with the new selection after every change; returns the
    /// token `stopObservingSelection` takes. SwiftUI views read `selection`
    /// through Observation instead.
    @discardableResult
    func observeSelection(_ handler: @escaping (AnnotationSelection) -> Void) -> UUID {
        let token = UUID()
        selectionObservers[token] = handler
        return token
    }
    func stopObservingSelection(_ token: UUID) { selectionObservers[token] = nil }
    /// the selection's didSet: tell the observers
    func selectionChanged() {
        for o in selectionObservers.values { o(selection) }
    }

    // MARK: reading

    /// the selected Annotations, back to front
    var selectedAnnotations: [Annotation] {
        let ids = selection.set
        return stack.annotations.filter { ids.contains($0.id) }
    }

    /// one setting across the selected Annotations that have it (`read`
    /// returns nil for the rest): their shared value, `.mixed`, or nil when
    /// none has it — a Tool menu's mixed state
    func shared<T: Equatable>(_ read: (Annotation) -> T?) -> Mixed<T>? {
        Mixed(selectedAnnotations.compactMap(read))
    }

    /// the selected Annotations' styles resolved field by field
    var sharedStyle: AnnotationStyle.Shared? { AnnotationStyle.Shared(selectedAnnotations.map(\.style)) }

    // MARK: selecting

    /// the Layers window's selection: rows keep the order they were picked in,
    /// hidden and locked ones refuse, and a non-empty pick arms Select first
    /// when nothing is armed
    func select(_ ids: Set<Annotation.ID>) {
        let pickable = Set(stack.annotations.filter(\.isSelectable).map(\.id)).intersection(ids)
        guard !pickable.isEmpty else { deselect(); return }
        if armed == nil { isScreen ? AppDelegate.shared?.trigger(.select) : arm(.select) }
        guard armed != nil else { return }
        let kept = selection.ids.filter(pickable.contains)
        let added = stack.annotations.map(\.id).filter { pickable.contains($0) && !kept.contains($0) }
        showAnchors(of: pickable)
        setSelection(AnnotationSelection(kept + added))
    }

    /// ⌘A: every Annotation that isn't locked or hidden; arms Select when
    /// nothing is armed. A Pen path or text session in flight commits first.
    func selectAll() {
        finishPen(); commitEditing()
        guard !stack.isEmpty else { return }
        if armed == nil { isScreen ? AppDelegate.shared?.trigger(.select) : arm(.select) }
        let all = AnnotationSelection.all(in: stack.annotations)
        showAnchors(of: all.set)
        setSelection(all)
        AppLog.line("markup: selected all (\(selection.count))")
    }

    /// a selection made outside Direct Select's own presses (the Layers
    /// window, Select All) resets its anchors: under Direct Select — armed,
    /// whatever ⌘ is doing — every picked path shows its anchors, none
    /// selected. The anchors go first because the selection's didSet renders.
    private func showAnchors(of ids: Set<Annotation.ID>) {
        nodes.clear()
        guard armed == .directSelect else { return }
        for a in stack.annotations where ids.contains(a.id) && a.kind.hasAnchors {
            nodes.show(a.id, adding: true)
        }
    }

    // MARK: the shared bounding box

    /// what a view draws for the selection beyond a single Annotation's
    /// grips: each member's outline, the shared box and its grips while
    /// several are selected, and the marquee in flight
    var groupChrome: SelectionChrome {
        var c = SelectionChrome()
        if case let .marqueeSelect(from, to, _) = gesture {
            c.marquee = CGRect(x: from.x, y: from.y, width: to.x - from.x, height: to.y - from.y).standardized
        }
        guard selection.count > 1 else { return c }
        let members = selectedAnnotations.filter { !$0.hidden }
        guard !members.isEmpty else { return c }
        c.outlines = members.map { PathGeometry.path(for: $0) }
        let box = AnnotationGroup.bounds(of: members)
        c.box = box
        c.handles = AnnotationGroup.handles(of: box, minExtent: Self.handleMinExtent / zoom,
                                            rotateOffset: Self.rotateOffset / zoom)
        return c
    }

    /// a press on the shared box's grips (with several selected) or on any
    /// selected Annotation's body starts the drag that moves them all; ⇧ on
    /// a body toggles it out instead, so it doesn't grab. False on a miss.
    func grabGroup(at p: CGPoint, shift: Bool) -> Bool {
        guard selection.count > 1 else { return false }
        if grabGroupHandle(at: p) { return true }
        guard !shift, let hit = stack.topmost(at: p, tolerance: Self.hitTolerance / zoom),
              selection.contains(hit.id) else { return false }
        moveSelection(from: p, duplicate: selecting && NSEvent.modifierFlags.contains(.option))
        return true
    }

    /// a press on the shared box's grips, with several selected, starts the
    /// drag that resizes or rotates them all; false on a miss
    func grabGroupHandle(at p: CGPoint) -> Bool {
        guard selection.count > 1 else { return false }
        let members = selectedAnnotations
        let box = AnnotationGroup.bounds(of: members)
        guard let h = AnnotationGroup.handle(at: p, of: box, radius: Self.handleHitRadius / zoom,
                                             minExtent: Self.handleMinExtent / zoom,
                                             rotateOffset: Self.rotateOffset / zoom) else { return false }
        gesture = .groupHandle(h, members, from: p)
        return true
    }

    /// a Select press that missed the grips, after Illustrator (WadjetKit's
    /// SelectPress): on any Annotation it selects that one, or keeps the
    /// selection it belongs to, and the drag moves the selection; ⇧ toggles
    /// it; only empty canvas starts a marquee, adding under ⇧
    func pressSelect(at p: CGPoint, shift: Bool) {
        let press = SelectPress.resolve(at: p, in: stack.annotations, selection: selection,
                                        shift: shift, tolerance: Self.hitTolerance / zoom)
        setSelection(press.selection)
        switch press.action {
        case let .marquee(adding):
            gesture = .marqueeSelect(from: p, to: p, adding: adding)
        case .none:
            AppLog.line("markup: deselected (\(selection.count))")
        case .move:
            AppLog.line("markup: grabbed the selection (\(selection.count))")
            moveSelection(from: p, duplicate: NSEvent.modifierFlags.contains(.option))
        }
    }

    /// the drag that moves every selected Annotation from `p`; `duplicate`
    /// (⌥) copies them once the pointer moves. One Annotation moves on its
    /// own, so a Magnify's source re-aims when the press was on it.
    private func moveSelection(from p: CGPoint, duplicate: Bool) {
        let members = selectedAnnotations
        if members.count == 1, let sel = members.first {
            snapper = MarkupSnapper(stack: stack, excluding: sel.id, canvasBounds: snapBounds,
                                    pixelSources: snapPixelSources)
            gesture = duplicate ? .group(members, from: p, duplicate: true) : Self.moveGesture(sel, at: p)
            return
        }
        snapper = MarkupSnapper(stack: LayerStack(stack.annotations.filter { !selection.contains($0.id) }),
                                excluding: nil, canvasBounds: snapBounds, pixelSources: snapPixelSources)
        gesture = .group(members, from: p, duplicate: duplicate)
    }

    /// true over the shared box's grips or a selected Annotation's body —
    /// where a placing Tool's press adjusts the selection
    func overGroup(at p: CGPoint) -> Bool {
        guard selection.count > 1 else { return false }
        let box = AnnotationGroup.bounds(of: selectedAnnotations)
        if AnnotationGroup.handle(at: p, of: box, radius: Self.handleHitRadius / zoom,
                                  minExtent: Self.handleMinExtent / zoom,
                                  rotateOffset: Self.rotateOffset / zoom) != nil { return true }
        guard let hit = stack.topmost(at: p, tolerance: Self.hitTolerance / zoom) else { return false }
        return selection.contains(hit.id)
    }

    /// a group drag or marquee in flight follows the pointer: ⇧ keeps a
    /// resize's proportions (or snaps a rotation to 45°), ⌥ resizes about the centre
    func dragGroup(to p: CGPoint, constrained: Bool) {
        switch gesture {
        case let .group(starts, from, duplicate):
            var starts = starts
            if duplicate, p != from {
                // the copies join the stack under the press's gesture snapshot,
                // so the duplicate and its drag are one undo step
                let (s, copies) = withCopies(of: starts, offset: .zero)
                mutateUnrecorded { $0 = s }
                setSelection(AnnotationSelection(copies.map(\.id)))
                AppLog.line("markup: ⌥-drag duplicated \(copies.count)")
                starts = copies
                gesture = .group(copies, from: from, duplicate: false)
            }
            let moved = AnnotationGroup.moved(starts, by: CGVector(dx: p.x - from.x, dy: p.y - from.y))
            let snapped = snapper?.offset(rect: AnnotationGroup.bounds(of: moved)) ?? .zero
            replaceDuringGesture(AnnotationGroup.moved(moved, by: snapped))
        case let .groupHandle(h, starts, from):
            let changed = AnnotationGroup.dragging(starts, h, from: from, to: p, proportional: constrained,
                                                   fromCentre: NSEvent.modifierFlags.contains(.option))
            replaceDuringGesture(changed)
        case let .marqueeSelect(from, _, adding):
            gesture = .marqueeSelect(from: from, to: p, adding: adding)
        default:
            return
        }
    }

    /// whether a modifier changing mid-drag changes the gesture in flight, so
    /// it re-runs at the same pointer: ⇧ and ⌥ reshape, ⌘ stops snapping,
    /// ⌃ stops attaching, ⇧⌘ attaches a moved Annotation whole. Brush, Pen
    /// and Eraser drags add a sample per run, so they don't re-run.
    var reactsToModifiers: Bool {
        switch gesture {
        case .drawing, .cutting, .moving, .movingSource, .handle, .convertAnchor, .anchors, .group, .groupHandle: true
        default: false
        }
    }

    /// a released marquee selects what it touches; a click-sized one leaves
    /// the selection the press set
    func endMarqueeSelect(from: CGPoint, to: CGPoint, adding: Bool) {
        let r = CGRect(x: from.x, y: from.y, width: to.x - from.x, height: to.y - from.y).standardized
        if max(r.width, r.height) >= Self.marqueeMinSize / zoom {
            setSelection(selection.marquee(r, in: stack.annotations, adding: adding))
            AppLog.line("markup: marquee selected \(selection.count)")
        }
        render()
    }

    // MARK: acting on every selected Annotation

    /// a style change applied to each selected Annotation's own style, so the
    /// fields it doesn't touch stay theirs — one undo step. `colourPicked`
    /// turns an image kind's coloured border on.
    func restyleSelection(colourPicked: Bool = false, _ change: (inout AnnotationStyle) -> Void) {
        // the text being typed folds its restyle into the session's one undo step
        if let id = editing, selection.single == id {
            restyle(id, colourPicked: colourPicked, change)
            return
        }
        transformSelection {
            var style = $0.style
            change(&style)
            return $0.restyled(style, colourPicked: colourPicked)
        }
    }

    /// restyles the Annotations with these ids as one undo step — the
    /// eyedropper's targets, whose selection Pick Colour's disarm cleared
    func restyle(_ ids: AnnotationSelection, colourPicked: Bool = false,
                 _ change: (inout AnnotationStyle) -> Void) {
        if let id = ids.single { restyle(id, colourPicked: colourPicked, change); return }
        let picked = ids.set
        let changed: [Annotation] = stack.annotations.filter { picked.contains($0.id) }.map {
            var style = $0.style
            change(&style)
            return $0.restyled(style, colourPicked: colourPicked)
        }
        edit { s in changed.forEach { s.replace($0) } }
    }

    /// the Transform menu's Rotate Left/Right: the selection turns about its
    /// shared centre — a single Annotation about its own
    func rotateSelection(by angle: CGFloat) {
        let changed = AnnotationGroup.rotated(selectedAnnotations, by: angle)
        guard !changed.isEmpty else { return }
        edit { s in changed.forEach { s.replace($0) } }
        AppLog.line("markup: rotated selection")
    }

    /// the Transform menu's flips: mirrored across the shared centre line
    func flipSelection(horizontally: Bool) {
        let changed = AnnotationGroup.flipped(selectedAnnotations, horizontally: horizontally)
        guard !changed.isEmpty else { return }
        edit { s in changed.forEach { s.replace($0) } }
        AppLog.line("markup: flipped selection")
    }

    /// arrows nudge the selection a point, ⇧ ten — each press one undo step
    func nudgeSelection(by d: CGVector) -> Bool {
        guard !selection.isEmpty, gesture == nil else { return false }
        let moved = AnnotationGroup.moved(selectedAnnotations, by: d)
        edit { $0.replaceGroup(moved) }
        return true
    }

    /// the nudge an arrow key asks for, or nil for any other key
    static func selectionNudge(for e: NSEvent) -> CGVector? {
        let step = e.modifierFlags.contains(.shift) ? bigNudge : 1
        switch e.keyCode {
        case 123: return CGVector(dx: -step, dy: 0)
        case 124: return CGVector(dx: step, dy: 0)
        case 125: return CGVector(dx: 0, dy: -step) // AppKit's y points up
        case 126: return CGVector(dx: 0, dy: step)
        default: return nil
        }
    }

    /// ⌥ held at the press of a Select move: a drag that copies `annotations`
    /// once the pointer moves — Illustrator's ⌥-drag duplicate; nil without ⌥
    func optionDuplicateGesture(_ annotations: [Annotation], at p: CGPoint) -> Gesture? {
        guard NSEvent.modifierFlags.contains(.option), !annotations.isEmpty else { return nil }
        return .group(annotations, from: p, duplicate: true)
    }

    /// ⌘D: the selection duplicated a little down and right, selected — one undo step
    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        finishPen(); commitEditing()
        let (s, copies) = withCopies(of: selectedAnnotations, offset: CGVector(dx: 10, dy: -10))
        edit { $0 = s }
        setSelection(AnnotationSelection(copies.map(\.id)))
        AppLog.line("markup: duplicated \(copies.count)")
    }

    /// the stack with copies of `annotations` (fresh ids, `offset` away)
    /// just above the topmost original, in their own order
    private func withCopies(of annotations: [Annotation],
                            offset: CGVector) -> (LayerStack, [Annotation]) {
        // attachments between the copies follow the copies
        let ids = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, UUID()) })
        let copies = LayerStack.copies(of: annotations.map { $0.moved(by: offset) }, ids: ids)
        for (a, c) in zip(annotations, copies) {
            // a linked Canvas whose package is gone draws from the snapshot kept under its id
            if let snapshot = assets.images[a.id] { assets.images[c.id] = snapshot }
        }
        let top = annotations.compactMap { a in stack.annotations.firstIndex { $0.id == a.id } }.max()
            ?? stack.annotations.count - 1
        var s = stack
        for (i, c) in copies.enumerated() {
            s.add(c)
            s.move(c.id, to: top + 1 + i)
        }
        return (s, copies)
    }

    /// ⌘C: the selection onto the clipboard as Annotations wadjet pastes back,
    /// plus an image of them for other apps; false with nothing selected
    @discardableResult
    func copySelection() -> Bool {
        guard !selection.isEmpty else { return false }
        AnnotationClipboard.copy(selectedAnnotations, assets: assets, windowLayers: windowLayers)
        AppLog.line("markup: copied \(selection.count)")
        return true
    }

    /// ⌘X: copy, then delete
    @discardableResult
    func cutSelection() -> Bool {
        guard copySelection() else { return false }
        deleteSelection()
        return true
    }

    /// pastes the copied Annotations centred on `p` as one undo step,
    /// selected with Select armed; false unless the clipboard holds Annotations wadjet copied
    func pasteAnnotations(from pb: NSPasteboard, at p: CGPoint) -> Bool {
        guard let clip = AnnotationClipboard.contents(of: pb) else { return false }
        finishPen(); commitEditing()
        for (k, v) in clip.images { assets.images[k] = v }
        for (k, v) in clip.canvases { assets.canvases[k] = v }
        for (k, v) in clip.embedded { assets.embedded[k] = v }
        let box = AnnotationGroup.bounds(of: clip.annotations)
        let d = CGVector(dx: p.x - box.midX, dy: p.y - box.midY)
        // attachments between pasted Annotations follow the pasted copies
        let ids = Dictionary(clip.annotations.map { ($0.id, UUID()) }, uniquingKeysWith: { a, _ in a })
        let renamed = LayerStack.copies(of: clip.annotations, ids: ids)
        let pasted = zip(clip.annotations, renamed).compactMap { a, r -> Annotation? in
            var c = r.moved(by: d)
            c.hidden = false; c.locked = false
            if let snapshot = clip.snapshots[a.id] { assets.images[c.id] = snapshot }
            // a window from another Canvas lands as an image of its pixels:
            // this Canvas has no layer for it to name
            if case let .window(layerID, frame) = c.kind, windowLayers[layerID] == nil {
                guard let image = clip.windowImages[layerID] else { return nil }
                let asset = UUID()
                assets.images[asset] = image
                c.kind = .image(asset: asset, ImagePlacement(
                    frame: frame, crop: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                    border: .hidden))
            }
            return c
        }
        guard !pasted.isEmpty else { return false }
        edit { s in pasted.forEach { s.add($0) } }
        syncPanels()
        setSelection(AnnotationSelection(pasted.map(\.id)))
        if armed != .select { isScreen ? AppDelegate.shared?.trigger(.select) : arm(.select) }
        AppLog.line("markup: pasted \(pasted.count) annotations")
        return true
    }

    /// the screen's armed-session keys beyond Delete: ⌘A, ⌘C, ⌘X, ⌘D, and
    /// the arrows; true when the key was Markup's
    func handleSelectionKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        // only keys aimed at the screen's Markup — its panels, the Freeze Frame
        // under them, or the Layers window — not an Editor, Settings, or a text field
        guard !textHasFocus, e.window is MarkupPanel || e.window is OverlayPanel
                || (e.window != nil && e.window?.windowNumber == LayersWindow.shared.windowNumber)
        else { return false }
        if mods == .command {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "a": selectAll(); return true
            case "c": return copySelection()
            case "x": return cutSelection()
            case "d": if selection.isEmpty { return false }; duplicateSelection(); return true
            default: return false
            }
        }
        guard mods.isSubset(of: .shift), let d = Self.selectionNudge(for: e) else { return false }
        return nudgeSelection(by: d)
    }
}

/// the multi-selection chrome a MarkupView draws above the Annotations
struct SelectionChrome {
    /// each selected Annotation's outline, while several are selected
    var outlines: [CGPath] = []
    /// the shared bounding box and its grips, while several are selected
    var box: CGRect?
    var handles: [(handle: SelectionHandle, at: CGPoint)] = []
    /// Select's marquee in flight
    var marquee: CGRect?
}

/// Annotations copied with ⌘C. The system pasteboard gets one item: the
/// Annotations as a private Canvas package wadjet pastes back, even after a
/// relaunch, and a PNG of them for other apps. The live copy stays in memory
/// too, so a paste before anything else replaces the clipboard keeps opened
/// linked Canvases live instead of their snapshots.
@MainActor
enum AnnotationClipboard {
    static let type = NSPasteboard.PasteboardType("cx.mia.wadjet.annotations")
    private static var clip: AnnotationClip?
    private static var changeCount = -1

    static func copy(_ annotations: [Annotation], assets: MarkupAssets,
                     windowLayers: [UUID: CanvasWindowLayer]) {
        var c = AnnotationClip(annotations: annotations)
        for a in annotations {
            switch a.kind {
            case let .image(asset, _): c.images[asset] = assets.images[asset]
            case let .canvas(.linked(link), _):
                c.canvases[link.url] = assets.canvases[link.url]
                c.snapshots[a.id] = assets.images[a.id]
            case let .canvas(.embedded(name), _): c.embedded[name] = assets.embedded[name]
            case let .window(id, _): c.windowImages[id] = windowLayers[id]?.image
            case .line, .path, .censor, .shape, .counter, .magnify, .text: break
            }
        }
        let item = NSPasteboardItem()
        do {
            let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            let data = try c.pasteboardData(scale: scale)
            item.setData(data.package, forType: type)
            item.setData(data.png, forType: .png)
        } catch {
            // the in-memory copy still pastes inside wadjet until the clipboard changes
            AppLog.line("markup: couldn't put annotations on the clipboard: \(error)")
            item.setData(Data(), forType: type)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        clip = c
        changeCount = pb.changeCount
        AppState.shared.lastClipboard = "<\(annotations.count) annotations>"
    }

    /// a cheap type check — no decoding — for Edit ▸ Paste
    static func canRead(_ pb: NSPasteboard) -> Bool { pb.types?.contains(type) == true }

    /// the copied Annotations on `pb`: the live copy while wadjet's own is
    /// still the latest on the general pasteboard, else decoded from the package
    static func contents(of pb: NSPasteboard) -> AnnotationClip? {
        guard canRead(pb) else { return nil }
        if pb == .general, pb.changeCount == changeCount, let clip { return clip }
        guard let data = pb.data(forType: type), !data.isEmpty else { return nil }
        do { return try AnnotationClip(package: data) } catch {
            AppLog.line("markup: unreadable annotations on the clipboard: \(error)")
            return nil
        }
    }
}
