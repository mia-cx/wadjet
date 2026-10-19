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
}

/// draws the Annotations that fall on its display; Annotation points are
/// global screen coords, so every panel draws its own part of each stroke
final class MarkupView: NSView {
    let canvas = CALayer()
    var shapeLayers: [Annotation.ID: CAShapeLayer] = [:]
    /// selection chrome, kept above the annotation layers
    let frameLayer = CAShapeLayer()
    let handlesLayer = CAShapeLayer()
    let accent = CGColor(srgbRed: 0.20, green: 0.84, blue: 0.58, alpha: 1)
    let scale: CGFloat
    init(frame f: NSRect, screen: NSScreen) {
        scale = screen.backingScaleFactor
        super.init(frame: f)
        wantsLayer = true
        // the bounds origin makes sublayer coordinates global screen points —
        // Annotation paths need no offset
        canvas.anchorPoint = .zero
        canvas.position = .zero
        canvas.bounds = screen.frame
        layer?.addSublayer(canvas)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    /// one CAShapeLayer per Annotation, keyed by id so strokes can persist
    /// and vanish without touching the rest; array order = back to front.
    /// `selection` draws its frame and grips on top.
    func show(_ annotations: [Annotation], selection: Annotation?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for a in annotations {
            let l = shapeLayers[a.id] ?? CAShapeLayer()
            shapeLayers[a.id] = l
            l.path = PathGeometry.path(for: a)
            l.fillColor = nil
            let c = a.style.colour
            l.strokeColor = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
            l.lineWidth = a.style.width
            l.lineCap = .round; l.lineJoin = .round
            l.contentsScale = scale
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
            frameLayer.lineWidth = 1
            frameLayer.contentsScale = scale
            let grips = CGMutablePath()
            let r = MarkupController.handleSize / 2
            for h in selection.handles(minExtent: MarkupController.handleMinExtent,
                                     rotateOffset: MarkupController.rotateOffset) {
                grips.addEllipse(in: CGRect(x: h.at.x - r, y: h.at.y - r, width: 2 * r, height: 2 * r))
            }
            handlesLayer.path = grips
            handlesLayer.fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            handlesLayer.strokeColor = accent
            handlesLayer.lineWidth = 1
            handlesLayer.contentsScale = scale
            handlesLayer.shadowColor = .black
            handlesLayer.shadowOpacity = 0.25
            handlesLayer.shadowRadius = 1
            handlesLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        }
        canvas.sublayers = annotations.compactMap { shapeLayers[$0.id] }
            + (selection == nil ? [] : [frameLayer, handlesLayer])
        CATransaction.commit()
    }

    func screenPt(_ e: NSEvent) -> CGPoint { window!.convertPoint(toScreen: e.locationInWindow) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        MarkupController.shared.begin(at: screenPt(e), command: e.modifierFlags.contains(.command))
    }
    // drags keep coming to this view across displays
    override func mouseDragged(with e: NSEvent) { MarkupController.shared.drag(to: screenPt(e)) }
    override func mouseUp(with e: NSEvent) { MarkupController.shared.end() }

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
        let c = MarkupController.shared
        if c.selecting { NSCursor.arrow.set() }
        else if let t = c.armed { WadjetCursors.cursor(for: t).set() }
    }
}
