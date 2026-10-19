import AppKit
import WadjetKit

/// one gesture's snapping: targets are gathered once at gesture start, so the
/// window list refreshes per gesture. `offset` reports the translation that
/// snaps the proposed geometry, storing the guides for render.
@MainActor struct MarkupSnapper {
    let targets: [SnapTarget]
    let range: CGFloat
    private(set) var guides: [SnapGuide] = []

    /// nil while the Snapping setting is off. Target order is the tiebreak:
    /// Annotations, then other apps' windows, then the displays.
    init?(stack: LayerStack, excluding id: Annotation.ID?) {
        let c = AppState.shared.config.value.markup
        guard c.snapping else { return nil }
        range = c.snapRange
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
        targets = SnapTarget.annotations(stack.annotations, excluding: id)
            + SnapTarget.windows(infos, excludingOwner: getpid(),
                                 primaryHeight: NSScreen.screens[0].frame.height)
            + NSScreen.screens.map { .rect($0.frame) }
    }

    mutating func offset(rect: CGRect? = nil, points: [CGPoint] = []) -> CGVector {
        let r = SnappingEngine.snap(rect: rect, points: points, targets: targets,
                                    range: range, skip: NSEvent.modifierFlags.contains(.control))
        guides = r.guides
        return CGVector(dx: r.offset.x, dy: r.offset.y)
    }

    /// a grip drag through the targets; the WadjetKit function keeps the
    /// press offset and snaps only the axes the grip can move
    mutating func dragging(_ a: Annotation, _ h: SelectionHandle, from: CGPoint, to: CGPoint) -> Annotation {
        let r = a.dragging(h, from: from, to: to,
                           minExtent: MarkupController.handleMinExtent,
                           rotateOffset: MarkupController.rotateOffset,
                           targets: targets, range: range,
                           skip: NSEvent.modifierFlags.contains(.control))
        guides = r.guides
        return r.annotation
    }
}

extension MarkupView {
    /// the snap guides — one thin malachite segment each — in global screen
    /// coords; empty clears them
    func showGuides(_ guides: [SnapGuide]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if guides.isEmpty {
            guidesLayer.path = nil
        } else {
            let p = CGMutablePath()
            for g in guides { p.move(to: g.start); p.addLine(to: g.end) }
            guidesLayer.path = p
        }
        guidesLayer.fillColor = nil
        guidesLayer.strokeColor = accent
        guidesLayer.lineWidth = 1
        guidesLayer.contentsScale = scale
        CATransaction.commit()
    }
}
