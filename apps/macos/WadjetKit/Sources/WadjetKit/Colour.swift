import Foundation

/// One 8-bit sRGB pixel, as read off a Freeze Frame.
public typealias RGB8 = (r: UInt8, g: UInt8, b: UInt8)

/// How Pick colour writes a colour. The raw value is the label the app shows and stores.
public enum ColourFormat: String, CaseIterable, Codable, Sendable {
    case hex = "Hex", rgb = "rgb()", hsl = "hsl()", oklch = "oklch()", lab = "lab()", swiftUI = "SwiftUI"

    /// `c` written in this format, e.g. `#33D694` or `oklch(0.779 0.162 160.6)`.
    public func format(_ c: RGB8) -> String {
        switch self {
        case .hex: return Self.hexString(c)
        case .rgb: return Self.fmtRGB(c)
        case .hsl: return Self.fmtHSL(c)
        case .oklch: return Self.fmtOKLCH(c)
        case .lab: return Self.fmtLAB(c)
        case .swiftUI: return Self.fmtSwiftUI(c)
        }
    }

    private static func hexString(_ c: RGB8) -> String { String(format: "#%02X%02X%02X", c.r, c.g, c.b) }
    private static func srgbLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    // CSS Color 4 breakdowns of one sRGB pixel
    private static func fmtRGB(_ c: RGB8) -> String { "rgb(\(c.r) \(c.g) \(c.b))" }
    private static func fmtHSL(_ c: RGB8) -> String {
        let hsl = RGBAColour(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1).hsl
        return String(format: "hsl(%.0f %.0f%% %.0f%%)", hsl.hue, hsl.saturation * 100, hsl.lightness * 100)
    }
    // OKLab (Ottosson) from linear sRGB
    private static func fmtOKLCH(_ c: RGB8) -> String {
        let r = srgbLinear(Double(c.r) / 255), g = srgbLinear(Double(c.g) / 255), b = srgbLinear(Double(c.b) / 255)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let C = sqrt(a * a + bb * bb)
        // below this a grey's "chroma" is float noise and atan2 reports a junk hue;
        // CSS calls such a hue powerless and it prints as 0
        let powerlessChroma = 1e-6
        var h = C < powerlessChroma ? 0 : atan2(bb, a) * 180 / .pi; if h < 0 { h += 360 }
        return String(format: "oklch(%.3f %.3f %.1f)", L, C, h)
    }
    // CIELAB D50 (CSS lab()) via linear sRGB -> XYZ D65 -> Bradford D50
    private static func fmtLAB(_ c: RGB8) -> String {
        let r = srgbLinear(Double(c.r) / 255), g = srgbLinear(Double(c.g) / 255), b = srgbLinear(Double(c.b) / 255)
        let x65 = 506752.0 / 1228815 * r + 87881.0 / 245763 * g + 12673.0 / 70218 * b
        let y65 = 87098.0 / 409605 * r + 175762.0 / 245763 * g + 12673.0 / 175545 * b
        let z65 = 7918.0 / 409605 * r + 87881.0 / 737289 * g + 1001167.0 / 1053270 * b
        let X = 1.0479297925449969 * x65 + 0.022946870601609652 * y65 - 0.05019226628920524 * z65 // Bradford D65->D50
        let Y = 0.02962780877005599 * x65 + 0.9904344267538799 * y65 - 0.017073799063418826 * z65
        let Z = -0.009243040646204504 * x65 + 0.015055191490298152 * y65 + 0.7518742814281371 * z65
        let e = 216.0 / 24389, k = 24389.0 / 27
        func f(_ t: Double) -> Double { t > e ? cbrt(t) : (k * t + 16) / 116 }
        let fx = f(X / (0.3457 / 0.3585)), fy = f(Y), fz = f(Z / ((1 - 0.3457 - 0.3585) / 0.3585)) // D50 white
        // half the last printed digit: a grey's a/b float noise would otherwise print -0.00
        func clean(_ v: Double) -> Double { abs(v) < 0.005 ? 0 : v }
        return String(format: "lab(%.2f %.2f %.2f)", 116 * fy - 16, clean(500 * (fx - fy)), clean(200 * (fy - fz)))
    }
    private static func fmtSwiftUI(_ c: RGB8) -> String {
        String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", Double(c.r) / 255, Double(c.g) / 255, Double(c.b) / 255)
    }
}

/// CSS HSL: hue in degrees 0..<360, saturation and lightness 0…1. Greys have
/// hue 0 and saturation 0.
public struct HSL: Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var lightness: Double
    public init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }
}

extension RGBAColour {
    public init(hsl: HSL, alpha: Double = 1) {
        var h = hsl.hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let c = (1 - abs(2 * hsl.lightness - 1)) * hsl.saturation
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch Int(h / 60) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = hsl.lightness - c / 2
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }
    /// the colour as CSS HSL; greys report hue 0, saturation 0
    public var hsl: HSL {
        let mx = max(red, green, blue), mn = min(red, green, blue)
        var h = 0.0, s = 0.0
        let l = (mx + mn) / 2
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            h = mx == red ? (green - blue) / d + (green < blue ? 6 : 0)
                : mx == green ? (blue - red) / d + 2 : (red - green) / d + 4
            h *= 60
        }
        return HSL(hue: h, saturation: s, lightness: l)
    }
}
