import AppKit
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
/// Keys (Delete, Escape, ⌘-select) go to the document view, its first responder.
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

    override func windowDidLoad() {
        super.windowDidLoad()
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
        ColoursPanel.shared.sync()
    }
    func windowDidResignMain(_ n: Notification) {
        guard let doc, EditorFocus.shared.markup === doc.markup else { return }
        EditorFocus.shared.markup = nil
        ColoursPanel.shared.sync()
    }
    func windowWillClose(_ n: Notification) {
        if let doc, EditorFocus.shared.markup === doc.markup { EditorFocus.shared.markup = nil }
        canvasView?.markupView.censors?.stop()
        AppDelegate.shared?.syncActivationPolicy(closing: window)
        ColoursPanel.shared.sync()
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
        layer?.mask = state.recrop ? nil : cropMask()

        if markupView == nil {
            markupView = MarkupView(frame: NSRect(origin: .zero, size: region.size),
                                    region: region, scale: window?.backingScaleFactor ?? 2,
                                    controller: doc.markup, censors: censorSource())
            doc.markup.surface = markupView
            addSubview(markupView)
        } else {
            markupView.frame = NSRect(origin: .zero, size: region.size)
            markupView.canvas.bounds = region
            markupView.guidesLayer.bounds = region
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
            layer?.mask = cropMask()
        }
    }

    /// one CALayer per display, then window layers by z-order — Canvas coords
    private func buildBackdrop() {
        let canvas = doc.canvas
        var layers: [CALayer] = canvas.layout.map { display in
            let l = CALayer()
            l.contents = canvas.displayImages[display.id]
            l.frame = display.frame
            l.contentsGravity = .resize
            l.preferredDynamicRange = .high
            return l
        }
        for w in canvas.windowLayers.sorted(by: { $0.zOrder < $1.zOrder }) {
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

    /// the rounded-crop mask in the view's own coordinates
    private func cropMask() -> CALayer {
        let r = CGRect(x: state.crop.minX - region.minX, y: state.crop.minY - region.minY,
                       width: state.crop.width, height: state.crop.height)
        let radius = min(state.radius, doc.canvas.maxCornerRadius)
        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        mask.frame = CGRect(origin: .zero, size: region.size)
        return mask
    }

    /// Censors in an Editor sample exactly what output flattens: the same
    /// renderer over the whole Canvas, without Annotations or the crop's corner
    private func censorSource() -> CensorLayers? {
        var canvas = doc.canvas
        canvas.layerStack = LayerStack()
        canvas.cornerRadius = 0
        guard let image = try? canvas.flatten(crop: canvas.displayBounds, scale: 1) else { return nil }
        return CensorLayers(staticImage: image, coverage: canvas.displayBounds, scale: 1)
    }

    // MARK: keys — the view is the window's first responder

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { // Delete, Fn+Delete
            doc.markup.deleteSelection()
            return
        }
        if e.keyCode == 53 { // Escape
            if !doc.markup.deselect(), state.recrop {
                state.recrop = false
                rebuild()
                state.wc?.zoomToFit(nil)
            }
            return
        }
        super.keyDown(with: e)
    }

    /// ⌘ turns the armed Tool into Select until release; ⇧/⌥ reshape a
    /// Shapes draft mid-drag — the screen's flags monitor does both there
    override func flagsChanged(with e: NSEvent) {
        doc.markup.cmdHeld = e.modifierFlags.contains(.command)
        markupView.setToolCursor()
        if doc.markup.draft != nil {
            doc.markup.drag(to: markupView.canvasPoint(fromScreen: NSEvent.mouseLocation))
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
