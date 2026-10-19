import CoreGraphics
import CoreText
import Foundation

/// A Text Annotation: `origin` is the box's TOP-LEFT corner in global screen
/// points (y up, so the box extends down from it). `width` is the wrapping
/// width of the text itself (padding excluded); nil fits the text, breaking
/// lines only at newlines. Height always comes from the layout.
public struct TextData: Equatable, Sendable {
    public var string: String
    public var origin: CGPoint
    public var width: CGFloat?
    public var format: TextFormat
    public init(string: String, origin: CGPoint, width: CGFloat? = nil, format: TextFormat) {
        self.string = string
        self.origin = origin
        self.width = width
        self.format = format
    }
}

/// How Text sets type. The Text Tool's default (the last font picked etc.)
/// persists as markup.tools.text.format.
public struct TextFormat: Codable, Equatable, Sendable {
    /// family name; TextFonts.system ("SF Pro") means the system font
    public var font: String
    public var size: CGFloat
    public var weight: TextWeight
    public var alignment: TextAlignment
    /// a rounded background behind the text
    public var pill: Bool
    public static let `default` = TextFormat(font: "Noteworthy", size: 24, weight: .bold,
                                             alignment: .left, pill: false)
    public init(font: String, size: CGFloat, weight: TextWeight, alignment: TextAlignment, pill: Bool) {
        self.font = font
        self.size = size
        self.weight = weight
        self.alignment = alignment
        self.pill = pill
    }
}

public enum TextWeight: String, Codable, CaseIterable, Sendable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    /// NSFont.Weight raw values
    public var trait: CGFloat {
        switch self {
        case .ultraLight: -0.8; case .thin: -0.6; case .light: -0.4
        case .regular: 0; case .medium: 0.23; case .semibold: 0.3
        case .bold: 0.4; case .heavy: 0.56; case .black: 0.62
        }
    }
    public var title: String {
        switch self {
        case .ultraLight: "Ultralight"; case .thin: "Thin"; case .light: "Light"
        case .regular: "Regular"; case .medium: "Medium"; case .semibold: "Semibold"
        case .bold: "Bold"; case .heavy: "Heavy"; case .black: "Black"
        }
    }
    /// the case nearest `trait`; ties go heavier
    static func nearest(_ trait: CGFloat) -> TextWeight {
        allCases.dropFirst().reduce(allCases[0]) { best, w in
            let d = abs(w.trait - trait), b = abs(best.trait - trait)
            return d < b || (d == b && w.trait > best.trait) ? w : best
        }
    }
}

public enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left, centre, right
    var ct: CTTextAlignment {
        switch self { case .left: .left; case .centre: .center; case .right: .right }
    }
}

// {"text":{"string":…,"origin":[x,y],"width":w (omit when nil),"format":{…}}}
extension TextData: Codable {
    enum CodingKeys: String, CodingKey { case string, origin, width, format }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        string = try c.decode(String.self, forKey: .string)
        origin = try c.decodePoint(forKey: .origin)
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width)
        format = try c.decode(TextFormat.self, forKey: .format)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(string, forKey: .string)
        try c.encodePoint(origin, forKey: .origin)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encode(format, forKey: .format)
    }
}

/// Lays a TextData out with CoreText (no AppKit): the resolved font, the
/// wrapped text's size, and the box the Annotation draws — box = textSize +
/// 2*padding, so the padding is always part of the box, pill or not, and
/// toggling the pill never moves the text.
public struct TextLayout {
    public let data: TextData
    public let font: CTFont
    /// ascent + descent + leading of the resolved font — the fixed line pitch
    public let lineHeight: CGFloat
    public let padding: CGSize
    /// the wrapped text; width is `data.width` exactly when set
    public let textSize: CGSize
    public var size: CGSize {
        CGSize(width: textSize.width + 2 * padding.width, height: textSize.height + 2 * padding.height)
    }
    /// the box in global y-up points, extending down from `data.origin`
    public var box: CGRect {
        CGRect(x: data.origin.x, y: data.origin.y - size.height,
               width: size.width, height: size.height)
    }
    let frame: CTFrame

    public init(_ data: TextData) {
        self.data = data
        let font = TextFonts.font(family: data.format.font, weight: data.format.weight,
                                  size: data.format.size)
        self.font = font
        lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        padding = CGSize(width: 0.35 * data.format.size, height: 0.15 * data.format.size)

        var alignment = data.format.alignment.ct
        var breakMode = CTLineBreakMode.byWordWrapping
        var minH = lineHeight, maxH = lineHeight
        let paragraph = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &breakMode) { b in
                withUnsafeBytes(of: &minH) { mn in
                    withUnsafeBytes(of: &maxH) { mx in
                        CTParagraphStyleCreate([
                            CTParagraphStyleSetting(spec: .alignment, valueSize: a.count, value: a.baseAddress!),
                            CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: b.count, value: b.baseAddress!),
                            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: mn.count, value: mn.baseAddress!),
                            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: mx.count, value: mx.baseAddress!),
                        ], 4)
                    }
                }
            }
        }
        let attributed = CFAttributedStringCreate(nil, data.string as CFString, [
            kCTFontAttributeName: font,
            kCTParagraphStyleAttributeName: paragraph,
            // the style's colour comes from the context at draw time
            kCTForegroundColorFromContextAttributeName: true,
        ] as CFDictionary)!
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var fit = CFRange(location: 0, length: 0)
        let constraint = CGSize(width: data.width ?? .greatestFiniteMagnitude,
                                height: .greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(setter,
            CFRange(location: 0, length: 0), nil, constraint, &fit)
        // an empty string still occupies one empty line, and the framesetter's
        // height doesn't count the empty line a trailing newline opens
        textSize = CGSize(width: data.width ?? ceil(suggested.width),
                          height: (data.string.isEmpty ? 0 : ceil(suggested.height))
                            + (data.string.isEmpty || data.string.hasSuffix("\n") ? lineHeight : 0))
        let path = CGPath(rect: CGRect(origin: .zero, size: textSize), transform: nil)
        frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }

    /// the pill's colour: the explicit `fill` when set, else picked by the
    /// text colour's WCAG relative luminance (linearised sRGB) — a dark pill
    /// behind light text, a light pill behind dark
    public static func pillColour(text: RGBAColour, fill: RGBAColour?) -> RGBAColour {
        if let fill { return fill }
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin(text.red) + 0.7152 * lin(text.green) + 0.0722 * lin(text.blue)
        return l > 0.179
            ? RGBAColour(red: 0, green: 0, blue: 0, alpha: 0.55)
            : RGBAColour(red: 1, green: 1, blue: 1, alpha: 0.8)
    }

    /// Draws in GLOBAL y-up coordinates: applies the Annotation's transform,
    /// fades pill and glyphs together through one transparency layer, fills
    /// the pill, then draws the glyphs in `style.colour`. `text: false` draws
    /// the pill only — the editor's NSTextView shows the glyphs meanwhile.
    public static func draw(_ a: Annotation, in ctx: CGContext, text: Bool = true) {
        guard case let .text(data) = a.kind else { return }
        let layout = TextLayout(data)
        ctx.saveGState()
        ctx.concatenate(a.affineTransform)
        ctx.setAlpha(CGFloat(a.style.opacity))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let box = layout.box
        if data.format.pill {
            let colour = pillColour(text: a.style.colour, fill: a.style.fill)
            let radius = min(box.height / 2, layout.lineHeight / 2 + layout.padding.height)
            ctx.setFillColor(CGColor(srgbRed: colour.red, green: colour.green,
                                     blue: colour.blue, alpha: colour.alpha))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        if text {
            let c = a.style.colour
            ctx.setFillColor(CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
            // CTFrame lays out top-down: flip inside the text rect so the
            // first line sits at the box's top in y-up space
            let rect = CGRect(x: box.minX + layout.padding.width,
                              y: box.minY + layout.padding.height,
                              width: layout.textSize.width, height: layout.textSize.height)
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            CTFrameDraw(layout.frame, ctx)
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
