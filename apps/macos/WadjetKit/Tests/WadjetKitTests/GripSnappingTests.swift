import CoreGraphics
import Testing
import WadjetKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-3 }
private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { near(a.x, b.x) && near(a.y, b.y) }

struct GripSnappingTests {
    static let minExtent: CGFloat = 12
    static let rotateOffset: CGFloat = 20
    let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    func drag(_ a: Annotation, _ h: SelectionHandle, from: CGPoint, to: CGPoint,
              targets: [SnapTarget]) -> (annotation: Annotation, guides: [SnapGuide]) {
        a.dragging(h, from: from, to: to, minExtent: Self.minExtent, rotateOffset: Self.rotateOffset,
                   targets: targets, range: 6, skip: false)
    }

    /// the dragged grip's screen position in the result
    func grip(of a: Annotation, _ h: SelectionHandle, nearest p: CGPoint) -> CGPoint? {
        a.handles(minExtent: Self.minExtent, rotateOffset: Self.rotateOffset)
            .filter { $0.handle == h }
            .min { hypot($0.at.x - p.x, $0.at.y - p.y) < hypot($1.at.x - p.x, $1.at.y - p.y) }?.at
    }

    // the press was 3 pt off the grip, so the delta — not the pointer — snaps
    @Test func offCentreCornerPressLandsOnTheGuides() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 100)), style: style)
        let h = SelectionHandle.resize(x: 1, y: 1)
        let r = drag(a, h, from: CGPoint(x: 103, y: 103), to: CGPoint(x: 111, y: 111),
                     targets: [.rect(CGRect(x: 110, y: 110, width: 100, height: 100))])
        #expect(near(grip(of: r.annotation, h, nearest: CGPoint(x: 110, y: 110)) ?? .zero,
                     CGPoint(x: 110, y: 110)))
        #expect(r.guides.count == 2)
        #expect(r.guides.contains { near($0.start.x, 110) && near($0.end.x, 110) })
        #expect(r.guides.contains { near($0.start.y, 110) && near($0.end.y, 110) })
    }

    // a horizontal Line's end grip moves along x only — the y target gets no guide
    @Test func horizontalEndGripSnapsXOnly() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)
        let h = SelectionHandle.resize(x: 1, y: 0)
        let r = drag(a, h, from: CGPoint(x: 100, y: 0), to: CGPoint(x: 104, y: 3),
                     targets: [.rect(CGRect(x: 106, y: 5, width: 100, height: 100))])
        #expect(near(grip(of: r.annotation, h, nearest: CGPoint(x: 106, y: 0)) ?? .zero,
                     CGPoint(x: 106, y: 0)))
        #expect(r.guides.count == 1)
        #expect(near(r.guides[0].start.x, 106) && near(r.guides[0].end.x, 106))
    }

    // rotated a right angle, the side grip's local x is the screen's y
    @Test func rightAngleRotationSwapsTheFreeAxis() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style,
                           transform: AnnotationTransform(rotation: .pi / 2))
        let h = SelectionHandle.resize(x: 1, y: 0)
        let r = drag(a, h, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 53, y: 54),
                     targets: [.rect(CGRect(x: 55, y: 57, width: 10, height: 10))])
        #expect(near(grip(of: r.annotation, h, nearest: CGPoint(x: 50, y: 57)) ?? .zero,
                     CGPoint(x: 50, y: 57)))
        #expect(r.guides.count == 1)
        #expect(near(r.guides[0].start.y, 57) && near(r.guides[0].end.y, 57))
    }

    // at other angles a side grip's axis maps to no screen axis: no snapping
    @Test func otherRotationsDontSnapSideGrips() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style,
                           transform: AnnotationTransform(rotation: .pi / 4))
        let h = SelectionHandle.resize(x: 1, y: 0)
        let from = grip(of: a, h, nearest: CGPoint(x: 100, y: 0))!
        let to = CGPoint(x: from.x + 3, y: from.y + 3)
        let r = drag(a, h, from: from, to: to,
                     targets: [.rect(CGRect(x: to.x + 1, y: to.y + 1, width: 10, height: 10))])
        #expect(r.annotation.kind == a.dragging(h, from: from, to: to).kind)
        #expect(r.guides.isEmpty)
    }
}
