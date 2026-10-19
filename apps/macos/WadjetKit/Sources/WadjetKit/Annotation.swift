import CoreGraphics
import Foundation

/// One object drawn with Markup. Coordinates are AppKit global screen points
/// (bottom-left origin, the space `NSScreen.frame` uses), so an Annotation can
/// span displays; each Markup panel draws its part.
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var style: AnnotationStyle
    public var transform: AnnotationTransform
    /// doesn't draw, on screen or in a flattened Canvas
    public var hidden: Bool
    /// can't be selected or erased
    public var locked: Bool
    public init(id: UUID = UUID(), kind: AnnotationKind, style: AnnotationStyle,
                transform: AnnotationTransform = .identity,
                hidden: Bool = false, locked: Bool = false) {
        self.id = id
        self.kind = kind
        self.style = style
        self.transform = transform
        self.hidden = hidden
        self.locked = locked
    }

    enum CodingKeys: String, CodingKey { case id, kind, style, transform, hidden, locked }
    /// annotations.json files from before `transform` existed decode as .identity;
    /// files from before `hidden`/`locked` existed decode as false
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(AnnotationKind.self, forKey: .kind)
        style = try c.decode(AnnotationStyle.self, forKey: .style)
        transform = try c.decodeIfPresent(AnnotationTransform.self, forKey: .transform) ?? .identity
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}

/// What an Annotation is; later slices add cases (pen, text, images…)
public enum AnnotationKind: Codable, Equatable, Sendable {
    case line(start: CGPoint, end: CGPoint)
    /// the filled rect in untransformed geometry space; Black out draws opaque
    /// black whatever the style, Blur and Pixelate show the content beneath
    /// filtered
    case censor(rect: CGRect, method: CensorMethod)
    case shape(ShapeKind, rect: CGRect)
    case counter(center: CGPoint, radius: CGFloat, value: Int, format: CounterFormat)

    enum CodingKeys: String, CodingKey { case line, censor, shape, counter }
    enum LineKeys: String, CodingKey { case start, end }
    enum CensorKeys: String, CodingKey { case rect, method }
    enum ShapeKeys: String, CodingKey { case kind, rect }
    enum CounterKeys: String, CodingKey { case center, radius, value, format }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.line) {
            let l = try c.nestedContainer(keyedBy: LineKeys.self, forKey: .line)
            self = .line(start: try l.decodePoint(forKey: .start),
                         end: try l.decodePoint(forKey: .end))
        } else if c.contains(.censor) {
            let n = try c.nestedContainer(keyedBy: CensorKeys.self, forKey: .censor)
            self = .censor(rect: try n.decodeRect(forKey: .rect),
                           method: try n.decode(CensorMethod.self, forKey: .method))
        } else if c.contains(.shape) {
            let s = try c.nestedContainer(keyedBy: ShapeKeys.self, forKey: .shape)
            self = .shape(try s.decode(ShapeKind.self, forKey: .kind),
                          rect: try s.decodeRect(forKey: .rect))
        } else if c.contains(.counter) {
            let n = try c.nestedContainer(keyedBy: CounterKeys.self, forKey: .counter)
            self = .counter(center: try n.decodePoint(forKey: .center),
                            radius: try n.decode(CGFloat.self, forKey: .radius),
                            value: try n.decode(Int.self, forKey: .value),
                            format: try n.decode(CounterFormat.self, forKey: .format))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "an AnnotationKind is a line, a censor, a shape, or a counter"))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .line(start, end):
            var l = c.nestedContainer(keyedBy: LineKeys.self, forKey: .line)
            try l.encodePoint(start, forKey: .start)
            try l.encodePoint(end, forKey: .end)
        case let .censor(rect, method):
            var n = c.nestedContainer(keyedBy: CensorKeys.self, forKey: .censor)
            try n.encodeRect(rect, forKey: .rect)
            try n.encode(method, forKey: .method)
        case let .shape(kind, rect):
            var s = c.nestedContainer(keyedBy: ShapeKeys.self, forKey: .shape)
            try s.encode(kind, forKey: .kind)
            try s.encodeRect(rect, forKey: .rect)
        case let .counter(center, radius, value, format):
            var n = c.nestedContainer(keyedBy: CounterKeys.self, forKey: .counter)
            try n.encodePoint(center, forKey: .center)
            try n.encode(radius, forKey: .radius)
            try n.encode(value, forKey: .value)
            try n.encode(format, forKey: .format)
        }
    }
}

/// How a Censor obscures its rect. Strengths are global points; renderers scale them to pixels.
public enum CensorMethod: Codable, Equatable, Sendable {
    case blackOut
    case blur(radius: CGFloat)
    case pixelate(blockSize: CGFloat)
    public static let defaultBlur = CensorMethod.blur(radius: 12)
    public static let defaultPixelate = CensorMethod.pixelate(blockSize: 12)
    /// Blur and Pixelate draw from the pixels beneath; Black out needs none
    public var samplesBeneath: Bool {
        switch self {
        case .blackOut: false
        case .blur, .pixelate: true
        }
    }

    enum CodingKeys: String, CodingKey { case blur, pixelate }
    enum BlurKeys: String, CodingKey { case radius }
    enum PixelateKeys: String, CodingKey { case blockSize }
    /// `"blackOut"` stays the bare string it always was; the sampling methods
    /// nest their strength: `{"blur":{"radius":12}}`
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            guard s == "blackOut" else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath,
                                          debugDescription: "unknown CensorMethod \"\(s)\""))
            }
            self = .blackOut
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.blur) {
            let b = try c.nestedContainer(keyedBy: BlurKeys.self, forKey: .blur)
            self = .blur(radius: try b.decode(CGFloat.self, forKey: .radius))
        } else if c.contains(.pixelate) {
            let p = try c.nestedContainer(keyedBy: PixelateKeys.self, forKey: .pixelate)
            self = .pixelate(blockSize: try p.decode(CGFloat.self, forKey: .blockSize))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "a CensorMethod is \"blackOut\", blur or pixelate"))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .blackOut:
            var c = encoder.singleValueContainer()
            try c.encode("blackOut")
        case let .blur(radius):
            var c = encoder.container(keyedBy: CodingKeys.self)
            var b = c.nestedContainer(keyedBy: BlurKeys.self, forKey: .blur)
            try b.encode(radius, forKey: .radius)
        case let .pixelate(blockSize):
            var c = encoder.container(keyedBy: CodingKeys.self)
            var p = c.nestedContainer(keyedBy: PixelateKeys.self, forKey: .pixelate)
            try p.encode(blockSize, forKey: .blockSize)
        }
    }
}

/// a CGPoint on the wire as `[x, y]` and a CGRect as `[x, y, width, height]` —
/// later Annotation kinds reuse these for their geometry
private extension KeyedDecodingContainer {
    func decodePoint(forKey key: Key) throws -> CGPoint {
        let v = try decode([CGFloat].self, forKey: key)
        guard v.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                debugDescription: "a point is exactly [x, y], got \(v.count) elements")
        }
        return CGPoint(x: v[0], y: v[1])
    }
    func decodeRect(forKey key: Key) throws -> CGRect {
        let v = try decode([CGFloat].self, forKey: key)
        guard v.count == 4 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                debugDescription: "a rect is exactly [x, y, width, height], got \(v.count) elements")
        }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}
private extension KeyedEncodingContainer {
    mutating func encodePoint(_ p: CGPoint, forKey key: Key) throws {
        try encode([p.x, p.y], forKey: key)
    }
    mutating func encodeRect(_ r: CGRect, forKey key: Key) throws {
        try encode([r.origin.x, r.origin.y, r.width, r.height], forKey: key)
    }
}

/// How an Annotation draws: stroke colour, width, and opacity — shapes add a
/// fill and can drop their stroke.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var colour: RGBAColour
    public var width: CGFloat // stroke width, points
    /// whole-Annotation opacity, separate from colour alpha
    public var opacity: Double
    /// shapes only: the inside's colour, nil = unfilled
    public var fill: RGBAColour?
    /// shapes only: false leaves just the fill
    public var stroked: Bool
    public init(colour: RGBAColour, width: CGFloat, opacity: Double = 1,
                fill: RGBAColour? = nil, stroked: Bool = true) {
        self.colour = colour
        self.width = width
        self.opacity = opacity
        self.fill = fill
        self.stroked = stroked
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colour = try c.decode(RGBAColour.self, forKey: .colour)
        width = try c.decode(CGFloat.self, forKey: .width)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1 // saved before opacity existed
        fill = try c.decodeIfPresent(RGBAColour.self, forKey: .fill) // saved before shapes existed
        stroked = try c.decodeIfPresent(Bool.self, forKey: .stroked) ?? true
    }
}

extension Annotation {
    /// what the outline strokes with: Lines always, shapes while `style.stroked`
    public var strokeColour: RGBAColour? {
        switch kind {
        case .line: style.colour
        case .shape: style.stroked ? style.colour : nil
        case .censor, .counter: nil
        }
    }
    /// what the inside fills with: a shape's `style.fill`, a Black out's opaque
    /// black or a counter's `style.colour` whatever the style, nil otherwise
    public var fillColour: RGBAColour? {
        switch kind {
        case .line: nil
        case .shape: style.fill
        case .censor: RGBAColour(red: 0, green: 0, blue: 0, alpha: 1)
        case .counter: style.colour
        }
    }
}

/// sRGB, components 0…1
public struct RGBAColour: Codable, Hashable, Sendable {
    public var red, green, blue, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    /// "#RRGGBB" (alpha ignored): components clamped to 0…1 and rounded to 8-bit
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
    /// "#RRGGBB" or "RRGGBB", case-insensitive, alpha 1; nil for anything else
    public init?(hex: String) {
        var s = hex[hex.startIndex...]
        if s.first == "#" { s = s.dropFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, alpha: 1)
    }
}
