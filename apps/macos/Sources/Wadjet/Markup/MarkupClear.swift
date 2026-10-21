import AppKit
import SwiftUI
import WadjetKit

// Clear Annotations with feedback: the toolbar's lens glides to the Clear
// cell, every Annotation fades out on every display, then the clear lands and
// the island goes the way IslandRule says. With nothing on screen the Clear
// cell shakes instead. Afterwards (ClearUndo): ⌘Z restores it for 3 s, the
// Clear cell reads Undo for 6 s, and a Clear that closed the toolbar keeps the
// collapsed island for 3 s with an Undo ring draining around its glyph; a
// Recording's own island shows the ring beside its time. A click on the ring
// undoes the Clear.

extension MarkupView {
    /// fades the whole Markup view (Annotations, their chrome, Magnify rims)
    /// and scales its canvas down about the Annotations on this view
    func fadeOut(_ fade: ClearFeedback.Fade, annotations: [Annotation]) {
        let ease = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1; opacity.toValue = 0
        opacity.duration = fade.duration; opacity.timingFunction = ease
        opacity.fillMode = .forwards; opacity.isRemovedOnCompletion = false
        layer?.add(opacity, forKey: Self.clearFadeKey)
        guard fade.endScale < 1 else { return }
        // canvas sits at the view's origin with its bounds at the region, so
        // a point's view coords are its global coords minus the region origin
        let region = canvas.bounds
        let here = annotations.filter { AnnotationGroup.bounds(of: [$0]).intersects(region) }
        var box = AnnotationGroup.bounds(of: here).intersection(region)
        if box.isNull { box = region }
        let c = CGPoint(x: box.midX - region.minX, y: box.midY - region.minY), k = CGFloat(fade.endScale)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, k, k, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DIdentity; scale.toValue = t
        scale.duration = fade.duration; scale.timingFunction = ease
        scale.fillMode = .forwards; scale.isRemovedOnCompletion = false
        canvas.add(scale, forKey: Self.clearFadeKey)
    }
    /// back to fully shown once the cleared stack has rendered
    func resetFade() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: Self.clearFadeKey)
        canvas.removeAnimation(forKey: Self.clearFadeKey)
        CATransaction.commit()
    }
    static let clearFadeKey = "clearFade"
}

extension MarkupController {
    /// the views drawing this Markup: the screen's panels, or the Editor's surface
    var markupViews: [MarkupView] { isScreen ? panels.map(\.view) : surface.map { [$0] } ?? [] }

    /// Clear with its fade: every view fades, then `beforeClear`, the clear
    /// itself (one undo step), and `afterClear` run once the fade has settled.
    /// The clear removes what was there at the tap: anything added during the
    /// fade (a paste) stays. Returns what happened — `.nothingToClear` does
    /// nothing — or nil while an earlier Clear is still fading.
    @discardableResult
    func fadeOutThenClear(beforeClear: @escaping @MainActor () -> Void = {},
                          afterClear: @escaping @MainActor () -> Void = {}) -> ClearFeedback.Response? {
        guard !clearInFlight else { return nil }
        // an unfinished Pen path is on screen too, though not yet in the stack
        let r = ClearFeedback.response(annotationCount: stack.annotations.count + (draft == nil ? 0 : 1),
                                       reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard case .fadeOut(let fade) = r else { return r }
        clearInFlight = true
        // the Pen draft too: disarming commits it into the stack with its id
        let views = markupViews, tapped = Set(stack.annotations.map(\.id) + [draft?.id].compactMap { $0 })
        views.forEach { $0.fadeOut(fade, annotations: stack.annotations) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(fade.settle))
            beforeClear()
            clear(keeping: Set(stack.annotations.map(\.id)).subtracting(tapped))
            views.forEach { $0.resetFade() }
            clearInFlight = false
            afterClear()
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Annotations cleared",
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        return r
    }

    /// a Clear is about to land: ⌘Z, the Undo cell and, with `ring`, the
    /// island's ring start now. Open it before the Clear records its step, so
    /// the step outlives a closing toolbar
    func offerUndo(ring: Bool) {
        guard isScreen else { return }
        clearUndo.cleared(at: .now, ring: ring)
        // the pointer may already rest on the island: the ring holds from the start
        if !hoveredIslands.isEmpty { clearUndo.hover(true, at: .now) }
        clearUndoChanged()
    }
    /// re-reads clearUndo now and wakes at its next change: ⌘Z unbinds at 3 s,
    /// the island goes when the ring empties, the Undo cell turns back into
    /// Clear and history ends with the offer
    func clearUndoChanged(chrome: Bool = true) {
        let now = Date.now
        if clearUndo.isActive, !clearUndo.offersUndo(at: now) { clearUndo.end() }
        let held = undoRingShown
        undoOffered = clearUndo.offersUndo(at: now)
        undoRingShown = clearUndo.holdsIsland(at: now)
        clearUndoWake?.cancel(); clearUndoWake = nil
        if let next = clearUndo.nextChange(after: now) {
            clearUndoWake = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.02))
                guard !Task.isCancelled else { return }
                self?.clearUndoChanged()
            }
        }
        syncSession()
        // the ring emptied: the island goes the way IslandRule says
        if chrome, held, !undoRingShown, AppState.shared.phase == .desktop {
            AppLog.line("markup: Undo ring emptied")
            AppDelegate.shared?.overlayCtrl.syncDesktopChrome()
        }
    }
    /// the pointer entered or left a display's island or toolbar: the ring
    /// holds while it's on any of them. The pointer itself, not the bar's
    /// expansion, which an armed Tool keeps up after the pointer leaves
    func islandHovered(_ inside: Bool, on display: Int) {
        guard isScreen else { return }
        let was = !hoveredIslands.isEmpty
        if inside { hoveredIslands.insert(display) } else { hoveredIslands.remove(display) }
        let now = !hoveredIslands.isEmpty
        guard clearUndo.isActive, now != was else { return }
        clearUndo.hover(now, at: .now)
        clearUndoChanged()
    }
    /// an edit after the Clear: "Undo Clear" would undo that edit instead
    func editedAfterClear() {
        guard clearUndo.isActive, !clearInFlight else { return }
        clearUndo.end()
        clearUndoChanged()
    }
    /// ⌘Z or the Undo cell brought the Annotations back: so does their island
    func undidClear() {
        guard isScreen, clearUndo.isActive else { return }
        AppLog.line("markup: Clear undone")
        clearUndo.end()
        clearUndoChanged(chrome: false)
        if AppState.shared.phase == .desktop { AppDelegate.shared?.overlayCtrl.syncDesktopChrome() }
    }
}

extension AppDelegate {
    /// a Clear from the toolbar, a Shortcut, or cmd.sh: fade, then clear.
    /// On the live toolbar Clear disarms the armed Markup Tool first, so the
    /// toolbar closes once the screen is empty and the collapsed island holds
    /// on with the Undo ring; a Recording keeps its own island (IslandRule)
    /// and shows the ring there. A Freeze Frame keeps its Tool and stays, so
    /// it gets no ring.
    func clearAnnotationsWithFeedback() {
        let s = AppState.shared, mc = MarkupController.shared, armed = s.tool
        let r = mc.fadeOutThenClear(beforeClear: {
            // only the Tool armed at the tap — not one armed during the fade (a paste arms Select)
            if s.phase == .toolbar, let t = armed, t.kind == .markup, s.tool == t {
                s.tool = nil; AppLog.line("markup: Clear disarmed")
            }
            mc.offerUndo(ring: s.phase != .frozen)
        }, afterClear: { [self] in
            AppLog.line("markup: cleared")
            s.clearing = false
            overlayCtrl.syncDesktopChrome()
            mc.syncSession()
        })
        switch r {
        case .nothingToClear?:
            s.clearRefusals += 1
            AppLog.line("markup: nothing to clear")
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Nothing to clear",
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        case .fadeOut?:
            s.clearing = true
            AppLog.line("markup: clearing")
        case nil: break
        }
    }
}

extension AppDelegate {
    /// the Undo cell: the Annotations a Clear removed come back, as with ⌘Z
    func undoClear() {
        let mc = MarkupController.shared
        guard mc.undoOffered else { return }
        AppLog.line("markup: Undo Clear tapped")
        mc.undo()
    }
}

extension ToolbarView {
    /// for a few seconds after a Clear its cell is an Undo button
    var clearReadsUndo: Bool { MarkupController.shared.undoOffered }
    /// a cell's icon: the Tool's own, or Undo's on the Clear cell
    func icon(for t: Tool) -> Image {
        t == .clearAnnotations && clearReadsUndo ? Image(systemName: "arrow.uturn.backward").resizable() : t.iconImage
    }
    /// a cell's label: the Tool's short title, or Undo on the Clear cell
    func label(for t: Tool) -> String { t == .clearAnnotations && clearReadsUndo ? "Undo" : t.shortTitle }

    /// a tap on Clear: the lens glides from the selected Tool to Clear, the way
    /// selecting a Tool travels, and Clear holds the highlight while the
    /// Annotations fade. With no visible selection the highlight just lands.
    func clearTap() {
        if clearReadsUndo { AppDelegate.shared?.undoClear(); return }
        let mc = MarkupController.shared
        if !mc.stack.isEmpty || mc.draft != nil, !mc.clearInFlight, let c = cellCentres[.clearAnnotations],
           let sel = s.tool, visibleTools.contains(sel), let from = cellCentres[sel] {
            if !travelling { snapLens(to: from) }
            travelling = true; travelStart = .now
            AppLog.line("travel -> Clear")
            setLensTarget(x: c.x)
            if reduceMotion { travelling = false } // the jump already landed
        }
        AppDelegate.shared?.trigger(.clearAnnotations)
    }
    /// the Clear landed and the bar is still up (a Freeze Frame): the lens
    /// goes back to the selected Tool
    func clearEnded() {
        guard !s.clearing, let t = s.tool, let c = cellCentres[t] else { return }
        if travelling { setLensTarget(x: c.x) } else { snapLens(to: c) }
    }
}

/// "nothing to clear": the cell shakes sideways a few points, or under
/// Reduce Motion dims for a moment. Each bump of `refusals` plays it once.
struct NothingToClearCue: ViewModifier {
    let refusals: Int
    @State private var shakes: CGFloat = 0
    @State private var dimmed = false
    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(shakes: shakes))
            .opacity(dimmed ? 0.4 : 1)
            .onChange(of: refusals) { old, new in
                guard new > old else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    withAnimation(.easeOut(duration: 0.1)) { dimmed = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        withAnimation(.easeOut(duration: 0.2)) { dimmed = false }
                    }
                } else {
                    withAnimation(.linear(duration: 0.36)) { shakes += 1 }
                }
            }
    }
}

/// one shake per whole step of `shakes`; at rest on every whole number
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = ClearFeedback.shakeOffset(progress: Double(shakes - shakes.rounded(.down)))
        return ProjectionTransform(CGAffineTransform(translationX: CGFloat(x), y: 0))
    }
}

/// VoiceOver for the Clear cell while it's Undo: one button named "Undo Clear"
struct UndoClearAccessibility: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Undo Clear")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { AppDelegate.shared?.undoClear() }
        } else {
            content
        }
    }
}

extension ToolbarView {
    /// the collapsed island shows a Clear's Undo ring: after a Clear that
    /// closed the toolbar, or beside a Recording's time
    var islandShowsRing: Bool { undoRingShown && annotationCount == nil }

    /// the ring as a button: a click undoes the Clear, and the island then
    /// stays collapsed under the pointer until it leaves
    var undoRingButton: some View {
        Button {
            _ = ringPointer.clickedRing()
            AppLog.line("markup: Undo ring clicked d\(displayIndex)")
            AppDelegate.shared?.undoClear()
        } label: {
            UndoRing(undo: MarkupController.shared.clearUndo, hot: ringPointer.onRing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Undo Clear")
        // only the collapsed island's ring takes clicks, never the bar's
        .allowsHitTesting(!expanded)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panel")) } action: { undoRingFrame = $0 }
        .onDisappear { undoRingFrame = .null }
    }

    /// re-reads the pointer against the ring: on its target the island
    /// stays collapsed; anywhere else on it hover expands as always
    func trackUndoRing() {
        var onRing = false
        if islandShowsRing, !expanded, let p = ctrl.toolbarPanels[displayIndex], !undoRingFrame.isNull {
            // view coords are bottom-up, the ring's frame top-down
            let ring = CGRect(x: undoRingFrame.minX, y: panelH - undoRingFrame.maxY,
                              width: undoRingFrame.width, height: undoRingFrame.height)
            let q = CGPoint(x: NSEvent.mouseLocation.x - p.frame.minX, y: NSEvent.mouseLocation.y - p.frame.minY)
            onRing = UndoRingPointer.target(ring: ring, island: shapeRectInView).contains(q)
        }
        ringPointer.moved(inside: hoverInside, onRing: onRing)
    }

    /// the pointer on the ring names it, since hover there doesn't open the bar
    func undoRingTip() {
        if ringPointer.onRing, let a = ctrl.panelScreenRect(undoRingFrame, on: displayIndex) {
            TipPanel.hover("Undo Clear", anchor: a)
        } else if TipPanel.current == "Undo Clear" {
            TipPanel.hide()
        }
    }
}

/// The collapsed island's Undo ring after a Clear, trailing on its own or
/// beside a Recording's time: an Undo glyph inside a ring that drains
/// clockwise from full to empty over ClearUndo.ring seconds, holding while the
/// pointer is on the island. Under Reduce Motion the ring gives way to the
/// seconds left beside the glyph, stepping 3, 2, 1. `hot` lights it while the
/// pointer is on it, as a click there undoes the Clear.
struct UndoRing: View {
    let undo: ClearUndo
    var hot = false
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let size: CGFloat = 14
    var body: some View {
        Group {
            if reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    HStack(spacing: 3) {
                        glyph
                        Text("\(undo.ringSeconds(at: ctx.date) ?? 0)").font(.system(size: 12)).monospacedDigit()
                    }
                    .fixedSize()
                }
            } else {
                TimelineView(.animation) { ctx in
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 1.5)
                        Circle().trim(from: 0, to: undo.ringLeft(at: ctx.date) ?? 0)
                            .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            // drains from 12 o'clock, clockwise
                            .rotationEffect(.degrees(-90))
                            .scaleEffect(x: -1)
                        glyph
                    }
                    .frame(width: Self.size, height: Self.size)
                }
            }
        }
        // the pointer on it: a soft disc behind, like a hovered control
        .background(Capsule().fill(.white.opacity(hot ? 0.22 : 0)).padding(-4))
        .contentShape(Rectangle().inset(by: -5))
        .animation(.easeOut(duration: 0.12), value: hot)
    }
    var glyph: some View {
        Image(systemName: "arrow.uturn.backward").font(.system(size: 7, weight: .bold))
    }
}
