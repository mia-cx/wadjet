import CoreGraphics
import Foundation
import Testing
@testable import WadjetKit

struct DrawGripsTests {
    static let style = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    static func grips(_ a: Annotation) -> [SelectionHandle] {
        a.handles(.drawing, minExtent: 12, rotateOffset: 20).map(\.handle)
    }

    static func hit(_ a: Annotation, _ p: CGPoint) -> SelectionHandle? {
        a.handle(at: p, radius: 6, minExtent: 12, rotateOffset: 20, set: .drawing)
    }

    // Proves a node the Draw Tool inserts shows as a grip afterwards and drags
    // on its own: a Line split at its middle has three anchors, and the
    // middle one moves without the ends
    @Test func insertedNodeShowsAndDrags() throws {
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: Self.style)
        let (path, i) = try #require(line.insertingNode(near: CGPoint(x: 50, y: 0)))
        #expect(Self.grips(path).filter { if case .vertex = $0 { true } else { false } }
            == [.vertex(0), .vertex(1), .vertex(2)])
        #expect(Self.hit(path, CGPoint(x: 51, y: 1)) == .vertex(i))
        let moved = path.dragging(.vertex(i), from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 30))
        let want = [CGPoint.zero, CGPoint(x: 50, y: 30), CGPoint(x: 100, y: 0)]
        let got = moved.anchorGrips.map(\.at)
        #expect(got.count == 3)
        #expect(zip(got, want).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 })
    }

    // Proves a Brush stroke under the Draw Tool shows its fitted nodes as
    // anchors, not its raw samples, and that dragging one drops the samples
    // so a later Smoothing change can't refit the edit away
    @Test func brushShowsFittedNodesAndAnEditDropsTheSamples() throws {
        let raw = (0...40).map { CGPoint(x: CGFloat($0) * 5, y: 20 * sin(CGFloat($0) / 6)) }
        let data = try #require(PathData.fitted(raw, smoothing: 0.5))
        let brush = Annotation(kind: .path(data), style: Self.style)
        let anchors = brush.anchorGrips
        #expect(anchors.count == data.nodes.count)
        #expect(anchors.count < raw.count)
        let last = try #require(anchors.last)
        let moved = brush.dragging(last.handle, from: last.at, to: CGPoint(x: last.at.x + 10, y: last.at.y))
        guard case let .path(d) = moved.kind else { Issue.record(); return }
        #expect(d.rawPoints == nil)
        #expect(d.smoothing == nil)
    }

    // Proves a Line under the Draw Tool keeps its bend grip and gets its two
    // ends as anchors, with no frame grip stacked on either end
    @Test func lineKeepsBendAndShowsItsEnds() {
        let a = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 40)), style: Self.style)
        let hs = a.handles(.drawing, minExtent: 12, rotateOffset: 20)
        #expect(Array(hs.map(\.handle).prefix(3)) == [.bend, .vertex(0), .vertex(1)])
        #expect(!hs.contains { $0.handle.isFrame && ($0.at == .zero || $0.at == CGPoint(x: 100, y: 40)) })
        #expect(hs.contains { $0.handle == .resize(x: 1, y: -1) })
        #expect(Self.hit(a, CGPoint(x: 50, y: 20)) == .bend)
    }

    // Proves an anchor in reach wins over a frame grip even when the frame
    // grip sits nearer the press: the path's first node is 4 pt from the
    // press, its frame's corner 2 pt
    @Test func anAnchorInReachBeatsANearerFrameGrip() {
        let data = PathData(nodes: [PathNode(anchor: CGPoint(x: 4, y: 0)),
                                    PathNode(anchor: CGPoint(x: 100, y: 50)),
                                    PathNode(anchor: CGPoint(x: 0, y: 100))])
        let a = Annotation(kind: .path(data), style: Self.style)
        #expect(Self.hit(a, CGPoint(x: 0, y: 2)) == .vertex(0))
        // the placing Tools' set still picks the nearest
        #expect(a.handle(at: CGPoint(x: 0, y: 2), radius: 6, minExtent: 12, rotateOffset: 20, set: .placed)
            == .resize(x: -1, y: -1))
        // away from every anchor the frame still resizes
        #expect(Self.hit(a, CGPoint(x: 100, y: 100)) == .resize(x: 1, y: 1))
    }

    // Proves kinds without anchors get exactly the placing Tools' grips
    @Test func otherKindsKeepThePlacedGrips() {
        let a = Annotation(kind: .shape(.ellipse, rect: CGRect(x: 0, y: 0, width: 80, height: 40)), style: Self.style)
        #expect(Self.grips(a) == a.handles(.placed, minExtent: 12, rotateOffset: 20).map(\.handle))
    }

    // Proves a fresh Brush stroke's anchor snaps on its first drag: the
    // anchor shows only under the Draw Tool's set, and the snapping lookup
    // finds it there, keeping the press offset
    @Test func freshBrushAnchorSnaps() throws {
        let raw = (0...20).map { CGPoint(x: CGFloat($0) * 5, y: 0) }
        let data = try #require(PathData.fitted(raw, smoothing: 0.5))
        let brush = Annotation(kind: .path(data), style: Self.style)
        let last = data.nodes.count - 1
        #expect(brush.anchorGrips[last].at == CGPoint(x: 100, y: 0))
        let r = brush.dragging(.vertex(last), from: CGPoint(x: 103, y: 3), to: CGPoint(x: 107, y: 6),
                               minExtent: 12, rotateOffset: 20,
                               targets: [.x(106), .y(5)], range: 6, skip: false)
        let moved = try #require(r.annotation.anchorGrips.last?.at)
        #expect(hypot(moved.x - 106, moved.y - 5) < 1e-6)
        #expect(r.guides.count == 2)
    }
}
