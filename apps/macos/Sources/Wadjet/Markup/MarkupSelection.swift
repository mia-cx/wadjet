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
        setSelection(AnnotationSelection(kept + added))
    }

    /// ⌘A: every Annotation that isn't locked or hidden; arms Select when
    /// nothing is armed. A Pen path or text session in flight commits first.
    func selectAll() {
        finishPen(); commitEditing()
        guard !stack.isEmpty else { return }
        if armed == nil { isScreen ? AppDelegate.shared?.trigger(.select) : arm(.select) }
        setSelection(.all(in: stack.annotations))
        AppLog.line("markup: selected all (\(selection.count))")
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
        let members = selectedAnnotations
        let box = AnnotationGroup.bounds(of: members)
        if let h = AnnotationGroup.handle(at: p, of: box, radius: Self.handleHitRadius / zoom,
                                          minExtent: Self.handleMinExtent / zoom,
                                          rotateOffset: Self.rotateOffset / zoom) {
            gesture = .groupHandle(h, members, from: p)
            return true
        }
        guard !shift, let hit = stack.topmost(at: p, tolerance: Self.hitTolerance / zoom),
              selection.contains(hit.id) else { return false }
        snapper = MarkupSnapper(stack: LayerStack(stack.annotations.filter { !selection.contains($0.id) }),
                                excluding: nil, canvasBounds: snapBounds, pixelSources: snapPixelSources)
        gesture = .group(members, from: p, duplicate: selecting && NSEvent.modifierFlags.contains(.option))
        return true
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

    /// whether ⇧ or ⌥ changing mid-drag reshapes the gesture in flight
    var reshapesOnModifiers: Bool {
        switch gesture {
        case .drawing, .cutting, .groupHandle: true
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
        edit { s in moved.forEach { s.replace($0) } }
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
        let copies = annotations.map { a -> Annotation in
            var c = a.moved(by: offset)
            c.id = UUID()
            return c
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

    /// ⌘C: the selection onto the clipboard as Annotations wadjet pastes back
    /// (other apps see nothing new); false with nothing selected
    @discardableResult
    func copySelection() -> Bool {
        guard !selection.isEmpty else { return false }
        AnnotationClipboard.copy(selectedAnnotations, assets: assets)
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
    /// selected with Select armed; false unless the clipboard holds wadjet's copy
    func pasteAnnotations(from pb: NSPasteboard, at p: CGPoint) -> Bool {
        guard let clip = AnnotationClipboard.contents(of: pb) else { return false }
        finishPen(); commitEditing()
        for (k, v) in clip.images { assets.images[k] = v }
        for (k, v) in clip.canvases { assets.canvases[k] = v }
        for (k, v) in clip.embedded { assets.embedded[k] = v }
        let box = AnnotationGroup.bounds(of: clip.annotations)
        let d = CGVector(dx: p.x - box.midX, dy: p.y - box.midY)
        let pasted = clip.annotations.map { a -> Annotation in
            var c = a.moved(by: d)
            c.id = UUID()
            c.hidden = false; c.locked = false
            return c
        }
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
        guard !textHasFocus else { return false }
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

/// Annotations copied with ⌘C, kept in memory with the pixels and Canvases
/// they draw from. The general pasteboard gets a private marker so its
/// change count says whether wadjet's copy is still the latest one.
@MainActor
enum AnnotationClipboard {
    static let type = NSPasteboard.PasteboardType("cx.mia.wadjet.annotations")
    struct Clip {
        var annotations: [Annotation]
        var images: [UUID: CGImage] = [:]
        var canvases: [URL: CanvasDocument] = [:]
        var embedded: [String: CanvasDocument] = [:]
    }
    private static var clip: Clip?
    private static var changeCount = -1

    static func copy(_ annotations: [Annotation], assets: MarkupAssets) {
        var c = Clip(annotations: annotations)
        for a in annotations {
            switch a.kind {
            case let .image(asset, _): c.images[asset] = assets.images[asset]
            case let .canvas(.linked(link), _): c.canvases[link.url] = assets.canvases[link.url]
            case let .canvas(.embedded(name), _): c.embedded[name] = assets.embedded[name]
            case .line, .path, .censor, .shape, .counter, .magnify, .text, .window: break
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(Data(), forType: type)
        clip = c
        changeCount = pb.changeCount
        AppState.shared.lastClipboard = "<\(annotations.count) annotations>"
    }

    /// the copied Annotations while `pb` is the general pasteboard and
    /// nothing has replaced wadjet's copy on it
    static func contents(of pb: NSPasteboard) -> Clip? {
        guard pb == .general, pb.changeCount == changeCount,
              pb.types?.contains(type) == true else { return nil }
        return clip
    }
}
