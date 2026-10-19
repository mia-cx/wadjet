import AppKit
import WadjetKit

/// one Markup panel per display, built like the Freeze Frame panels:
/// borderless and non-activating, but keyable so it can own the pointer's
/// cursor while a Markup Tool is armed
final class MarkupPanel: NSPanel {
    let view: MarkupView
    init(screen: NSScreen) {
        view = MarkupView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver; hasShadow = false
        animationBehavior = .none
        isOpaque = false; backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = view
    }
    override var canBecomeKey: Bool { true }
    /// closing (hotplug, Markup emptied) stops this display's live sampler
    override func close() {
        view.censors?.stop()
        super.close()
    }
}

/// draws the Annotations that fall on its display; Annotation points are
/// global screen coords, so every panel draws its own part of each stroke
final class MarkupView: NSView {
    let canvas = CALayer()
    /// the Annotation layers, below the selection chrome; an Editor masks it to the crop
    let content = CALayer()
    var shapeLayers: [Annotation.ID: AnnotationLayer] = [:]
    /// selection chrome, kept above the annotation layers
    let frameLayer = CAShapeLayer()
    let handlesLayer = CAShapeLayer()
    /// snap guides, drawn above the Annotations and outside the peer-through mask
    let guidesLayer = CAShapeLayer()
    let accent = CGColor(srgbRed: 0.20, green: 0.84, blue: 0.58, alpha: 1)
    /// the display's backing scale; mixed-scale setups get crisp strokes on
    /// every panel because each one follows its own window
    var scale: CGFloat
    /// the Markup engine this view feeds; the panels' is the screen's shared one
    let controller: MarkupController
    /// Blur/Pixelate Censors on this panel's display
    let censors: CensorLayers?
    /// a panel's view: screen frame for its region, its own backing scale
    convenience init(frame f: NSRect, screen: NSScreen) {
        self.init(frame: f, region: screen.frame, scale: screen.backingScaleFactor,
                  controller: .shared, censors: CensorLayers(screen: screen))
    }
    /// `region` is the global rect the view shows — canvas sublayers' bounds
    /// origin, so Annotation points (Canvas coordinates) need no offset
    init(frame f: NSRect, region: CGRect, scale: CGFloat, controller: MarkupController,
         censors: CensorLayers? = nil) {
        self.scale = scale
        self.controller = controller
        self.censors = censors
        super.init(frame: f)
        wantsLayer = true
        // the bounds origin makes sublayer coordinates global screen points —
        // Annotation paths need no offset
        canvas.anchorPoint = .zero
        canvas.position = .zero
        canvas.bounds = region
        layer?.addSublayer(canvas)
        content.anchorPoint = .zero
        // inside canvas's shifted bounds space, position zero would re-apply
        // the origin — sit at the region's origin so Canvas coords land once
        content.position = region.origin
        content.bounds = region
        canvas.addSublayer(content)
        guidesLayer.anchorPoint = .zero
        guidesLayer.position = .zero
        guidesLayer.bounds = region
        guidesLayer.contentsScale = scale
        layer?.addSublayer(guidesLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    // the window moved to a display with another scale, or the display's own changed
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // scale covers magnification too — an Editor's strokes stay crisp at any zoom
        let s = (window?.backingScaleFactor ?? 2) * controller.zoom
        guard s != scale else { return }
        scale = s
        for l in Array(shapeLayers.values) + [frameLayer, handlesLayer, guidesLayer] {
            l.contentsScale = s
            l.sublayers?.forEach { $0.contentsScale = s }
        }
    }

    /// one CAShapeLayer per Annotation, keyed by id so strokes can persist
    /// and vanish without touching the rest; array order = back to front.
    /// `selection` draws its frame and grips on top.
    func show(_ annotations: [Annotation], selection: Annotation?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for a in annotations {
            let l = shapeLayers[a.id] ?? AnnotationLayer()
            shapeLayers[a.id] = l
            l.update(a, scale: scale)
        }
        let seen = Set(annotations.map(\.id))
        for id in shapeLayers.keys where !seen.contains(id) { shapeLayers[id] = nil }
        if let selection {
            let frame = CGMutablePath()
            frame.addLines(between: selection.frameCorners)
            frame.closeSubpath()
            frameLayer.path = frame
            frameLayer.fillColor = nil
            frameLayer.strokeColor = accent
            frameLayer.lineWidth = 1 / controller.zoom
            frameLayer.contentsScale = scale
            let grips = CGMutablePath()
            let r = MarkupController.handleSize / 2 / controller.zoom
            for h in selection.handles(minExtent: MarkupController.handleMinExtent / controller.zoom,
                                     rotateOffset: MarkupController.rotateOffset / controller.zoom) {
                grips.addEllipse(in: CGRect(x: h.at.x - r, y: h.at.y - r, width: 2 * r, height: 2 * r))
            }
            handlesLayer.path = grips
            handlesLayer.fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            handlesLayer.strokeColor = accent
            handlesLayer.lineWidth = 1 / controller.zoom
            handlesLayer.contentsScale = scale
            handlesLayer.shadowColor = .black
            handlesLayer.shadowOpacity = 0.25
            handlesLayer.shadowRadius = 1 / controller.zoom
            handlesLayer.shadowOffset = CGSize(width: 0, height: -0.5 / controller.zoom)
        }
        content.sublayers = annotations.compactMap { shapeLayers[$0.id] }
        canvas.sublayers = [content] + (selection == nil ? [] : [frameLayer, handlesLayer])
        censors?.sync(annotations, layers: shapeLayers)
        CATransaction.commit()
    }

    /// the event's point in Canvas (global display) coordinates — the view's
    /// point shifted by the canvas layer's bounds origin
    func canvasPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x + canvas.bounds.origin.x, y: p.y + canvas.bounds.origin.y)
    }
    /// a screen point in Canvas coordinates — for re-dragging to the pointer
    func canvasPoint(fromScreen p: CGPoint) -> CGPoint {
        guard let w = window else { return p }
        let v = convert(w.convertPoint(fromScreen: p), from: nil)
        return CGPoint(x: v.x + canvas.bounds.origin.x, y: v.y + canvas.bounds.origin.y)
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        controller.begin(at: canvasPoint(e), command: e.modifierFlags.contains(.command))
    }
    // drags keep coming to this view across displays
    override func mouseDragged(with e: NSEvent) {
        controller.drag(to: canvasPoint(e), constrained: e.modifierFlags.contains(.shift))
    }
    override func mouseUp(with e: NSEvent) { controller.end() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    // the armed Tool's cursor while its panel owns the pointer
    override func cursorUpdate(with e: NSEvent) { setToolCursor() }
    override func mouseMoved(with e: NSEvent) { setToolCursor() }
    func setToolCursor() {
        let c = controller
        if c.selecting { NSCursor.arrow.set() }
        else if let t = c.armed { WadjetCursors.cursor(for: t).set() }
    }
}
