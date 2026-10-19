import CoreGraphics
import Foundation
import Testing
import WadjetKit

struct KnifeTests {
    let red4 = AnnotationStyle(colour: RGBAColour(red: 1, green: 0, blue: 0, alpha: 1), width: 4)

    func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 1e-4) -> Bool {
        hypot(a.x - b.x, a.y - b.y) <= tol
    }
    func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    // Proves a straight Line cut becomes two Lines meeting at the crossing,
    // the tail only on the first, the head only on the second
    @Test func straightLineCut() {
        var style = red4
        style.tail = .dot; style.head = .filledArrow
        var stack = LayerStack([Annotation(
            kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)])
        let didCut = stack.cut(from: CGPoint(x: 50, y: -10), to: CGPoint(x: 50, y: 10))
        #expect(didCut)
        guard stack.annotations.count == 2,
              case let .line(s0, e0, b0) = stack.annotations[0].kind,
              case let .line(s1, e1, b1) = stack.annotations[1].kind else {
            Issue.record("expected two .line pieces, got \(stack.annotations.map(\.kind))")
            return
        }
        #expect(s0 == .zero && near(e0, CGPoint(x: 50, y: 0)) && b0 == nil)
        #expect(near(s1, CGPoint(x: 50, y: 0)) && e1 == CGPoint(x: 100, y: 0) && b1 == nil)
        #expect(stack.annotations[0].style.tail == .dot && stack.annotations[0].style.head == .none)
        #expect(stack.annotations[1].style.tail == .none && stack.annotations[1].style.head == .filledArrow)
    }

    // Proves a bent Line becomes two open paths that start/end where it did
    // and meet at the crossing — the bend's on-curve midpoint is (50,50)
    @Test func bentLineCut() {
        var stack = LayerStack([Annotation(
            kind: .line(start: .zero, end: CGPoint(x: 100, y: 0), bend: CGPoint(x: 50, y: 50)),
            style: red4)])
        let didCut = stack.cut(from: CGPoint(x: 50, y: -10), to: CGPoint(x: 50, y: 60))
        #expect(didCut)
        guard stack.annotations.count == 2,
              case let .path(d0) = stack.annotations[0].kind,
              case let .path(d1) = stack.annotations[1].kind else {
            Issue.record("expected two .path pieces, got \(stack.annotations.map(\.kind))")
            return
        }
        #expect(!d0.closed && !d1.closed)
        #expect(d0.nodes.first?.anchor == .zero
                && near(d0.nodes.last!.anchor, CGPoint(x: 50, y: 50)))
        #expect(near(d1.nodes.first!.anchor, CGPoint(x: 50, y: 50))
                && d1.nodes.last?.anchor == CGPoint(x: 100, y: 0))
    }

    // Proves an open curved Pen path cut twice splits into three open pieces
    // in path order — a smooth U whose arms a horizontal cut crosses twice
    @Test func openPathCutTwice() {
        let path = PathData(nodes: [
            PathNode(anchor: CGPoint(x: 0, y: 100), handleOut: CGPoint(x: 20, y: 60)),
            PathNode(anchor: CGPoint(x: 50, y: 0),
                     handleIn: CGPoint(x: 30, y: 0), handleOut: CGPoint(x: 70, y: 0)),
            PathNode(anchor: CGPoint(x: 100, y: 100), handleIn: CGPoint(x: 80, y: 60)),
        ])
        var stack = LayerStack([Annotation(kind: .path(path), style: red4)])
        let didCut = stack.cut(from: CGPoint(x: -10, y: 40), to: CGPoint(x: 110, y: 40))
        #expect(didCut)
        #expect(stack.annotations.count == 3)
        for a in stack.annotations {
            guard case let .path(d) = a.kind else {
                Issue.record("expected a .path piece, got \(a.kind)")
                return
            }
            #expect(!d.closed)
        }
        guard case let .path(d0) = stack.annotations[0].kind,
              case let .path(d2) = stack.annotations[2].kind else { return }
        #expect(d0.nodes.first?.anchor == CGPoint(x: 0, y: 100))
        #expect(d2.nodes.last?.anchor == CGPoint(x: 100, y: 100))
        // the middle piece is the dipped middle, its ends on the cut line
        guard case let .path(d1) = stack.annotations[1].kind else { return }
        #expect(abs(d1.nodes.first!.anchor.y - 40) < 0.01
                && abs(d1.nodes.last!.anchor.y - 40) < 0.01)
    }

    // Proves a Brush stroke's raw samples split at the crossing: piece 1's
    // samples all left of the cut plus the projected crossing point, piece
    // 2's all right of it, and both keep the fit's smoothing
    @Test func brushStrokeKeepsSplitRawSamples() {
        let raw = (0...10).map { CGPoint(x: CGFloat($0) * 10, y: 0) }
        guard let path = PathData.fitted(raw, smoothing: 0.5) else {
            Issue.record("fit failed")
            return
        }
        var stack = LayerStack([Annotation(kind: .path(path), style: red4)])
        let didCut = stack.cut(from: CGPoint(x: 50, y: -20), to: CGPoint(x: 50, y: 20))
        #expect(didCut)
        guard stack.annotations.count == 2,
              case let .path(d0) = stack.annotations[0].kind,
              case let .path(d1) = stack.annotations[1].kind,
              let r0 = d0.rawPoints, let r1 = d1.rawPoints else {
            Issue.record("expected two .path pieces with raw samples, got \(stack.annotations.map(\.kind))")
            return
        }
        #expect(d0.smoothing == 0.5 && d1.smoothing == 0.5)
        #expect(r0.dropLast().allSatisfy { $0.x <= 50 } && abs(r0.last!.x - 50) < 1)
        #expect(r1.dropFirst().allSatisfy { $0.x >= 50 } && abs(r1.first!.x - 50) < 1)
    }

    // Proves a filled rectangle cut through its middle becomes two closed
    // paths whose bounds are the left and right halves, fill kept
    @Test func rectangleCutIntoHalves() {
        var style = red4
        style.fill = RGBAColour(red: 0, green: 0, blue: 1, alpha: 1)
        var stack = LayerStack([Annotation(
            kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 0, y: 0, width: 100, height: 60)),
            style: style)])
        let didCut = stack.cut(from: CGPoint(x: 50, y: -10), to: CGPoint(x: 50, y: 70))
        #expect(didCut)
        guard stack.annotations.count == 2,
              case let .path(d0) = stack.annotations[0].kind,
              case let .path(d1) = stack.annotations[1].kind else {
            Issue.record("expected two .path pieces, got \(stack.annotations.map(\.kind))")
            return
        }
        #expect(d0.closed && d1.closed)
        // path order puts the right half first — the bottom crossing's u is lower
        let halves = stack.annotations.map(\.kind.bounds).sorted { $0.minX < $1.minX }
        #expect(near(halves[0], CGRect(x: 0, y: 0, width: 50, height: 60)))
        #expect(near(halves[1], CGRect(x: 50, y: 0, width: 50, height: 60)))
        #expect(stack.annotations[0].style.fill == style.fill)
    }

    // Proves an ellipse cut through its centre becomes two closed pieces
    // covering its halves — the outline's start-point node merges, not sticks
    @Test func ellipseCutIntoHalves() {
        var stack = LayerStack([Annotation(
            kind: .shape(.ellipse, rect: CGRect(x: 0, y: 0, width: 100, height: 60)),
            style: red4)])
        let didCut = stack.cut(from: CGPoint(x: 50, y: -10), to: CGPoint(x: 50, y: 70))
        #expect(didCut)
        guard stack.annotations.count == 2,
              case let .path(d0) = stack.annotations[0].kind,
              case let .path(d1) = stack.annotations[1].kind else {
            Issue.record("expected two .path pieces, got \(stack.annotations.map(\.kind))")
            return
        }
        #expect(d0.closed && d1.closed)
        let halves = stack.annotations.map(\.kind.bounds).sorted { $0.minX < $1.minX }
        #expect(near(halves[0], CGRect(x: 0, y: 0, width: 50, height: 60)))
        #expect(near(halves[1], CGRect(x: 50, y: 0, width: 50, height: 60)))
    }

    // Proves a cut corner to corner splits a rectangle into two closed
    // triangles — the crossing on node 0 reports once, not twice, so the
    // loop trace closes cleanly
    @Test func rectangleCutCornerToCorner() {
        var stack = LayerStack([Annotation(
            kind: .shape(.rectangle(cornerRadius: 0), rect: CGRect(x: 0, y: 0, width: 100, height: 60)),
            style: red4)])
        let didCut = stack.cut(from: CGPoint(x: -10, y: -6), to: CGPoint(x: 110, y: 66))
        #expect(didCut)
        #expect(stack.annotations.count == 2)
        for a in stack.annotations {
            guard case let .path(d) = a.kind else {
                Issue.record("expected a .path piece, got \(a.kind)")
                return
            }
            #expect(d.closed && d.nodes.count == 3)
        }
    }

    // Proves a closed U-shaped polygon cut across both arms (4 crossings)
    // traces into three closed pieces — each arm's cap and the body
    @Test func uShapeCutAcrossBothArms() {
        let u = PathData(nodes: [
            CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 80, y: 100), CGPoint(x: 80, y: 20),
            CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 100),
        ].map { PathNode(anchor: $0) }, closed: true)
        var stack = LayerStack([Annotation(kind: .path(u), style: red4)])
        let didCut = stack.cut(from: CGPoint(x: -10, y: 60), to: CGPoint(x: 110, y: 60))
        #expect(didCut)
        #expect(stack.annotations.count == 3)
        for a in stack.annotations {
            guard case let .path(d) = a.kind else {
                Issue.record("expected a .path piece, got \(a.kind)")
                return
            }
            #expect(d.closed)
        }
        // the body keeps the bottom, the caps keep one arm top each
        let tops = stack.annotations.map { $0.kind.bounds.maxY }.sorted()
        #expect(tops == [60, 100, 100])
    }

    // Proves nothing else cuts: non-geometry kinds, hidden and locked Lines,
    // a cut that stops short, one exactly through an endpoint — the stack is
    // unchanged and cut reports false
    @Test func cutsNothingElse() {
        let censor = Annotation(kind: .censor(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                            method: .blackOut), style: red4)
        let counter = Annotation(kind: .counter(center: CGPoint(x: 50, y: 50), radius: 14,
                                                value: 1, format: .numbers), style: red4)
        let magnify = Annotation(kind: .magnify(Magnifier(
            source: CGRect(x: 0, y: 0, width: 40, height: 40),
            frame: CGRect(x: 0, y: 0, width: 80, height: 80),
            options: MagnifierOptions())), style: red4)
        let locked = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                                style: red4, locked: true)
        let hidden = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                                style: red4, hidden: true)
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: red4)
        let text = Annotation(kind: .text(TextData(string: "Hello",
                                                 origin: CGPoint(x: 10, y: 80),
                                                 format: .default)), style: red4)
        let window = Annotation(kind: .window(layerID: UUID(),
                                             frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
                                style: red4)
        let image = Annotation(kind: .image(asset: UUID(),
                                            ImagePlacement(
                                                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                crop: CGRect(x: 0, y: 0, width: 100, height: 100))),
                               style: red4)
        let rows: [(Annotation, CGPoint, CGPoint)] = [
            (censor, CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50)),
            (counter, CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50)),
            (magnify, CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50)),
            (text, CGPoint(x: -10, y: 60), CGPoint(x: 110, y: 60)),
            (window, CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50)),
            (image, CGPoint(x: -10, y: 50), CGPoint(x: 110, y: 50)),
            (locked, CGPoint(x: 50, y: -10), CGPoint(x: 50, y: 10)),
            (hidden, CGPoint(x: 50, y: -10), CGPoint(x: 50, y: 10)),
            // stops short of the line at y = 0
            (line, CGPoint(x: 50, y: 5), CGPoint(x: 50, y: 10)),
            // exactly through the line's end point — a degenerate piece
            (line, CGPoint(x: 100, y: -10), CGPoint(x: 100, y: 10)),
        ]
        for (a, from, to) in rows {
            var stack = LayerStack([a])
            let didCut = stack.cut(from: from, to: to)
            #expect(!didCut)
            #expect(stack.annotations == [a])
        }
    }

    // Proves a cut that misses a closed Annotation entirely leaves it alone
    // and still splits what it does cross — a zero-crossing closed path used
    // to trap in the chord pairing
    @Test func missedClosedShapeIsNotCut() {
        let rect = Annotation(kind: .shape(.rectangle(cornerRadius: 0),
                                          rect: CGRect(x: 0, y: 0, width: 100, height: 60)),
                              style: red4)
        var lone = LayerStack([rect])
        var didCut = lone.cut(from: CGPoint(x: 200, y: 0), to: CGPoint(x: 200, y: 100))
        #expect(!didCut && lone.annotations == [rect])

        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                              style: red4)
        var stack = LayerStack([rect, line])
        didCut = stack.cut(from: CGPoint(x: 50, y: -10), to: CGPoint(x: 50, y: 10))
        #expect(didCut)
        #expect(stack.annotations.count == 3 && stack.annotations[0] == rect)
    }

    // Proves two crossings projecting onto the same raw sample segment don't
    // trap the slice, and the split keeps every original sample in order —
    // each projected boundary point ends one piece and opens the next
    @Test func rawSplitsOnSameSegmentDoNotTrap() {
        let raw = [CGPoint(x: 0, y: 0), CGPoint(x: 36, y: -1), CGPoint(x: 73, y: -27),
                   CGPoint(x: 99, y: 25), CGPoint(x: 106, y: -29)]
        guard let path = PathData.fitted(raw, smoothing: 1) else {
            Issue.record("fit failed")
            return
        }
        var stack = LayerStack([Annotation(kind: .path(path), style: red4)])
        let didCut = stack.cut(from: CGPoint(x: -10, y: 0), to: CGPoint(x: 120, y: 0))
        #expect(didCut)
        #expect(stack.annotations.count >= 2)
        var rawPieces: [[CGPoint]] = []
        for a in stack.annotations {
            guard case let .path(d) = a.kind, let r = d.rawPoints, r.count >= 2 else {
                Issue.record("expected .path pieces with ≥ 2 raw samples, got \(a.kind)")
                return
            }
            rawPieces.append(r)
        }
        // each later piece opens with the projected boundary point — drop it
        let all = rawPieces.enumerated().flatMap { i, r in
            i == 0 ? r : Array(r.dropFirst())
        }
        var idx = 0
        for p in all where idx < raw.count && p == raw[idx] { idx += 1 }
        #expect(idx == raw.count)
    }

    // Proves pieces take the original's layer position, in path order
    @Test func piecesKeepLayerPosition() {
        let x = Annotation(kind: .counter(center: CGPoint(x: -50, y: -50), radius: 5,
                                          value: 1, format: .numbers), style: red4)
        let line = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: red4)
        let y = Annotation(kind: .counter(center: CGPoint(x: 200, y: 200), radius: 5,
                                          value: 2, format: .numbers), style: red4)
        var stack = LayerStack([x, line, y])
        let didCut = stack.cut(from: CGPoint(x: 50, y: -10), to: CGPoint(x: 50, y: 10))
        #expect(didCut)
        #expect(stack.annotations.count == 4)
        #expect(stack.annotations[0].id == x.id && stack.annotations[3].id == y.id)
        #expect(stack.annotations[1].id != line.id && stack.annotations[2].id != line.id)
    }

    // Proves a rotated Line's pieces keep its rotation and sit where it drew:
    // their screen endpoints equal the original's screen start and end
    @Test func rotatedLinePiecesStayPut() {
        var original = Annotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)),
                                  style: red4)
        original.transform.rotation = .pi / 4
        // the rotated line runs at 45° through (50,0); cut across it there
        let s2 = 1 / CGFloat(2).squareRoot()
        var stack = LayerStack([original])
        let didCut = stack.cut(from: CGPoint(x: 50 + 20 * s2, y: -20 * s2),
                               to: CGPoint(x: 50 - 20 * s2, y: 20 * s2))
        #expect(didCut)
        guard stack.annotations.count == 2,
              case let .line(s0, e0, _) = stack.annotations[0].kind,
              case let .line(s1, e1, _) = stack.annotations[1].kind else {
            Issue.record("expected two .line pieces, got \(stack.annotations.map(\.kind))")
            return
        }
        #expect(abs(stack.annotations[0].transform.rotation - .pi / 4) < 1e-9)
        #expect(near(s0.applying(stack.annotations[0].affineTransform),
                     CGPoint(x: 0, y: 0).applying(original.affineTransform)))
        #expect(near(e0.applying(stack.annotations[0].affineTransform), CGPoint(x: 50, y: 0)))
        #expect(near(s1.applying(stack.annotations[1].affineTransform), CGPoint(x: 50, y: 0)))
        #expect(near(e1.applying(stack.annotations[1].affineTransform),
                     CGPoint(x: 100, y: 0).applying(original.affineTransform)))
    }
}
