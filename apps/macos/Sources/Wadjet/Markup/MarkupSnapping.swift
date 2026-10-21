import AppKit
import WadjetKit

/// one gesture's snapping: targets are gathered once at gesture start, so the
/// window list refreshes per gesture. `offset` reports the translation that
/// snaps the proposed geometry, storing the guides for render.
@MainActor struct MarkupSnapper {
    let targets: [SnapTarget]
    let range: CGFloat
    private let pixels: [MarkupPixelEdges]
    private(set) var guides: [SnapGuide] = []

    /// nil while the Snapping setting is off. Target order is the tiebreak:
    /// Annotations, then other apps' windows, then the displays. An Editor
    /// passes `canvasBounds` for its Annotations and the bounds Recrop can reach.
    /// Pixel targets are scanned
    /// lazily from the gesture's still images; the live screen supplies none.
    init?(stack: LayerStack, excluding id: Annotation.ID?, canvasBounds: CGRect? = nil,
          pixelSources: (() -> [MarkupPixelEdges])? = nil) {
        let c = AppState.shared.config.value.markup
        guard c.snapping else { return nil }
        range = c.snapRange
        pixels = pixelSources?() ?? (AppState.shared.phase == .frozen && canvasBounds == nil
            && AppDelegate.shared?.overlayCtrl.showsFrozen == true
            ? Freeze.shared.displays.map {
                let image = AppState.shared.shotWadjet ? $0.clean : $0.bareClean ?? $0.clean
                return MarkupPixelEdges(image: image, bounds: $0.screen.frame)
            } : [])
        if let canvasBounds {
            targets = SnapTarget.annotations(stack.annotations, excluding: id)
                + [.rect(canvasBounds)]
            return
        }
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
        // hidden Annotations don't draw, so they don't pull the pointer either
        targets = SnapTarget.annotations(stack.annotations.filter { !$0.hidden }, excluding: id)
            + SnapTarget.windows(infos, excludingOwner: getpid(),
                                 primaryHeight: NSScreen.screens[0].frame.height)
            + NSScreen.screens.map { .rect($0.frame) }
    }

    mutating func offset(rect: CGRect? = nil, points: [CGPoint] = []) -> CGVector {
        let r = SnappingEngine.snap(rect: rect, points: points, targets: targets + pixelTargets(rect: rect, points: points),
                                    range: range, skip: !DragModifiers.held.snaps)
        guides = r.guides
        return CGVector(dx: r.offset.x, dy: r.offset.y)
    }

    /// a grip drag through the targets; the WadjetKit function keeps the
    /// press offset and snaps only the axes the grip can move. `stretch`
    /// (⇧) frees an image kind from its aspect ratio
    mutating func dragging(_ a: Annotation, _ h: SelectionHandle, from: CGPoint, to: CGPoint,
                           stretch: Bool = false) -> Annotation {
        // the grip may be a point grip or a bounding-box one, whichever set the press took
        let grip = a.gripPosition(h, near: from, minExtent: MarkupController.handleMinExtent,
                                  rotateOffset: MarkupController.rotateOffset)
        let points = grip.map { [CGPoint(x: $0.x + to.x - from.x, y: $0.y + to.y - from.y)] } ?? []
        var rect: CGRect?
        if case .resize = h {
            let proposed = a.dragging(h, from: from, to: to, stretch: stretch,
                                      minExtent: MarkupController.handleMinExtent,
                                      rotateOffset: MarkupController.rotateOffset,
                                      targets: [], range: range, skip: true).annotation
            rect = proposed.pixelSnapBounds
        }
        let r = a.dragging(h, from: from, to: to, stretch: stretch,
                           minExtent: MarkupController.handleMinExtent,
                           rotateOffset: MarkupController.rotateOffset,
                           targets: targets + pixelTargets(rect: rect, points: points), range: range,
                           skip: !DragModifiers.held.snaps)
        guides = r.guides
        return r.annotation
    }

    private func pixelTargets(rect: CGRect? = nil, points: [CGPoint] = []) -> [SnapTarget] {
        guard DragModifiers.held.snaps else { return [] }
        return pixels.flatMap { $0.targets(rect: rect, points: points, range: range) }
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
