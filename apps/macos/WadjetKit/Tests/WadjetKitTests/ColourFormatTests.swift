import Testing
import WadjetKit

struct ColourFormatTests {
    @Test(arguments: [
        (.hex, RGB8(r: 10, g: 20, b: 30), "#0A141E"), // zero-padded uppercase
        (.rgb, RGB8(r: 51, g: 214, b: 148), "rgb(51 214 148)"),
        (.hsl, RGB8(r: 51, g: 214, b: 148), "hsl(156 67% 52%)"), // green-max sector, rounding
        (.hsl, RGB8(r: 0, g: 0, b: 255), "hsl(240 100% 50%)"), // blue-max sector
        (.hsl, RGB8(r: 255, g: 0, b: 128), "hsl(330 100% 50%)"), // red-max hue wraps past 360
        (.hsl, RGB8(r: 255, g: 255, b: 255), "hsl(0 0% 100%)"), // grey has hue 0
        (.oklch, RGB8(r: 255, g: 0, b: 0), "oklch(0.628 0.258 29.2)"),
        (.oklch, RGB8(r: 0, g: 0, b: 255), "oklch(0.452 0.313 264.1)"), // negative atan2 wraps
        (.oklch, RGB8(r: 51, g: 214, b: 148), "oklch(0.779 0.162 160.6)"),
        (.oklch, RGB8(r: 255, g: 255, b: 255), "oklch(1.000 0.000 0.0)"), // grey's powerless hue prints 0
        (.oklch, RGB8(r: 128, g: 128, b: 128), "oklch(0.600 0.000 0.0)"),
        (.lab, RGB8(r: 255, g: 0, b: 0), "lab(54.29 80.80 69.89)"),
        (.lab, RGB8(r: 51, g: 214, b: 148), "lab(76.52 -54.15 20.48)"), // negative a
        (.lab, RGB8(r: 10, g: 20, b: 30), "lab(5.85 -1.50 -8.25)"), // dark colour takes the linear branch of f
        (.lab, RGB8(r: 255, g: 255, b: 255), "lab(100.00 0.00 0.00)"), // D50 white maps to zero a/b
        (.lab, RGB8(r: 48, g: 48, b: 48), "lab(19.87 0.00 0.00)"), // float noise never prints -0.00
        (.swiftUI, RGB8(r: 51, g: 214, b: 148), "Color(red: 0.200, green: 0.839, blue: 0.580)"),
    ] as [(ColourFormat, RGB8, String)])
    func formats(format: ColourFormat, colour: RGB8, expected: String) {
        #expect(format.format(colour) == expected)
    }
}
