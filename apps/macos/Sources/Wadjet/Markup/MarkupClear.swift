import AppKit
import SwiftUI
import WadjetKit

// Clear Annotations with feedback: the toolbar's lens glides to the Clear
// cell, every Annotation fades out on every display, then the clear lands and
// the island goes the way IslandRule says. With nothing on screen the Clear
// cell shakes instead. A Clear that closes the toolbar stays undoable with ⌘Z
// for ClearFeedback.undoGrace seconds.

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

    /// keeps the screen's undo history and ⌘Z alive past a closing toolbar
    /// for ClearFeedback.undoGrace seconds; open it before the Clear records
    func openUndoGrace() {
        guard isScreen else { return }
        undoGrace.open(at: .now)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ClearFeedback.undoGrace + 0.05))
            // a later Clear's grace runs on its own timer
            guard let self, !self.undoGrace.isOpen(at: .now) else { return }
            self.endUndoGrace()
        }
    }
    /// history ends now if the toolbar is closed and nothing is left, and ⌘Z unbinds
    func endUndoGrace() {
        undoGrace.close()
        syncSession()
    }
    /// ⌘Z in the grace brought the Annotations back: so does their island
    func undidInGrace() {
        guard isScreen, undoGrace.isOpen(at: .now) else { return }
        AppLog.line("markup: Clear undone after the toolbar closed")
        if AppState.shared.phase == .desktop { AppDelegate.shared?.overlayCtrl.syncDesktopChrome() }
        endUndoGrace()
    }
}

extension AppDelegate {
    /// a Clear from the toolbar, a Shortcut, or cmd.sh: fade, then clear.
    /// On the live toolbar Clear disarms the armed Markup Tool first, so the
    /// toolbar and island go once the screen is empty; a Freeze Frame keeps
    /// its Tool and stays, and a Recording keeps its island (IslandRule).
    func clearAnnotationsWithFeedback() {
        let s = AppState.shared, mc = MarkupController.shared, armed = s.tool
        let r = mc.fadeOutThenClear(beforeClear: {
            // only the Tool armed at the tap — not one armed during the fade (a paste arms Select)
            if s.phase == .toolbar, let t = armed, t.kind == .markup, s.tool == t {
                s.tool = nil; AppLog.line("markup: Clear disarmed")
            }
            mc.openUndoGrace()
        }, afterClear: { [self] in
            AppLog.line("markup: cleared")
            s.clearing = false
            overlayCtrl.syncDesktopChrome()
            // the toolbar stayed (a Freeze Frame): its history lives on anyway
            if s.toolbarOpen { mc.undoGrace.close() }
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

extension ToolbarView {
    /// a tap on Clear: the lens glides from the selected Tool to Clear, the way
    /// selecting a Tool travels, and Clear holds the highlight while the
    /// Annotations fade. With no visible selection the highlight just lands.
    func clearTap() {
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
