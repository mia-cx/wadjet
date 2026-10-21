/// A borrowed view of an 8-bit premultiplied-ARGB bitmap: tightly packed rows (width × 4 bytes), top row first.
public struct PixelBuffer {
    public let width: Int, height: Int
    private let base: UnsafePointer<UInt8>

    public init(base: UnsafePointer<UInt8>, width: Int, height: Int) {
        self.base = base
        self.width = width
        self.height = height
    }

    /// The pixel at x, y (y counts down from the top row); both must be in bounds.
    public subscript(x: Int, y: Int) -> RGB8 {
        let i = (y * width + x) * 4
        return (r: base[i + 1], g: base[i + 2], b: base[i + 3]) // ARGB -> RGB
    }

    public enum Axis: Sendable { case horizontal, vertical }

    /// The run of pixels through x, y along `axis` that each differ from the pixel at x, y
    /// by at most `tolerance` (|ΔR| + |ΔG| + |ΔB|), as a half-open range of x (horizontal) or y (vertical).
    /// Measure's ruler spans this run.
    /// `maxDistance` bounds a local scan on either side of the starting pixel;
    /// a returned endpoint at that limit need not be a colour boundary.
    public func run(through x: Int, _ y: Int, along axis: Axis, tolerance: Int,
                    maxDistance: Int? = nil) -> Range<Int> {
        let c0 = self[x, y]
        func diff(_ x: Int, _ y: Int) -> Bool {
            let c = self[x, y]
            return abs(Int(c.r) - Int(c0.r)) + abs(Int(c.g) - Int(c0.g)) + abs(Int(c.b) - Int(c0.b)) > tolerance
        }
        switch axis {
        case .horizontal:
            var l = x, r = x
            while l > max(0, x - (maxDistance ?? width)) && !diff(l - 1, y) { l -= 1 }
            while r < min(width - 1, x + (maxDistance ?? width)) && !diff(r + 1, y) { r += 1 }
            return l..<(r + 1) // r is the last matching pixel, so the run ends at r + 1
        case .vertical:
            var t = y, b = y
            while t > max(0, y - (maxDistance ?? height)) && !diff(x, t - 1) { t -= 1 }
            while b < min(height - 1, y + (maxDistance ?? height)) && !diff(x, b + 1) { b += 1 }
            return t..<(b + 1)
        }
    }
}
