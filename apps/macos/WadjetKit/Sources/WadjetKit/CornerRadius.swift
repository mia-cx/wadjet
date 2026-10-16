/// The radius, in pixels, of a rounded corner, from alpha samples along its diagonal:
/// `alpha[i]` is the pixel i steps in from the corner on both axes. The corner's arc
/// crosses the diagonal at r·(1 − 1/√2). The crossing pixel's coverage inverts its
/// position within the pixel — the inside region there is ~triangular. Nil when the
/// samples are all transparent.
public func cornerRadius(diagonalAlpha alpha: [UInt8]) -> Double? {
    guard let inside = alpha.last, inside > 0 else { return nil }
    // the first fully opaque pixel; the arc crossed the diagonal one pixel earlier.
    // Already opaque at the corner pixel itself means a square corner.
    guard let i = alpha.firstIndex(where: { $0 >= inside }) else { return nil }
    guard i > 0 else { return 0 }
    let f = min(1, Double(alpha[i - 1]) / Double(inside))
    // inside region within pixel i−1 is the triangle 2(j+1−c)² when the crossing c
    // sits in its far half, or 1 − 2(c−j)² in its near half
    let c = f <= 0.5 ? Double(i) - (f / 2).squareRoot()
                     : Double(i - 1) + ((1 - f) / 2).squareRoot()
    return c / (1 - 1 / Double(2).squareRoot())
}
