import Testing
import WadjetKit

struct CornerRadiusTests {
    // alpha[i] = coverage of pixel [i, i+1]² measured in from the corner, by a
    // quarter circle of radius r centred at (r, r); 8×8 supersampling per pixel
    private static func diagonal(radius r: Double, count: Int = 64) -> [UInt8] {
        (0..<count).map { i in
            var inside = 0
            for sx in 0..<8 {
                for sy in 0..<8 {
                    let x = Double(i) + (Double(sx) + 0.5) / 8
                    let y = Double(i) + (Double(sy) + 0.5) / 8
                    let outsideSquare = x >= r || y >= r
                    let insideArc = (x - r) * (x - r) + (y - r) * (y - r) <= r * r
                    if outsideSquare || insideArc { inside += 1 }
                }
            }
            return UInt8(inside * 255 / 64)
        }
    }

    @Test(arguments: [0, 12, 32, 52])
    func rasterisedCorner(r: Double) {
        let measured = cornerRadius(diagonalAlpha: Self.diagonal(radius: r))
        #expect(measured != nil)
        #expect(abs(measured! - r) < 0.5)
    }

    @Test func allTransparent() {
        #expect(cornerRadius(diagonalAlpha: [UInt8](repeating: 0, count: 64)) == nil)
    }
}
