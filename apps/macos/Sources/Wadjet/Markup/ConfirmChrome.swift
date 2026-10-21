import AppKit
import SwiftUI

/// manual confirm's chrome — the selection outline, its 8 handles, the
/// dimensions badge and the Capture/Record button — in panels of its own one
/// level above the Markup panels, so an opaque Annotation can't hide it (#234).
/// The Freeze Frame panel still owns the selection and takes every drag: the
/// drawing panel ignores the mouse, and only the button's own small panel
/// takes clicks. One per Freeze display, owned by that display's OverlayNSView.
@MainActor
final class ConfirmChrome {
    /// above the Markup panels (.screenSaver), sharing the toolbar's level;
    /// ordered behind the toolbar, bubble and Layers window there
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    let drawing: NSPanel
    let button: NSPanel

    init(overlay: OverlayNSView, label: String, symbol: String, confirm: @escaping () -> Void) {
        let frame = overlay.window?.frame ?? .zero
        drawing = Self.panel(frame)
        drawing.ignoresMouseEvents = true
        drawing.contentView = ConfirmChromeView(frame: NSRect(origin: .zero, size: frame.size), overlay: overlay)
        button = Self.panel(.zero)
        button.acceptsMouseMovedEvents = true
        let panel = button
        let v = Button(action: confirm) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .onContinuousHover { [weak panel] ph in
            if case .active = ph, let panel { TipPanel.hover(label, anchor: panel.frame) } else { TipPanel.hide() }
        }
        let h = FirstMouseHostingView(rootView: v)
        h.frame.size = h.fittingSize
        button.setContentSize(h.fittingSize)
        button.contentView = h
        orderBelowPeers(drawing)
        orderBelowPeers(button)
    }

    static func panel(_ frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = level; p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = false; p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        return p
    }

    /// the button's origin in the overlay's view coords: just outside the
    /// selection's bottom-trailing corner, clamped into the display
    func layout(sel s: CGRect, in overlay: OverlayNSView) {
        let o = CGPoint(x: min(overlay.bounds.width - 38, s.maxX + 8), y: max(8, s.minY - 38))
        if let w = overlay.window {
            let r = w.convertToScreen(overlay.convert(NSRect(origin: o, size: button.frame.size), to: nil))
            button.setFrameOrigin(r.origin)
        }
        drawing.contentView?.needsDisplay = true
    }

    func close() {
        TipPanel.hide()
        drawing.close(); button.close()
    }

    var windowNumbers: [Int] { [drawing.windowNumber, button.windowNumber] }

    /// behind every other Wadjet window at this level — toolbar, bubble,
    /// Layers window — so the chrome stays under the toolbar and its menus
    func orderBelowPeers(_ p: NSPanel) {
        let mine = Set([drawing.windowNumber, button.windowNumber])
        let peers = Set(NSApp.windows.filter { $0.isVisible && $0.level == Self.level && !mine.contains($0.windowNumber) }
            .map(\.windowNumber))
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue) // front to back
        if let back = order.last(where: peers.contains) { p.order(.below, relativeTo: back) }
        else { p.orderFront(nil) }
    }
}

/// the button's host takes the first click: its panel is never key
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

/// draws the overlay's selection chrome in the overlay's own coordinates —
/// both panels cover the same display
final class ConfirmChromeView: NSView {
    weak var overlay: OverlayNSView?
    init(frame: NSRect, overlay: OverlayNSView) {
        self.overlay = overlay
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ r: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        overlay?.drawConfirmChrome()
    }
}
