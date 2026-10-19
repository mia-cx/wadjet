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

    enum CodingKeys: String, CodingKey { case line }
    enum LineKeys: String, CodingKey { case start, end }
    public init(from decoder: Decoder) throws {
        let l = try decoder.container(keyedBy: CodingKeys.self)
            .nestedContainer(keyedBy: LineKeys.self, forKey: .line)
        self = .line(start: try l.decodePoint(forKey: .start),
                     end: try l.decodePoint(forKey: .end))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .line(start, end):
            var l = c.nestedContainer(keyedBy: LineKeys.self, forKey: .line)
            try l.encodePoint(start, forKey: .start)
            try l.encodePoint(end, forKey: .end)
        }
    }
}

/// a CGPoint on the wire as `[x, y]` — later Annotation kinds reuse these for
/// their points
private extension KeyedDecodingContainer {
    func decodePoint(forKey key: Key) throws -> CGPoint {
        let v = try decode([CGFloat].self, forKey: key)
        guard v.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                debugDescription: "a point is exactly [x, y], got \(v.count) elements")
        }
        return CGPoint(x: v[0], y: v[1])
    }
}
private extension KeyedEncodingContainer {
    mutating func encodePoint(_ p: CGPoint, forKey key: Key) throws {
        try encode([p.x, p.y], forKey: key)
    }
}

/// How an Annotation draws: stroke colour and width.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var colour: RGBAColour
    public var width: CGFloat // stroke width, points
    public init(colour: RGBAColour, width: CGFloat) {
        self.colour = colour
        self.width = width
    }
}

/// sRGB, components 0…1
public struct RGBAColour: Codable, Equatable, Sendable {
    public var red, green, blue, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
