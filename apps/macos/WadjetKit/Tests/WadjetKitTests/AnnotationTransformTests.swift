import Testing
import Foundation
import WadjetKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-3 }
private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

struct AnnotationTransformTests {
    let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    // the anchor stays put; dragging past it mirrors (resize(x:1,y:0) to a negative x)
    @Test(arguments: [
        (SelectionHandle.resize(x: 1, y: 1), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 100)),
        (.resize(x: 1, y: 0), CGPoint(x: 150, y: 999), CGPoint(x: 150, y: 50)),
        (.resize(x: 1, y: 0), CGPoint(x: -100, y: 0), CGPoint(x: -100, y: 50)),
    ])
    func resize(handle: SelectionHandle, to: CGPoint, end: CGPoint) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 50)), style: style)
        let r = a.dragging(handle, from: .zero, to: to)
        guard case let .line(s, e, _) = r.kind else { Issue.record(); return }
        #expect(near(s, .zero) && near(e, end))
    }

    // the resize happens in the annotation's own space; the anchor (the line's
    // left end, displayed at (50,-50) after the pi/2 rotation) stays put
    @Test func rotatedResize() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style,
                           transform: AnnotationTransform(rotation: .pi / 2))
        let r = a.dragging(.resize(x: 1, y: 0), from: .zero, to: CGPoint(x: 50, y: 150))
        guard case let .line(s, e, _) = r.kind else { Issue.record(); return }
        #expect(near(s, CGPoint(x: -50, y: 50)) && near(e, CGPoint(x: 150, y: 50)))
        #expect(near(r.transform.rotation, .pi / 2))
    }

    @Test func rotateDrag() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let r = a.dragging(.rotate, from: CGPoint(x: 50, y: 30), to: CGPoint(x: 20, y: 0))
        #expect(near(r.transform.rotation, .pi / 2))
    }

    // a mirror across the screen's vertical axis through the centre: the
    // pi/4-tilted line ends up tilted -pi/4, ends swapped
    @Test func flipAfterRotate() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style,
                           transform: AnnotationTransform(rotation: .pi / 4))
            .flipped(horizontally: true)
        guard case let .line(s, e, _) = a.kind else { Issue.record(); return }
        let shown = [s, e].map { $0.applying(a.affineTransform) }
        let want = [CGPoint(x: 14.645, y: 35.355), CGPoint(x: 85.355, y: -35.355)]
        #expect(want.allSatisfy { w in shown.contains { near($0, w) } })
    }

    // corners first (a 0-extent axis zeroes that component, deduplicated), then
    // edge midpoints only when both extents reach minExtent, then rotate
    @Test(arguments: [
        // a zero-height line: only its end grips
        (CGPoint(x: 100, y: 0),
         [(SelectionHandle.resize(x: -1, y: 0), CGPoint(x: 0, y: 0)),
          (.resize(x: 1, y: 0), CGPoint(x: 100, y: 0)),
          (.rotate, CGPoint(x: 50, y: 20))]),
        // a short one keeps them under minExtent
        (CGPoint(x: 10, y: 0),
         [(.resize(x: -1, y: 0), CGPoint(x: 0, y: 0)),
          (.resize(x: 1, y: 0), CGPoint(x: 10, y: 0)),
          (.rotate, CGPoint(x: 5, y: 20))]),
        // an undersized diagonal keeps all 4 corners, no edge midpoints
        (CGPoint(x: 8, y: 8),
         [(.resize(x: -1, y: -1), CGPoint(x: 0, y: 0)),
          (.resize(x: -1, y: 1), CGPoint(x: 0, y: 8)),
          (.resize(x: 1, y: -1), CGPoint(x: 8, y: 0)),
          (.resize(x: 1, y: 1), CGPoint(x: 8, y: 8)),
          (.rotate, CGPoint(x: 4, y: 28))]),
        // full set: 4 corners, then the 4 edge midpoints (bottom, top, left, right)
        (CGPoint(x: 100, y: 100),
         [(.resize(x: -1, y: -1), CGPoint(x: 0, y: 0)),
          (.resize(x: -1, y: 1), CGPoint(x: 0, y: 100)),
          (.resize(x: 1, y: -1), CGPoint(x: 100, y: 0)),
          (.resize(x: 1, y: 1), CGPoint(x: 100, y: 100)),
          (.resize(x: 0, y: -1), CGPoint(x: 50, y: 0)),
          (.resize(x: 0, y: 1), CGPoint(x: 50, y: 100)),
          (.resize(x: -1, y: 0), CGPoint(x: 0, y: 50)),
          (.resize(x: 1, y: 0), CGPoint(x: 100, y: 50)),
          (.rotate, CGPoint(x: 50, y: 120))]),
    ])
    func frameHandles(end: CGPoint, expected: [(SelectionHandle, CGPoint)]) {
        let a = Annotation(kind: .line(start: .zero, end: end), style: style)
        let hs = a.frameHandles(minExtent: 12, rotateOffset: 20)
        #expect(hs.count == expected.count)
        for (h, e) in zip(hs, expected) {
            #expect(h.handle == e.0 && near(h.at, e.1))
        }
    }

    // a press resolves to the NEAREST grip, not the first in array order: on
    // (0,0)->(10,0) vertex(1)@(10,0) and bend@(5,0) crowd within radius, so a
    // press nearer the end still moves the end
    @Test(arguments: [
        (CGPoint(x: 9, y: 1), SelectionHandle.vertex(1), CGPoint(x: 9, y: 51), CGPoint(x: 10, y: 50)),
        (CGPoint(x: 5.5, y: 0.5), .bend, CGPoint(x: 5.5, y: 20.5), CGPoint(x: 10, y: 0)),
    ])
    func handlePick(press: CGPoint, handle: SelectionHandle,
                    to: CGPoint, endAfter: CGPoint) {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 0)), style: style)
        let h = a.handle(at: press, radius: 6, minExtent: 12, rotateOffset: 20)
        #expect(h == handle)
        let r = a.dragging(h!, from: press, to: to)
        guard case let .line(s, e, _) = r.kind else { Issue.record(); return }
        #expect(near(s, .zero) && near(e, endAfter))
    }

    @Test func handlePickMiss() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 5)), style: style)
        #expect(a.handle(at: CGPoint(x: 50, y: 50), radius: 6, minExtent: 12, rotateOffset: 20) == nil)
    }

    // Proves an image resize keeps its aspect ratio: a corner's larger axis wins,
    // an edge grows the passive axis symmetrically, and stretch opts out.
    @Test(arguments: [
        (SelectionHandle.resize(x: 1, y: 1), CGPoint(x: 120, y: 50), false, CGRect(x: 0, y: 0, width: 120, height: 60)),
        (.resize(x: 1, y: 1), CGPoint(x: 120, y: 50), true, CGRect(x: 0, y: 0, width: 120, height: 50)),
        (.resize(x: 1, y: 0), CGPoint(x: 120, y: 25), false, CGRect(x: 0, y: -5, width: 120, height: 60)),
    ])
    func imageResizeLocksAspect(handle: SelectionHandle, to: CGPoint, stretch: Bool, frame: CGRect) {
        let a = Annotation(kind: .image(asset: UUID(), ImagePlacement(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            crop: CGRect(x: 0, y: 0, width: 200, height: 100))), style: style)
        #expect(near(a.dragging(handle, from: .zero, to: to, stretch: stretch).placement!.frame, frame))
    }

    // Proves recrop moves the frame and crop edges together in source units and
    // clamps at the source bounds, so the kept pixels never move or mirror.
    @Test func imageRecrop() {
        let source = CGRect(x: 0, y: 0, width: 200, height: 100)
        let a = Annotation(kind: .image(asset: UUID(), ImagePlacement(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50), crop: source)), style: style)
        let trimmed = a.recropping(.resize(x: 1, y: 0), from: CGPoint(x: 100, y: 25),
                                   to: CGPoint(x: 90, y: 25), source: source)
        let p = trimmed.placement!
        #expect(near(p.frame, CGRect(x: 0, y: 0, width: 90, height: 50)))
        #expect(near(p.crop, CGRect(x: 0, y: 0, width: 180, height: 100)))
        #expect(near(p.sourceFrame(for: source), a.placement!.sourceFrame(for: source)))
        // crop (50,0,100,100) can only grow 50 source units before hitting maxX
        var inset = a
        inset.placement!.crop = CGRect(x: 50, y: 0, width: 100, height: 100)
        let clamped = inset.recropping(.resize(x: 1, y: 0), from: CGPoint(x: 100, y: 25),
                                       to: CGPoint(x: 180, y: 25), source: source)
        #expect(near(clamped.placement!.frame, CGRect(x: 0, y: 0, width: 150, height: 50)))
        #expect(near(clamped.placement!.crop, CGRect(x: 50, y: 0, width: 150, height: 100)))
    }

    // Proves a recrop on a rotated image re-pins through the moved pivot: the
    // untouched edge stays where it was on screen.
    @Test func rotatedImageRecropKeepsOppositeEdge() {
        let source = CGRect(x: 0, y: 0, width: 200, height: 100)
        let a = Annotation(kind: .image(asset: UUID(), ImagePlacement(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50), crop: source)), style: style,
            transform: AnnotationTransform(rotation: .pi / 2))
        // the right edge's grip sits on screen at (50,75); a drag to (50,55)
        // trims 20 geometry units. The untouched left edge's midpoint must
        // stay on screen at (50,-25), which re-pins the frame
        let r = a.recropping(.resize(x: 1, y: 0), from: CGPoint(x: 50, y: 75),
                             to: CGPoint(x: 50, y: 55), source: source)
        let frame = r.placement!.frame
        #expect(near(frame, CGRect(x: 10, y: -10, width: 80, height: 50)))
        #expect(near(CGPoint(x: frame.minX, y: frame.midY).applying(r.affineTransform),
                     CGPoint(x: 50, y: -25)))
    }

    // Proves a recrop moves by the pointer's delta from the press: a grip
    // pressed inside the edge and dragged only along the passive axis leaves
    // frame and crop untouched — rotated or not.
    @Test(arguments: [0.0, .pi / 2])
    func recropOffGripPressDoesNotJump(rotation: Double) {
        let source = CGRect(x: 0, y: 0, width: 200, height: 100)
        var a = Annotation(kind: .image(asset: UUID(), ImagePlacement(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50), crop: source)), style: style,
            transform: AnnotationTransform(rotation: rotation))
        // the right edge's grip is at geometry (100,25); the press sits 3pt
        // inside it, at (97,25) — on screen the passive axis is perpendicular
        let press = CGPoint(x: 97, y: 25).applying(a.affineTransform)
        // drag only along the passive axis: screen y unrotated, screen x rotated
        let to = rotation == 0 ? CGPoint(x: press.x, y: press.y + 35)
                               : CGPoint(x: press.x + 35, y: press.y)
        a = a.recropping(.resize(x: 1, y: 0), from: press, to: to, source: source)
        #expect(near(a.placement!.frame, CGRect(x: 0, y: 0, width: 100, height: 50)))
        #expect(near(a.placement!.crop, source))
    }

    // Proves a colour pick turns an image's border on even when the stored
    // colour is unchanged, while restyles without the flag leave it alone.
    @Test(arguments: [
        (true, ImageBorder.colour),   // picking the same colour still enables it
        (false, ImageBorder.hidden),  // an opacity-only restyle keeps .hidden
    ])
    func colourPickedTurnsBorderOn(colourPicked: Bool, border: ImageBorder) {
        let a = Annotation(kind: .image(asset: UUID(), ImagePlacement(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            crop: CGRect(x: 0, y: 0, width: 200, height: 100), border: .hidden)), style: style)
        var sameColour = style
        sameColour.opacity = 0.5 // the colour itself doesn't change
        #expect(a.restyled(sameColour, colourPicked: colourPicked).placement!.border == border)
    }

    // Proves panning slides the crop against the pointer and clamps at the
    // source bounds while the frame stays put.
    @Test func imagePan() {
        let a = Annotation(kind: .image(asset: UUID(), ImagePlacement(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            crop: CGRect(x: 50, y: 0, width: 100, height: 100))), style: style)
        let source = CGRect(x: 0, y: 0, width: 200, height: 100)
        let r = a.panning(from: .zero, to: CGPoint(x: 10, y: 5), source: source)
        #expect(near(r.placement!.frame, a.placement!.frame))
        #expect(near(r.placement!.crop, CGRect(x: 40, y: 0, width: 100, height: 100)))
        let clamped = r.panning(from: .zero, to: CGPoint(x: -100, y: 0), source: source)
        #expect(near(clamped.placement!.crop, CGRect(x: 100, y: 0, width: 100, height: 100)))
    }

    // Proves dragging a censor's grip past its anchor re-standardizes the rect —
    // a negative scale can't leave a mirrored CGRect with negative extents
    @Test func censorResizePastAnchorStaysStandardized() {
        let a = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 100, height: 50),
                                         method: .blackOut), style: style)
        let r = a.dragging(.resize(x: 1, y: 1), from: .zero, to: CGPoint(x: -40, y: -20))
        guard case let .censor(rect, method) = r.kind else { Issue.record(); return }
        #expect(method == .blackOut)
        #expect(rect.width >= 0 && rect.height >= 0)
        #expect(near(rect, CGRect(x: -40, y: -20, width: 40, height: 20)))
    }

    // a Line's grips: one per end, one on the curve (the bend itself, or the
    // chord midpoint when straight), then rotate above the frame
    @Test func lineHandles() {
        let straight = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let hs = straight.handles(minExtent: 12, rotateOffset: 20)
        #expect(hs.map(\.handle) == [.vertex(0), .vertex(1), .bend, .rotate])
        for (h, e) in zip(hs, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                               CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 20)]) {
            #expect(near(h.at, e))
        }
        let bent = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0),
                                        bend: CGPoint(x: 50, y: 40)), style: style)
        #expect(near(bent.handles(minExtent: 12, rotateOffset: 20)[2].at, CGPoint(x: 50, y: 40)))
    }

    // dragging a vertex moves only that end; the press needn't land dead-on —
    // the new position is the grip's start position plus the drag
    @Test func vertexDrag() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let r = a.dragging(.vertex(1), from: CGPoint(x: 98, y: 2), to: CGPoint(x: 98, y: 52))
        guard case let .line(s, e, b) = r.kind else { Issue.record(); return }
        #expect(near(s, .zero) && near(e, CGPoint(x: 100, y: 50)) && b == nil)
    }

    // Shift snaps the moved end to a 45° ray from the other end: (100,80) is
    // 38.7° off horizontal, so the end lands on the diagonal, x kept
    @Test func constrainedVertexDrag() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let r = a.dragging(.vertex(1), from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 80),
                           constrained: true)
        guard case let .line(s, e, _) = r.kind else { Issue.record(); return }
        #expect(near(s, .zero) && near(e, CGPoint(x: 90, y: 90)))
    }

    // the bend grip sets the on-curve point: the drawn path passes through it
    // while the old chord is left behind
    @Test func bendDrag() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let r = a.dragging(.bend, from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 40))
        guard case let .line(_, _, b) = r.kind else { Issue.record(); return }
        #expect(b == CGPoint(x: 50, y: 40))
        #expect(PathGeometry.hitTest(r, at: CGPoint(x: 50, y: 40)))
        #expect(!PathGeometry.hitTest(r, at: CGPoint(x: 50, y: 0)))
    }

    // dragged back to within bendStraightenRadius of the chord midpoint the
    // curve straightens
    @Test func bendStraighten() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0),
                                     bend: CGPoint(x: 50, y: 40)), style: style)
        let r = a.dragging(.bend, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 50, y: 2))
        guard case let .line(_, _, b) = r.kind else { Issue.record(); return }
        #expect(b == nil)
    }

    // the bend keeps its place relative to the chord: (50,50) on (0,0)->(100,0)
    // is z = 0.5+0.5i along it; on (0,0)->(100,100) that lands at (0,100)
    @Test func vertexDragKeepsBendOnChord() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0),
                                     bend: CGPoint(x: 50, y: 50)), style: style)
        let r = a.dragging(.vertex(1), from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 100))
        guard case let .line(_, e, b) = r.kind else { Issue.record(); return }
        #expect(near(e, CGPoint(x: 100, y: 100)) && near(b!, CGPoint(x: 0, y: 100)))
    }

    // a rotated Line's vertex drag bakes the transform into the points: the
    // end displayed at (50,50) (rotation pi/2 about (50,0)) moves, the other
    // displayed end stays put
    @Test func vertexDragBakesTransform() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style,
                           transform: AnnotationTransform(rotation: .pi / 2))
        let r = a.dragging(.vertex(1), from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 100))
        guard case let .line(s, e, _) = r.kind else { Issue.record(); return }
        #expect(r.transform == .identity)
        #expect(near(s, CGPoint(x: 50, y: -50)) && near(e, CGPoint(x: 50, y: 100)))
    }

    // a path's grips: one per anchor, then a tangent grip per non-nil handle
    // off its anchor, then rotate — no frame resize grips
    @Test func pathHandles() {
        let a = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 80, y: -20),
                     handleOut: CGPoint(x: 120, y: 20)),
            PathNode(anchor: CGPoint(x: 200, y: 0)),
        ])), style: style)
        let hs = a.handles(minExtent: 12, rotateOffset: 20)
        #expect(hs.map(\.handle) == [.vertex(0), .vertex(1), .vertex(2),
                                     .tangent(1, outgoing: true), .tangent(1, outgoing: false), .rotate])
        #expect(near(hs[3].at, CGPoint(x: 120, y: 20)) && near(hs[4].at, CGPoint(x: 80, y: -20)))
    }

    // a vertex drag moves the anchor and rides both its handles along
    @Test func pathVertexDrag() {
        let a = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 80, y: -20),
                     handleOut: CGPoint(x: 120, y: 20)),
        ])), style: style)
        let r = a.dragging(.vertex(1), from: CGPoint(x: 100, y: 0), to: CGPoint(x: 150, y: 40))
        guard case let .path(d) = r.kind else { Issue.record(); return }
        #expect(near(d.nodes[1].anchor, CGPoint(x: 150, y: 40)))
        #expect(near(d.nodes[1].handleIn!, CGPoint(x: 130, y: 20)))
        #expect(near(d.nodes[1].handleOut!, CGPoint(x: 170, y: 60)))
    }

    // a tangent drag turns the opposite handle to stay collinear through the
    // anchor at its own length — the node stays smooth
    @Test func tangentDragStaysCollinear() {
        let a = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 80, y: -10),
                     handleOut: CGPoint(x: 120, y: 10)),
        ])), style: style)
        let r = a.dragging(.tangent(1, outgoing: true), from: CGPoint(x: 120, y: 10),
                           to: CGPoint(x: 100, y: 40))
        guard case let .path(d) = r.kind else { Issue.record(); return }
        let n = d.nodes[1]
        #expect(near(n.handleOut!, CGPoint(x: 100, y: 40)))
        // handleIn: opposite direction through the anchor, still 22.36 long
        #expect(near(n.handleIn!, CGPoint(x: 100, y: -22.3607)))
        #expect(near(hypot(n.handleIn!.x - n.anchor.x, n.handleIn!.y - n.anchor.y),
                     hypot(20, 10)))
    }

    // with no opposite handle the tangent drag changes only its own side
    @Test func tangentDragNilOpposite() {
        let a = Annotation(kind: .path(PathData(nodes: [
            PathNode(anchor: .zero),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleOut: CGPoint(x: 120, y: 10)),
        ])), style: style)
        let r = a.dragging(.tangent(1, outgoing: true), from: CGPoint(x: 120, y: 10),
                           to: CGPoint(x: 100, y: 40))
        guard case let .path(d) = r.kind else { Issue.record(); return }
        #expect(near(d.nodes[1].handleOut!, CGPoint(x: 100, y: 40)))
        #expect(d.nodes[1].handleIn == nil)
    }
}

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    near(a.origin, b.origin) && near(a.width, b.width) && near(a.height, b.height)
}
