import AppKit
import CoreImage
import SwiftUI
import WadjetKit

/// What the Editor window shows and edits live: Recrop mode, the in-flight
/// crop and corner radius (mid-drag values land here before the commit).
@MainActor @Observable
final class EditorState {
    var recrop = false
    var crop: CGRect
    var radius: CGFloat
    /// the toolbar reaches the window through here — a view can't hold its
    /// window controller without a retain cycle
    weak var wc: CanvasEditorWindowController?
    init(_ canvas: CanvasDocument) {
        crop = canvas.crop
        radius = canvas.cornerRadius
    }
}

/// centres the document while it's smaller than the scroll view
final class CentreClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if doc.frame.width < r.width {
            r.origin.x = doc.frame.midX - r.width / 2
        }
        if doc.frame.height < r.height {
            r.origin.y = doc.frame.midY - r.height / 2
        }
        return r
    }
}

/// The Editor window: a magnified Canvas, the floating Markup toolbar on top.
/// Keys (Delete, Escape, modifiers) go to the document view, its first responder.
final class CanvasEditorWindowController: NSWindowController, NSWindowDelegate {
    private var doc: CanvasEditorDocument? { document as? CanvasEditorDocument }
    private(set) var state: EditorState?
    let scrollView = NSScrollView()
    private(set) var canvasView: EditorCanvasView?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Wadjet Canvas"
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    /// builds the window's contents — called from makeWindowControllers after
    /// the document attaches (NSWindowController(window:) never runs
    /// windowDidLoad); restoration goes through the same path
    func setUp() {
        guard let doc, let window else { return }
        let state = EditorState(doc.canvas)
        self.state = state
        doc.onReload = { [weak self] in self?.reload() }

        let canvasView = EditorCanvasView(doc: doc, state: state)
        self.canvasView = canvasView
        state.wc = self
        doc.markup.snapBounds = doc.canvas.displayBounds
        scrollView.contentView = CentreClipView(frame: .zero)
        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder
        NotificationCenter.default.addObserver(self, selector: #selector(magnifyEnded(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        window.contentViewController = NSHostingController(rootView: CanvasEditorRoot(
            doc: doc, state: state, scroll: scrollView))
        window.initialFirstResponder = canvasView

        // initial size: the crop, capped to 80% of the pointer's screen, at least 560×420
        let vf = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: max(560, min(state.crop.width, vf.width * 0.8)),
                          height: max(420, min(state.crop.height, vf.height * 0.8)))
        window.setContentSize(size)
        window.center()
        rebuild()
        zoomToFit(nil)
        window.makeFirstResponder(canvasView)
        installToolbar()
        // restoration at launch: the window already exists when the policy syncs
        DispatchQueue.main.async { AppDelegate.shared?.syncActivationPolicy() }
    }

    /// the document changed under the window (Revert, undo of a crop): reseed.
    /// Annotations are untouched — read() reloads the Markup stack on a Revert
    private func reload() {
        guard let doc, let state else { return }
        state.crop = doc.canvas.crop
        state.radius = doc.canvas.cornerRadius
        rebuild()
    }

    /// docRect/mask/backdrop follow the mode and the live crop
    func rebuild() {
        canvasView?.rebuild()
    }

    private func syncMagnification() {
        guard let doc, let canvasView else { return }
        doc.markup.zoom = scrollView.magnification
        canvasView.syncScale(backing: window?.backingScaleFactor ?? 2, zoom: scrollView.magnification)
    }

    @objc private func magnifyEnded(_ n: Notification) { syncMagnification() }

    // MARK: zoom (View menu, nil-targeted responder actions)

    private func magnify(_ factor: CGFloat) {
        scrollView.magnification = min(max(scrollView.magnification * factor,
            scrollView.minMagnification), scrollView.maxMagnification)
        syncMagnification()
    }
    @IBAction func zoomIn(_ sender: Any?) { magnify(1.25) }
    @IBAction func zoomOut(_ sender: Any?) { magnify(1 / 1.25) }
    @IBAction func zoomImageToActualSize(_ sender: Any?) {
        scrollView.magnification = 1
        syncMagnification()
    }
    @IBAction func zoomToFit(_ sender: Any?) {
        guard let cv = canvasView, cv.frame.width > 0, cv.frame.height > 0 else { return }
        let visible = scrollView.contentSize
        guard visible.width > 0, visible.height > 0 else { return }
        scrollView.magnification = min(max(min(visible.width / cv.frame.width,
            visible.height / cv.frame.height), scrollView.minMagnification), scrollView.maxMagnification)
        syncMagnification()
    }

    // MARK: window delegate

    func windowDidBecomeMain(_ n: Notification) {
        guard let doc else { return }
        EditorFocus.shared.markup = doc.markup
        EditorPanel.syncAll()
    }
    func windowDidResignMain(_ n: Notification) {
        guard let doc, EditorFocus.shared.markup === doc.markup else { return }
        EditorFocus.shared.markup = nil
        EditorPanel.syncAll()
    }
    func windowWillClose(_ n: Notification) {
        if let doc, EditorFocus.shared.markup === doc.markup { EditorFocus.shared.markup = nil }
        canvasView?.markupView.censors?.stop()
        AppDelegate.shared?.syncActivationPolicy(closing: window)
        EditorPanel.syncAll()
    }
}

/// The scroll view's document: display and window layers, the Markup surface,
/// and in Recrop mode the crop overlay — all in Canvas coordinates.
final class EditorCanvasView: NSView {
    let doc: CanvasEditorDocument
    let state: EditorState
    /// holds the backdrop layers; bounds origin shifts so children take Canvas coords
    private let container = CALayer()
    private(set) var markupView: MarkupView!
    private var overlay: RecropOverlay?
    /// what the view shows: the crop normally, every display in Recrop
    private var docRect: CGRect = .zero
    /// 60‰ of the document, at least 24 pt — room around the picture
    private var margin: CGFloat = 24
    /// the outset document rect — every child layer's coordinate space
    private(set) var region: CGRect = .zero

    init(doc: CanvasEditorDocument, state: EditorState) {
        self.doc = doc
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        container.anchorPoint = .zero
        container.position = .zero
        layer?.addSublayer(container)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// markup stays crisp at any zoom: layer scale = backing × magnification
    func syncScale(backing: CGFloat, zoom: CGFloat) {
        markupView.scale = backing * zoom
        markupView.canvas.contentsScale = backing * zoom
        doc.markup.render()
        overlay?.needsLayout = true
    }

    /// lays the view out for the current mode and crop; called on open,
    /// Revert, an undo/redo of the crop, and Recrop toggles
    func rebuild() {
        let canvas = doc.canvas
        let content = state.recrop ? canvas.displayBounds : state.crop
        margin = max(24, 0.06 * max(content.width, content.height))
        region = content.insetBy(dx: -margin, dy: -margin)
        docRect = content
        frame = NSRect(origin: .zero, size: region.size)

        container.bounds = region
        buildBackdrop()

        if markupView == nil {
            markupView = MarkupView(frame: NSRect(origin: .zero, size: region.size),
                                    region: region, scale: window?.backingScaleFactor ?? 2,
                                    controller: doc.markup, censors: censorSource(),
                                    magnifiers: magnifierSource())
            doc.markup.surface = markupView
            addSubview(markupView)
        } else {
            markupView.frame = NSRect(origin: .zero, size: region.size)
            markupView.canvas.bounds = region
            markupView.content.bounds = region
            markupView.content.position = region.origin
            markupView.guidesLayer.bounds = region
        }
        // the crop masks the backdrop and the Annotations — never the
        // selection chrome above them
        if state.recrop {
            container.mask = nil
            markupView.content.mask = nil
        } else {
            container.mask = cropMask()
            markupView.content.mask = cropMask()
        }

        if state.recrop {
            if overlay == nil {
                let o = RecropOverlay(state: state, doc: doc, view: self)
                o.frame = NSRect(origin: .zero, size: region.size)
                addSubview(o)
                overlay = o
            } else {
                overlay?.needsLayout = true
            }
        } else {
            overlay?.removeFromSuperview()
            overlay = nil
        }
        doc.markup.render()
    }

    /// only the crop's edge moved: refresh the mask or the Recrop overlay —
    /// the backdrop and document rect stay put
    func cropChanged() {
        if state.recrop {
            overlay?.needsLayout = true
        } else {
            container.mask = cropMask()
            markupView?.content.mask = cropMask()
        }
    }

    /// one CALayer per display, then window layers by z-order — Canvas coords.
    /// An isolating window Screenshot replaces the desktop under it, so the
    /// displays get a hole where its transparent pixels must not show through.
    private func buildBackdrop() {
        let canvas = doc.canvas
        let displays = CALayer()
        displays.anchorPoint = .zero
        // inside container's shifted bounds space, sit at the region's origin
        displays.position = region.origin
        displays.bounds = region
        displays.sublayers = canvas.layout.map { display in
            let l = CALayer()
            l.contents = canvas.displayImages[display.id]
            l.frame = display.frame
            l.contentsGravity = .resize
            l.preferredDynamicRange = .high
            return l
        }
        // windows an Annotation names draw on the Markup surface, not the backdrop
        let isolated = canvas.windowLayers.filter { $0.id == nil && $0.isolatesBackground }
        if !isolated.isEmpty {
            let p = CGMutablePath()
            p.addRect(region)
            for w in isolated { p.addRect(w.frame) }
            let m = CAShapeLayer()
            m.path = p
            m.fillRule = .evenOdd
            m.frame = displays.bounds
            m.bounds = displays.bounds // Canvas coords, like `displays`' children
            displays.mask = m
        }
        var layers: [CALayer] = [displays]
        for w in canvas.windowLayers.filter({ $0.id == nil }).sorted(by: { $0.zOrder < $1.zOrder }) {
            let l = CALayer()
            l.contents = w.image
            l.frame = w.frame
            l.contentsGravity = .resize
            l.preferredDynamicRange = .high
            layers.append(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.sublayers = layers
        CATransaction.commit()
    }

    /// one rounded-crop mask per masked layer — the path is in Canvas
    /// coordinates, matching the masked layers' bounds-origin trick
    private func cropMask() -> CAShapeLayer {
        let radius = min(state.radius, doc.canvas.maxCornerRadius)
        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: state.crop, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
        mask.frame = region
        mask.bounds = region // the path is in Canvas coords, like the masked layer's children
        return mask
    }

    /// Censors in an Editor sample exactly what output flattens: the same
    /// renderer over the whole Canvas, without Annotations or the crop's
    /// corner — `render` re-runs per Censor with the windows stacked beneath it
    private func censorSource() -> CensorLayers? {
        let canvas = doc.canvas
        return CensorLayers(coverage: canvas.displayBounds, scale: 1) { windows in
            var c = canvas
            c.layerStack = LayerStack(windows)
            c.cornerRadius = 0
            do {
                return try c.flatten(crop: c.displayBounds, scale: 1)
            } catch {
                AppLog.line("censor source: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Magnifies in an Editor sample what flatten draws: the Canvas's displays
    /// plus the layers beneath each one, at the window's backing scale so
    /// they stay crisp
    private func magnifierSource() -> MagnifierLayers? {
        let canvas = doc.canvas
        let sources = canvas.layout.compactMap { d -> MagnifyRenderer.Source? in
            canvas.displayImages[d.id].map { (CIImage(cgImage: $0), d.frame) }
        }
        guard !sources.isEmpty else { return nil }
        return MagnifierLayers(staticSources: sources, scale: window?.backingScaleFactor ?? 2) {
            [weak doc = self.doc] layers, rect, scale in
            do {
                // the live document: its images and Canvases as edited so far
                return try doc?.current.beneathSource(layers: layers, rect: rect, scale: scale)
            } catch {
                AppLog.line("magnifier source: \(error.localizedDescription)")
                return nil
            }
        }
    }

    // MARK: keys — the view is the window's first responder

    /// ⌘-modified keys travel the responder chain via performKeyEquivalent —
    /// menus take theirs first, the rest land here (keyDown never sees ⌘)
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // the in-place text editor owns ⌘-keys while it's typing — no restack
        if doc.markup.editing != nil { return super.performKeyEquivalent(with: e) }
        if e.modifierFlags.contains(.command) {
            let shift = e.modifierFlags.contains(.shift)
            switch e.charactersIgnoringModifiers ?? "" {
            // charactersIgnoringModifiers keeps Shift: ⇧] types } on US layouts
            case "]", "}": doc.markup.restackSelection(shift ? .front : .up); return true
            case "[", "{": doc.markup.restackSelection(shift ? .back : .down); return true
            case "d" where !shift && !doc.markup.selection.isEmpty:
                doc.markup.duplicateSelection(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { // Delete, Fn+Delete
            doc.markup.deleteSelection()
            return
        }
        if e.keyCode == 36 || e.keyCode == 76 { // Return, keypad Enter
            if doc.markup.finishPen() { return }
        }
        // arrows nudge Direct Select's anchors
        if let d = MarkupController.nudge(for: e), doc.markup.nudgeAnchors(by: d) { return }
        // arrows nudge the selection, ⇧ by ten
        if doc.markup.editing == nil,
           e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let d = MarkupController.selectionNudge(for: e), doc.markup.nudgeSelection(by: d) { return }
        if e.keyCode == 53 { // Escape
            if doc.markup.finishPen() { return }
            if !doc.markup.deselect(), state.recrop {
                state.recrop = false
                rebuild()
                state.wc?.zoomToFit(nil)
            }
            return
        }
        // the Markup Tool Keys: one unmodified letter arms a Tool or variant —
        // never while a text is being typed
        if !state.recrop, doc.markup.editing == nil,
           let key = MarkupToolKey.key(pressed: e.charactersIgnoringModifiers,
                                       modified: !e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty),
           doc.markup.press(key) {
            // only when the pointer rests on the Markup surface, not a toolbar or scroller
            if let content = window?.contentView,
               let hit = content.hitTest(content.convert(window!.mouseLocationOutsideOfEventStream, from: nil)),
               hit === markupView || hit.isDescendant(of: markupView) {
                markupView.setToolCursor()
            }
            return
        }
        super.keyDown(with: e)
    }

    // MARK: paste — Edit ▸ Paste reaches the first responder

    /// canvas coords of the pointer when it's over the canvas, else the
    /// visible region's centre
    private var pastePoint: CGPoint {
        let p = markupView.canvasPoint(fromScreen: NSEvent.mouseLocation)
        if region.contains(p) { return p }
        let centre = convert(CGPoint(x: visibleRect.midX, y: visibleRect.midY), to: nil)
        return markupView.canvasPoint(fromScreen: window!.convertPoint(toScreen: centre))
    }
    @objc func paste(_ sender: Any?) { doc.markup.paste(from: .general, at: pastePoint) }
    /// Edit ▸ Copy: the selected Annotations, or the whole Canvas with none selected
    @objc func copy(_ sender: Any?) {
        if !doc.markup.copySelection() { doc.copy(sender) }
    }
    @objc func cut(_ sender: Any?) { doc.markup.cutSelection() }
    override func selectAll(_ sender: Any?) { doc.markup.selectAll() }

    /// modifiers change a drag in flight without the pointer moving — the
    /// screen's flags monitor does the same there
    override func flagsChanged(with e: NSEvent) {
        markupView.setToolCursor()
        if doc.markup.draft != nil || doc.markup.reactsToModifiers {
            doc.markup.drag(to: markupView.canvasPoint(fromScreen: NSEvent.mouseLocation),
                            constrained: DragModifiers(e.modifierFlags).constrains)
        }
        super.flagsChanged(with: e)
    }
}

/// The crop over a Recrop canvas: dim outside the rounded crop, an accent
/// stroke, and eight grips at constant on-screen size. Drags move edges live;
/// mouse-up commits one undoable step.
final class RecropOverlay: NSView {
    let state: EditorState
    let doc: CanvasEditorDocument
    weak var canvasView: EditorCanvasView?
    private let dim = CAShapeLayer()
    private let stroke = CAShapeLayer()
    private let grips = CAShapeLayer()
    private let accent = CGColor(srgbRed: 0.20, green: 0.84, blue: 0.58, alpha: 1)
    private var drag: (edges: CropEdges, from: CGPoint, crop: CGRect, radius: CGFloat)?

    init(state: EditorState, doc: CanvasEditorDocument, view: EditorCanvasView) {
        self.state = state
        self.doc = doc
        canvasView = view
        super.init(frame: .zero)
        wantsLayer = true
        for l in [dim, stroke, grips] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }

    private var magnification: CGFloat { (canvasView?.enclosingScrollView)?.magnification ?? 1 }
    /// the outset document rect — the canvas view's coordinate space
    private var region: CGRect { canvasView?.region ?? bounds }

    private func canvasPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x + region.minX, y: p.y + region.minY)
    }
    /// canvas → view-local
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - region.minX, y: p.y - region.minY)
    }

    override func layout() {
        super.layout()
        let mag = magnification
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // dim everything outside the rounded crop
        let r = CGRect(origin: local(state.crop.origin), size: state.crop.size)
        let radius = min(state.radius, doc.canvas.maxCornerRadius)
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        dimPath.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        dim.path = dimPath
        dim.fillRule = .evenOdd
        dim.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
        // the crop's edge in malachite
        stroke.path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        stroke.fillColor = nil
        stroke.strokeColor = accent
        stroke.lineWidth = 1.5 / mag
        // 8 grips, constant on-screen size
        let g = CGMutablePath()
        let d = 7 / mag
        for p in Self.gripPoints(of: r) {
            g.addEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        }
        grips.path = g
        grips.fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        grips.strokeColor = accent
        grips.lineWidth = 1 / mag
        CATransaction.commit()
    }

    /// the eight grip centres: four corners, four edge midpoints
    static func gripPoints(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    override func mouseDown(with e: NSEvent) {
        let p = canvasPoint(e)
        guard let edges = Recrop.edges(at: p, of: state.crop, radius: 6 / magnification) else { return }
        drag = (edges, from: p, crop: state.crop, radius: state.radius)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let drag else { return }
        let p = canvasPoint(e)
        state.crop = Recrop.drag(drag.crop, edges: drag.edges,
                                 by: CGVector(dx: p.x - drag.from.x, dy: p.y - drag.from.y),
                                 within: doc.canvas.displayBounds, minSize: 16)
        needsLayout = true
    }
    override func mouseUp(with e: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        if state.crop != drag.crop {
            doc.setCrop(state.crop, cornerRadius: state.radius,
                        undoingTo: (drag.crop, drag.radius))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func cursorUpdate(with e: NSEvent) { updateCursor(at: canvasPoint(e)) }
    override func mouseMoved(with e: NSEvent) { updateCursor(at: canvasPoint(e)) }
    private func updateCursor(at p: CGPoint) {
        guard let edges = Recrop.edges(at: p, of: state.crop, radius: 6 / magnification) else {
            NSCursor.arrow.set()
            return
        }
        if edges.isEmpty { NSCursor.openHand.set(); return }
        let position: NSCursor.FrameResizePosition = switch edges {
        case [.minX, .maxY]: .topLeft
        case [.maxX, .maxY]: .topRight
        case [.minX, .minY]: .bottomLeft
        case [.maxX, .minY]: .bottomRight
        case [.minX]: .left
        case [.maxX]: .right
        case [.minY]: .bottom
        default: .top
        }
        NSCursor.frameResize(position: position, directions: .all).set()
    }
}

extension EditorCanvasView: NSMenuItemValidation {
    /// Edit ▸ Paste is enabled while the clipboard holds something Markup takes
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)):
            MarkupPasteboard.canRead(.general) || AnnotationClipboard.canRead(.general)
        case #selector(cut(_:)): !doc.markup.selection.isEmpty
        case #selector(selectAll(_:)): !doc.markup.stack.isEmpty
        default: true
        }
    }
}
