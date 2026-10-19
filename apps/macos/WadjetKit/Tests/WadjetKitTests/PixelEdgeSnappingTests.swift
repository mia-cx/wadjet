import CoreGraphics
import Testing
import WadjetKit

struct PixelEdgeSnappingTests {
    // Proves boxes and Line ends use real image edges in global points at both
    // display scales, while edges beyond the user's range leave them alone.
    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func imageEdges(scale: CGFloat) {
        var bytes = [UInt8](repeating: 255, count: 40 * 40 * 4)
        for y in 8..<30 {
            for x in 12..<28 {
                for channel in 1...3 { bytes[(y * 40 + x) * 4 + channel] = 0 }
            }
        }
        bytes.withUnsafeBufferPointer { buffer in
            let pixels = PixelBuffer(base: buffer.baseAddress!, width: 40, height: 40)
            let bounds = CGRect(x: -100, y: 50, width: 40 / scale, height: 40 / scale)
            let rect = CGRect(x: -100 + 9 / scale, y: 50 + 13 / scale,
                              width: 14 / scale, height: 10 / scale)
            let range = 3 / scale
            let targets = pixels.snapTargets(rect: rect, bounds: bounds, range: range)
            let box = SnappingEngine.snap(rect: rect, targets: targets, range: range)
            #expect(box.offset == CGPoint(x: 3 / scale, y: -3 / scale))
            #expect(box.guides.count == 2)
            #expect(targets.contains { if case .x(-100 + 12 / scale, span: .some) = $0 { true } else { false } })

            let end = CGPoint(x: rect.minX, y: rect.minY)
            let endTargets = pixels.snapTargets(points: [end], bounds: bounds, range: range)
            let line = SnappingEngine.snap(points: [end], targets: endTargets, range: range)
            #expect(line.offset == CGPoint(x: 3 / scale, y: 0))
            #expect(line.guides.count == 1)
            let bottomEnd = CGPoint(x: -100 + 16 / scale, y: rect.minY)
            let bottomTargets = pixels.snapTargets(points: [bottomEnd], bounds: bounds, range: range)
            #expect(SnappingEngine.snap(points: [bottomEnd], targets: bottomTargets, range: range).offset
                == CGPoint(x: 0, y: -3 / scale))
            #expect(SnappingEngine.snap(points: [end], targets: endTargets, range: range, skip: true).guides.isEmpty)

            let outside = CGPoint(x: -100 + 8 / scale, y: 50 + 20 / scale)
            let distant = pixels.snapTargets(points: [outside], bounds: bounds, range: range)
            #expect(SnappingEngine.snap(points: [outside], targets: distant, range: range).offset == .zero)
            #expect(distant.isEmpty)

            // A bounded scan through a flat area must not invent an edge at its limit.
            let flat = CGPoint(x: -100 + 5 / scale, y: 50 + 35 / scale)
            #expect(pixels.snapTargets(points: [flat], bounds: bounds, range: range).isEmpty)
        }
    }
}
