import CoreGraphics
import Foundation
import Testing
@testable import WadjetKit

struct AnchorDeleteTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    func path(_ xs: [CGFloat], closed: Bool = false) -> Annotation {
        Annotation(kind: .path(PathData(nodes: xs.enumerated().map {
            PathNode(anchor: CGPoint(x: $0.element, y: $0.offset.isMultiple(of: 2) ? 0 : 40)) }, closed: closed)),
                   style: red4)
    }

    func nodes(_ stack: LayerStack, _ id: Annotation.ID) -> PathData? {
        guard case let .path(d)? = stack.annotations.first(where: { $0.id == id })?.kind else { return nil }
        return d
    }

    // Proves Delete on the Draw Tool's active middle point removes only that
    // point, joins its neighbours with one segment, and hands the active
    // point to the previous one
    @Test func middlePointGoesAndThePreviousGoesActive() throws {
        let a = path([0, 50, 100, 150])
        var stack = LayerStack([a])
        let active = stack.deleteActiveAnchor(2, of: a.id)
        #expect(active == 1)
        let d = try #require(nodes(stack, a.id))
        #expect(d.nodes.map(\.anchor.x) == [0, 50, 150])
        #expect(!d.closed)
    }

    // Proves deleting the start makes the next point the new start, and active
    @Test func startPointHandsOverToTheNext() throws {
        let a = path([0, 50, 100])
        var stack = LayerStack([a])
        let active = stack.deleteActiveAnchor(0, of: a.id)
        #expect(active == 0)
        #expect(try #require(nodes(stack, a.id)).nodes.map(\.anchor.x) == [50, 100])
    }

    // Proves a closed path stays closed, and deleting its first point wraps
    // the active point back to the last
    @Test func closedPathStaysClosed() throws {
        let a = path([0, 50, 100, 150], closed: true)
        var stack = LayerStack([a])
        let active = stack.deleteActiveAnchor(0, of: a.id)
        #expect(active == 2)
        let d = try #require(nodes(stack, a.id))
        #expect(d.closed)
        #expect(d.nodes.map(\.anchor.x) == [50, 100, 150])
    }

    // Proves the joined segment keeps the neighbours' handles as they were,
    // the one that pointed at the deleted point included (Affinity)
    @Test func neighboursKeepTheirHandles() throws {
        let data = PathData(nodes: [
            PathNode(anchor: .zero, handleOut: CGPoint(x: 10, y: 20)),
            PathNode(anchor: CGPoint(x: 50, y: 40), handleIn: CGPoint(x: 40, y: 40), handleOut: CGPoint(x: 60, y: 40)),
            PathNode(anchor: CGPoint(x: 100, y: 0), handleIn: CGPoint(x: 90, y: 20)),
        ])
        let a = Annotation(kind: .path(data), style: red4)
        var stack = LayerStack([a])
        _ = stack.deleteActiveAnchor(1, of: a.id)
        let d = try #require(nodes(stack, a.id))
        #expect(d.nodes == [data.nodes[0], data.nodes[2]])
    }

    // Proves a path left with one point goes whole, and so does a Line
    // losing an end: no point stays active
    @Test func tooFewPointsDeleteTheAnnotation() {
        let a = path([0, 50])
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: red4)
        var stack = LayerStack([a, line])
        let fromPath = stack.deleteActiveAnchor(1, of: a.id)
        let fromLine = stack.deleteActiveAnchor(0, of: line.id)
        #expect(fromPath == nil && fromLine == nil)
        #expect(stack.isEmpty)
    }

    // Proves the deletion maps attachments as Direct Select's does: the
    // deleted node's own lets go, a later node's keeps its point under the
    // new index
    @Test func attachmentsFollowTheRenumbering() throws {
        let a = path([0, 50, 100, 150])
        let t1 = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 50, y: 40, width: 5, height: 5)),
                            style: red4)
        let t2 = Annotation(kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 100, y: 0, width: 5, height: 5)),
                            style: red4)
        var stack = LayerStack([t1, t2, a])
        stack.attach(a.id, .node(1), to: t1.id, at: .frame(.zero))
        stack.attach(a.id, .node(2), to: t2.id, at: .frame(.zero))
        _ = stack.deleteActiveAnchor(1, of: a.id)
        let kept = try #require(stack.annotations.first { $0.id == a.id })
        #expect(kept.attachments.map(\.point) == [.node(1)])
        #expect(kept.attachments.map(\.target) == [t2.id])
    }

    // Proves Direct Select's multi-point delete goes through the same join
    @Test func directSelectDeleteJoinsToo() throws {
        let a = path([0, 50, 100, 150, 200])
        var stack = LayerStack([a])
        let kept = stack.removeAnchors([1, 3], of: a.id)
        #expect(kept)
        #expect(try #require(nodes(stack, a.id)).nodes.map(\.anchor.x) == [0, 100, 200])
        let gone = stack.removeAnchors([0, 1], of: a.id)
        #expect(!gone)
        #expect(stack.isEmpty)
    }
}
