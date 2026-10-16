import Testing
import WadjetKit

struct PixelBufferTests {
    // ASCII art -> [A,R,G,B] bytes, one row per line, A = 255
    // . white   # black   ~ soft edge grey 240 (Δ = 45)   1-4 greys 100/110/120/130
    private static func buffer(_ rows: [String], _ body: (PixelBuffer) -> Void) {
        let legend: [Character: UInt8] = [".": 255, "#": 0, "~": 240, "1": 100, "2": 110, "3": 120, "4": 130]
        let w = rows[0].count
        var bytes: [UInt8] = []
        for row in rows {
            precondition(row.count == w)
            for ch in row {
                let v = legend[ch]!
                bytes += [255, v, v, v]
            }
        }
        bytes.withUnsafeBufferPointer { body(PixelBuffer(base: $0.baseAddress!, width: w, height: rows.count)) }
    }

    private static let fixture = [
        "..........",
        "..####....",
        "..####~~..",
        "1234......",
    ]

    @Test(arguments: [
        (3, 1, PixelBuffer.Axis.horizontal, 30, 2..<6), // spans a shape's interior
        (3, 1, .vertical, 30, 1..<3),
        (4, 0, .horizontal, 30, 0..<10), // runs to both buffer edges
        (7, 0, .vertical, 30, 0..<2), // a soft edge beyond the tolerance stops the run
        (7, 0, .vertical, 45, 0..<4), // a difference equal to the tolerance still matches
        (0, 3, .horizontal, 30, 0..<2), // compares with the start pixel, so a gradient doesn't run away
    ] as [(Int, Int, PixelBuffer.Axis, Int, Range<Int>)])
    func run(x: Int, y: Int, axis: PixelBuffer.Axis, tolerance: Int, expected: Range<Int>) {
        Self.buffer(Self.fixture) { pixels in
            #expect(pixels.run(through: x, y, along: axis, tolerance: tolerance) == expected)
        }
    }
}
