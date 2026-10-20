import AppKit
import WadjetKit

/// one Markup panel per display, built like the Freeze Frame panels:
/// borderless and non-activating, but keyable so it can own the pointer's
/// cursor while a Markup Tool is armed
final class MarkupPanel: NSPanel {
    /// the Freeze Frame panels' level, one below the Markup panels' — the
    /// Annotations stay above the frozen picture and the selection dim
    /// whatever AppKit reorders (a click on a Freeze panel that isn't key
    /// brings it to the front of its level)
    static let freezeFrameLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
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
}

/// draws the Annotations that fall on its display; Annotation points are
/// global screen coords, so every panel draws its own part of each stroke
final class MarkupView: NSView {
    let canvas = CALayer()
    /// the Annotation layers, below the selection chrome; an Editor masks it to the crop
    let content = CALayer()
    /// AnnotationLayer for stroked kinds, TextAnnotationLayer for texts
    var shapeLayers: [Annotation.ID: CALayer] = [:]
    /// MarkupImageLayer for the image kinds
    var imageLayers: [Annotation.ID: MarkupImageLayer] = [:]
    /// selection chrome, kept above the annotation layers
    let frameLayer = CAShapeLayer()
    let handlesLayer = CAShapeLayer()
    /// Direct Select's chrome: the shown paths' outlines and handle stems,
    /// the handle grips, the anchors, and the marquee
    let nodeFrameLayer = CAShapeLayer()
    let nodeGripsLayer = CAShapeLayer()
    let anchorsLayer = CAShapeLayer()
    let selectedAnchorsLayer = CAShapeLayer()
    let marqueeLayer = CAShapeLayer()
    /// a multi-selection's chrome: each member's outline, the shared box and
    /// its grips, and Select's marquee — MarkupSelection.swift
    let groupLayer = CAShapeLayer()
    let groupHandlesLayer = CAShapeLayer()
    let marqueeSelectLayer = CAShapeLayer()
    /// snap guides, drawn above the Annotations and outside the peer-through mask
    let guidesLayer = CAShapeLayer()
    let accent = CGColor(srgbRed: 0.20, green: 0.84, blue: 0.58, alpha: 1)
    /// the display's backing scale; mixed-scale setups get crisp strokes on
    /// every panel because each one follows its own window
    var scale: CGFloat
    /// the Markup engine this view feeds; the panels' is the screen's shared one
    let controller: MarkupController
    /// Blur/Pixelate Censors on this panel's display — screen panels only
    let censors: CensorLayers?
    /// the Magnifies' content layers and their glass rims — screen panels
    /// only; the Editor's sampling isn't the live screen
    let magnifiers: MagnifierLayers?
    /// the annotations from the last `show`, for syncSampled
    private var shown: [Annotation] = []
    /// the last `show`'s Eraser-marked ids, re-applied by syncSampled
    private var shownDimmed: Set<Annotation.ID> = []
    /// a panel's view: screen frame for its region, its own backing scale
    convenience init(frame f: NSRect, screen: NSScreen) {
        self.init(frame: f, region: screen.frame, scale: screen.backingScaleFactor,
                  controller: .shared, censors: CensorLayers(screen: screen),
                  magnifiers: MagnifierLayers(screen: screen))
    }
    /// `region` is the global rect the view shows — canvas sublayers' bounds
    /// origin, so Annotation points (Canvas coordinates) need no offset
    init(frame f: NSRect, region: CGRect, scale: CGFloat, controller: MarkupController,
         censors: CensorLayers? = nil, magnifiers: MagnifierLayers? = nil) {
        self.scale = scale
        self.controller = controller
        self.censors = censors
        self.magnifiers = magnifiers
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
        // the magnifiers' Liquid Glass rims live in a pass-through subview
        // above the canvas layers, outside the peer-through mask
        if let container = magnifiers?.container {
            container.frame = bounds
            container.autoresizingMask = [.width, .height]
            addSubview(container)
        }
        registerForDraggedTypes([.fileURL, .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType(CanvasDocument.contentType.identifier)])
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
        for l in Array(shapeLayers.values) + Array(imageLayers.values)
            + [frameLayer, handlesLayer, guidesLayer, groupLayer, groupHandlesLayer, marqueeSelectLayer] {
            l.contentsScale = s
            l.sublayers?.forEach { $0.contentsScale = s }
        }
        for l in shapeLayers.values { (l as? TextAnnotationLayer)?.setNeedsDisplay() }
    }

    /// one layer per Annotation, keyed by id so strokes can persist and vanish
    /// without touching the rest; array order = back to front. Image kinds get
    /// a MarkupImageLayer, the rest a CAShapeLayer. `selection` draws its frame
    /// and grips on top — except while the selection is the text being edited —
    /// and while `cropping` names it, only resize grips show. `dimmed` are the
    /// Annotations an Eraser drag has marked — they draw faint until release.
    /// `group` is a multi-selection's shared box and the marquee in flight.
    func show(_ annotations: [Annotation], selection: Annotation?,
              editing: Annotation.ID? = nil, cropping: Annotation.ID? = nil,
              dimmed: Set<Annotation.ID> = [], group: SelectionChrome = SelectionChrome()) {
        shown = annotations
        shownDimmed = dimmed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for a in annotations {
            if case .text = a.kind {
                let l = (shapeLayers[a.id] as? TextAnnotationLayer) ?? TextAnnotationLayer()
                shapeLayers[a.id] = l
                l.show(a, editing: a.id == editing, scale: scale)
                // TextLayout.draw applies the style's opacity itself; the
                // layer's carries only the Eraser's dim, reset every show
                l.opacity = dimmed.contains(a.id) ? Float(MarkupEraser.dimOpacity) : 1
                continue
            }
            let l = (shapeLayers[a.id] as? AnnotationLayer) ?? AnnotationLayer()
            if a.placement != nil { // image kinds never get a shape layer
                let l = imageLayers[a.id] ?? MarkupImageLayer()
                imageLayers[a.id] = l
                // update() sets the style's opacity; the dim multiplies it
                l.update(a, source: controller.assets.source(for: a),
                         cropping: a.id == cropping, scale: scale)
                if dimmed.contains(a.id) { l.opacity *= Float(MarkupEraser.dimOpacity) }
                continue
            }
            shapeLayers[a.id] = l
            l.update(a, scale: scale,
                     windowImage: a.windowLayerID.flatMap { controller.windowLayers[$0]?.image })
            if dimmed.contains(a.id) { l.opacity *= Float(MarkupEraser.dimOpacity) }
        }
        let seen = Set(annotations.map(\.id))
        for id in shapeLayers.keys where !seen.contains(id) { shapeLayers[id] = nil }
        for id in imageLayers.keys where !seen.contains(id) { imageLayers[id] = nil }
        // Direct Select draws a pathlike selection as anchors, not grips
        let nodeChrome = controller.directSelecting ? syncNodeChrome(annotations) : []
        let selection = controller.directSelecting && selection?.kind.hasAnchors == true ? nil : selection
        if let selection, selection.id != editing {
            let frame = CGMutablePath()
            frame.addLines(between: selection.frameCorners)
            frame.closeSubpath()
            frameLayer.path = frame
            frameLayer.fillColor = nil
            frameLayer.strokeColor = accent
            frameLayer.lineWidth = 1 / controller.zoom
            frameLayer.contentsScale = scale
            let grips = CGMutablePath()
            let hs = selection.handles(controller.gripSet, minExtent: MarkupController.handleMinExtent / controller.zoom,
                                       rotateOffset: MarkupController.rotateOffset / controller.zoom)
                // recrop mode has no rotate grip
                .filter { cropping == nil || $0.handle != .rotate }
            // tangent stems ride the frame layer's accent stroke, under the
            // grips: a line from each node's anchor grip to its handle grip
            for h in hs {
                if case let .tangent(i, _) = h.handle,
                   let anchor = hs.first(where: { $0.handle == .vertex(i) }) {
                    frame.move(to: anchor.at); frame.addLine(to: h.at)
                }
            }
            for h in hs {
                // tangent grips read as satellites of their node: smaller
                let base: CGFloat = switch h.handle {
                case .tangent: 2.5
                default: MarkupController.handleSize / 2
                }
                let r = base / controller.zoom
                grips.addEllipse(in: CGRect(x: h.at.x - r, y: h.at.y - r, width: 2 * r, height: 2 * r))
            }
            frameLayer.path = frame
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
        let chrome = selection != nil && selection?.id != editing ? [frameLayer, handlesLayer] : []
        content.sublayers = annotations.compactMap { shapeLayers[$0.id] ?? imageLayers[$0.id] }
        canvas.sublayers = [content] + chrome + nodeChrome + syncGroupChrome(group)
        // text entries are TextAnnotationLayers; the samplers only write back
        // into their own AnnotationLayers
        let layers = shapeLayers.compactMapValues { $0 as? AnnotationLayer }
        censors?.sync(annotations, layers: layers)
        magnifiers?.sync(annotations, layers: layers, scale: scale, dimmed: dimmed)
        CATransaction.commit()
    }

    /// Direct Select's chrome after Illustrator: the shown paths outlined,
    /// hollow square anchors that fill once selected, round handle grips on
    /// stems, and the marquee — the layers to show above the content
    private func syncNodeChrome(_ annotations: [Annotation]) -> [CALayer] {
        let z = controller.zoom
        let chrome = controller.directChrome
        let frame = CGMutablePath(), grips = CGMutablePath()
        let hollow = CGMutablePath(), filled = CGMutablePath()
        for id in controller.nodes.shown {
            if let a = annotations.first(where: { $0.id == id }) { frame.addPath(PathGeometry.path(for: a)) }
        }
        for g in chrome.grips {
            if let stem = g.stem { frame.move(to: stem); frame.addLine(to: g.at) }
            let r = (g.handle == .cornerRadius ? 3.5 : 2.5) / z
            grips.addEllipse(in: CGRect(x: g.at.x - r, y: g.at.y - r, width: 2 * r, height: 2 * r))
        }
        let h = 3 / z
        for a in chrome.anchors {
            (a.selected ? filled : hollow).addRect(CGRect(x: a.at.x - h, y: a.at.y - h, width: 2 * h, height: 2 * h))
        }
        func style(_ l: CAShapeLayer, _ path: CGPath, fill: CGColor?) {
            l.path = path
            l.fillColor = fill
            l.strokeColor = accent
            l.lineWidth = 1 / z
            l.contentsScale = scale
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        style(nodeFrameLayer, frame, fill: nil)
        style(nodeGripsLayer, grips, fill: white)
        style(anchorsLayer, hollow, fill: white)
        style(selectedAnchorsLayer, filled, fill: accent)
        var layers: [CALayer] = [nodeFrameLayer, nodeGripsLayer, anchorsLayer, selectedAnchorsLayer]
        if let m = controller.marqueeRect {
            style(marqueeLayer, CGPath(rect: m, transform: nil), fill: nil)
            marqueeLayer.lineDashPattern = [NSNumber(value: 3 / z), NSNumber(value: 3 / z)]
            layers.append(marqueeLayer)
        }
        return layers
    }

    /// a multi-selection's chrome after Illustrator: thin outlines on every
    /// selected Annotation, one box around them with square-ish grips like a
    /// single frame's, and a dashed marquee — the layers to add above the content
    private func syncGroupChrome(_ g: SelectionChrome) -> [CALayer] {
        let z = controller.zoom
        var layers: [CALayer] = []
        if let box = g.box {
            let path = CGMutablePath()
            for o in g.outlines { path.addPath(o) }
            path.addRect(box)
            if let rotate = g.handles.first(where: { $0.handle == .rotate }) {
                // the rotate grip hangs off the top edge on a short stem
                path.move(to: CGPoint(x: box.midX, y: box.maxY)); path.addLine(to: rotate.at)
            }
            groupLayer.path = path
            groupLayer.fillColor = nil
            groupLayer.strokeColor = accent
            groupLayer.lineWidth = 1 / z
            groupLayer.contentsScale = scale
            let grips = CGMutablePath()
            let r = MarkupController.handleSize / 2 / z
            for h in g.handles {
                grips.addEllipse(in: CGRect(x: h.at.x - r, y: h.at.y - r, width: 2 * r, height: 2 * r))
            }
            groupHandlesLayer.path = grips
            groupHandlesLayer.fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            groupHandlesLayer.strokeColor = accent
            groupHandlesLayer.lineWidth = 1 / z
            groupHandlesLayer.contentsScale = scale
            groupHandlesLayer.shadowColor = .black
            groupHandlesLayer.shadowOpacity = 0.25
            groupHandlesLayer.shadowRadius = 1 / z
            groupHandlesLayer.shadowOffset = CGSize(width: 0, height: -0.5 / z)
            layers += [groupLayer, groupHandlesLayer]
        }
        if let m = g.marquee {
            marqueeSelectLayer.path = CGPath(rect: m, transform: nil)
            marqueeSelectLayer.fillColor = accent.copy(alpha: 0.08)
            marqueeSelectLayer.strokeColor = accent
            marqueeSelectLayer.lineWidth = 1 / z
            marqueeSelectLayer.lineDashPattern = [NSNumber(value: 3 / z), NSNumber(value: 3 / z)]
            marqueeSelectLayer.contentsScale = scale
            layers.append(marqueeSelectLayer)
        }
        return layers
    }

    /// a fresh sample or a lost stream: re-run the sampled layers on the last
    /// shown annotations
    func syncSampled() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layers = shapeLayers.compactMapValues { $0 as? AnnotationLayer }
        censors?.sync(shown, layers: layers)
        magnifiers?.sync(shown, layers: layers, scale: scale, dimmed: shownDimmed)
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
        controller.begin(at: canvasPoint(e), command: e.modifierFlags.contains(.command),
                         constrained: e.modifierFlags.contains(.shift),
                         clickCount: e.clickCount)
    }
    // drags keep coming to this view across displays
    override func mouseDragged(with e: NSEvent) {
        controller.drag(to: canvasPoint(e), constrained: e.modifierFlags.contains(.shift))
    }
    override func mouseUp(with e: NSEvent) { controller.end() }
    /// scroll over a selected Magnify's magnifier zooms it; anything else passes through
    override func scrollWheel(with e: NSEvent) {
        if !controller.scroll(e, at: canvasPoint(e)) { super.scrollWheel(with: e) }
    }

    // drops land only while a Markup Tool is armed — the panels ignore the
    // mouse otherwise, so nothing ever steals a drop from another app
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller.armed != nil && MarkupPasteboard.canRead(sender.draggingPasteboard)
            ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller.paste(from: sender.draggingPasteboard,
            at: canvasPoint(fromScreen: window!.convertPoint(toScreen: sender.draggingLocation)))
    }


    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    // the armed Tool's cursor while its panel owns the pointer
    override func cursorUpdate(with e: NSEvent) { setToolCursor() }
    override func mouseMoved(with e: NSEvent) {
        setToolCursor()
        controller.hover(at: canvasPoint(e))
    }
    func setToolCursor() {
        let c = controller
        if c.selecting { NSCursor.arrow.set() }
        // over the selection a placing Tool's press adjusts it or adds a node, not places
        else if let s = c.selectionCursor(at: canvasPoint(fromScreen: NSEvent.mouseLocation)) { s.set() }
        // the eraser ring is drawn at the view's zoom, not screen size
        else if c.armed == .eraser { MarkupEraser.cursor(zoom: c.zoom).set() }
        else if let t = c.armed { WadjetCursors.cursor(for: t).set() }
    }
}
