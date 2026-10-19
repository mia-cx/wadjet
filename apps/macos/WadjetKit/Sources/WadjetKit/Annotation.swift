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
    public init(id: UUID = UUID(), kind: AnnotationKind, style: AnnotationStyle,
                transform: AnnotationTransform = .identity) {
        self.id = id
        self.kind = kind
        self.style = style
        self.transform = transform
    }

    enum CodingKeys: String, CodingKey { case id, kind, style, transform }
    /// annotations.json files from before `transform` existed decode as .identity
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(AnnotationKind.self, forKey: .kind)
        style = try c.decode(AnnotationStyle.self, forKey: .style)
        transform = try c.decodeIfPresent(AnnotationTransform.self, forKey: .transform) ?? .identity
    }
}

/// What an Annotation is; later slices add cases (shapes, pen, text, images…)
public enum AnnotationKind: Codable, Equatable, Sendable {
    case line(start: CGPoint, end: CGPoint)
    /// the filled rect in untransformed geometry space; Black out draws opaque
    /// black whatever the style
    case censor(rect: CGRect, method: CensorMethod)

    enum CodingKeys: String, CodingKey { case line, censor }
    enum LineKeys: String, CodingKey { case start, end }
    enum CensorKeys: String, CodingKey { case rect, method }
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
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "an AnnotationKind is a line or a censor"))
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
        }
    }
}

/// How a Censor obscures its rect; Blur and Pixelate join in #124.
public enum CensorMethod: String, Codable, Sendable {
    case blackOut
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

/// How an Annotation draws: stroke colour, width, and opacity.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var colour: RGBAColour
    public var width: CGFloat // stroke width, points
    /// whole-Annotation opacity, separate from colour alpha
    public var opacity: Double
    public init(colour: RGBAColour, width: CGFloat, opacity: Double = 1) {
        self.colour = colour
        self.width = width
        self.opacity = opacity
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colour = try c.decode(RGBAColour.self, forKey: .colour)
        width = try c.decode(CGFloat.self, forKey: .width)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1 // saved before opacity existed
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
