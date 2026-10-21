import AppKit
import WadjetKit

/// While nothing is armed, a feathered circle under the pointer masks the
/// Annotations so what's beneath shows through — soft like the webcam edge
/// light. `sync` runs whenever the want can change (phase/tool/stack/config);
/// while wanted it follows the pointer with global and local mouse monitors.
@MainActor
final class PeerThrough {
    static let shared = PeerThrough()
    static let diameter: CGFloat = 60

    private var globalMon: Any?
    private var localMon: Any?

    /// the want: the setting on, Annotations on screen, no Tool armed —
    /// the panels ignore the mouse then, so pointer events go to other apps
    var wanted: Bool {
        let s = AppState.shared
        return s.config.value.markup.peerThrough
            && !(s.toolbarOpen && s.tool != nil)
            && !MarkupController.shared.stack.isEmpty
    }

    func sync() {
        if wanted, globalMon == nil {
            globalMon = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            localMon = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
                MainActor.assumeIsolated { self?.update() }
                return e
            }
        } else if !wanted {
            if let m = globalMon { NSEvent.removeMonitor(m); globalMon = nil }
            if let m = localMon { NSEvent.removeMonitor(m); localMon = nil }
        }
        update()
    }

    func update() {
        let p = NSEvent.mouseLocation
        let shown = wanted && MarkupController.shared.stack.topmost(at: p, tolerance: MarkupController.hitTolerance) != nil
        MarkupController.shared.showPeer(at: shown ? p : nil)
    }
}

/// the mask on a MarkupView's canvas: an opaque border covering its whole
/// display (drawn by Core Animation, no backing store), a feathered clear hole
/// in the middle tile, and `cover`, an opaque square over the hole whose
/// opacity drives the fade — 1 = no hole, 0 = full hole
final class PeerMask: CALayer {
    let cover = CALayer()
    init(diameter d: CGFloat, display size: CGSize, scale: CGFloat) {
        super.init()
        let b = hypot(size.width, size.height) + d
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        bounds = CGRect(x: 0, y: 0, width: d + 2 * b, height: d + 2 * b)
        borderWidth = b
        borderColor = CGColor(gray: 0, alpha: 1)
        contents = PeerMask.tile(diameter: d, scale: scale)
        contentsGravity = .center
        contentsScale = scale
        cover.frame = CGRect(x: b, y: b, width: d, height: d)
        cover.backgroundColor = CGColor(gray: 0, alpha: 1)
        addSublayer(cover)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// centre the hole at p, in the canvas's global screen coords
    func move(to p: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = p
        CATransaction.commit()
    }

    /// a black tile with a feathered transparent hole: clear to ~30% of the
    /// radius, then a smoothstep ramp to opaque at the radius; the corners are
    /// opaque via `.drawsAfterEndLocation`
    static func tile(diameter d: CGFloat, scale: CGFloat) -> CGImage {
        let px = Int((d * scale).rounded(.up))
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                            bytesPerRow: px * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rgba: [CGFloat] = []
        var locs: [CGFloat] = []
        let inner: CGFloat = 0.3 // clear fraction of the radius
        for i in 0...8 {
            let t = CGFloat(i) / 8
            let u = min(max((t - inner) / (1 - inner), 0), 1)
            let a = u * u * (3 - 2 * u) // smoothstep
            rgba += [0, 0, 0, a]
            locs.append(t)
        }
        let g = CGGradient(colorSpace: CGColorSpaceCreateDeviceRGB(), colorComponents: rgba, locations: locs, count: locs.count)!
        let c = CGPoint(x: px / 2, y: px / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                               endRadius: d * scale / 2, options: .drawsAfterEndLocation)
        return ctx.makeImage()!
    }
}

extension MarkupView {
    /// show the peer hole at p (a global screen point) on this panel, or fade
    /// it out on nil. Points beyond the circle's reach are treated as nil so
    /// the mask never moves out of reach of its own display.
    func peer(at point: CGPoint?) {
        let d = PeerThrough.diameter
        var p = point
        if let q = p, !canvas.bounds.insetBy(dx: -d / 2, dy: -d / 2).contains(q) { p = nil }
        if let p {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let m = canvas.mask as? PeerMask ?? PeerMask(diameter: d, display: canvas.bounds.size, scale: scale)
            if canvas.mask !== m { canvas.mask = m }
            m.move(to: p)
            CATransaction.commit()
            // re-setting the same opacity would restart the fade from its end value
            guard m.cover.opacity != 0 else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            m.cover.opacity = 0
            CATransaction.commit()
        } else {
            guard let m = canvas.mask as? PeerMask, m.cover.opacity != 1 else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            // a panel without the circle pays no offscreen mask pass
            CATransaction.setCompletionBlock { [weak self, weak m] in
                MainActor.assumeIsolated {
                    if let m, m.cover.opacity == 1, self?.canvas.mask === m { self?.canvas.mask = nil }
                }
            }
            m.cover.opacity = 1
            CATransaction.commit()
        }
    }
}
