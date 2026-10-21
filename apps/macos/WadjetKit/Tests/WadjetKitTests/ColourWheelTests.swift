import Testing
import CoreGraphics
import WadjetKit

struct ColourWheelTests {
    @Test(arguments: [
        ((1, 0, 0), (0, 1, 0.5)), // red sector
        ((1, 1, 0), (60, 1, 0.5)), // yellow: green-max sector
        ((0.25, 0.5, 0.75), (210, 0.5, 0.5)), // blue-max sector
        ((0.5, 0.5, 1), (240, 1, 0.75)), // light tint: blue with white
        ((0.5, 0.5, 0.5), (0, 0, 0.5)), // grey has hue 0, saturation 0
    ] as [((Double, Double, Double), (Double, Double, Double))])
    // Proves RGB→HSL→RGB round trips through both directions of the conversion
    func rgbHSL(rgb: (Double, Double, Double), hsl: (Double, Double, Double)) {
        let c = RGBAColour(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        #expect(c.hsl.hue.isApproximately(hsl.0), "\(c.hsl.hue) != \(hsl.0)")
        #expect(c.hsl.saturation.isApproximately(hsl.1))
        #expect(c.hsl.lightness.isApproximately(hsl.2))
        let back = RGBAColour(hsl: HSL(hue: hsl.0, saturation: hsl.1, lightness: hsl.2))
        #expect(back.red.isApproximately(rgb.0), "\(back) != \(rgb)")
        #expect(back.green.isApproximately(rgb.1))
        #expect(back.blue.isApproximately(rgb.2))
    }

    @Test(arguments: [
        (0.0, CGPoint(x: 1, y: 0), (1, 0.5)), // the hue vertex is pure colour
        (0.0, CGPoint(x: -0.5, y: sqrt(3.0) / 2), (0, 1)), // the white vertex
        (0.0, CGPoint(x: -0.5, y: -sqrt(3.0) / 2), (0, 0)), // the black vertex
        (0.0, CGPoint(x: -0.5, y: 0), (0, 0.5)), // W–K midpoint is mid grey
        (0.0, CGPoint(x: 2, y: 0), (1, 0.5)), // outside clamps to the nearest edge point
        (120.0, CGPoint(x: -0.5, y: sqrt(3.0) / 2), (1, 0.5)), // hue 120's own vertex
    ] as [(Double, CGPoint, (Double, Double))])
    // Proves the triangle maps points to S/L in the unit space the view feeds it
    func triangle(hue: Double, point: CGPoint, expected: (Double, Double)) {
        let sl = ColourWheel.saturationLightness(at: point, hue: hue)
        #expect(sl.saturation.isApproximately(expected.0), "\(sl) != \(expected)")
        #expect(sl.lightness.isApproximately(expected.1))
    }

    @Test(arguments: [
        (0.6, 0.4, 30.0),
        (0.35, 0.7, 200.0),
    ] as [(Double, Double, Double)])
    // Proves point() and saturationLightness() invert each other inside the triangle
    func triangleRoundTrip(s: Double, l: Double, hue: Double) {
        let sl = ColourWheel.saturationLightness(at: ColourWheel.point(saturation: s, lightness: l, hue: hue), hue: hue)
        #expect(sl.saturation.isApproximately(s), "\(sl) != (\(s), \(l))")
        #expect(sl.lightness.isApproximately(l))
    }

    @Test(arguments: [
        (CGPoint(x: 0, y: 1), 90.0),
        (CGPoint(x: -1, y: 0), 180.0),
        (CGPoint(x: 0, y: -1), 270.0),
    ] as [(CGPoint, Double)])
    // Proves hue() reads angles counter-clockwise from +x, y up
    func hueRing(point: CGPoint, expected: Double) {
        #expect(ColourWheel.hue(at: point).isApproximately(expected))
    }

    // Proves hue() normalises just-under-zero into just-under-360, never 360
    @Test func hueRingWrap() {
        let h = ColourWheel.hue(at: CGPoint(x: 1, y: -1e-12))
        #expect((0..<360).contains(h))
        #expect(h > 359.999)
    }

    @Test(arguments: ["#FF3B30", "ff3b30"])
    // Proves hex parses with or without #, in any case, and writes uppercase
    func hexParses(string: String) {
        let c = RGBAColour(hex: string)
        #expect(c == RGBAColour(red: 1, green: Double(0x3B) / 255, blue: Double(0x30) / 255, alpha: 1))
        #expect(c?.hex == "#FF3B30")
    }

    @Test(arguments: ["nope", "#12345"])
    // Proves malformed hex fails rather than guessing a colour
    func hexRejects(string: String) {
        #expect(RGBAColour(hex: string) == nil)
    }
}

private extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 1e-9 }
}
