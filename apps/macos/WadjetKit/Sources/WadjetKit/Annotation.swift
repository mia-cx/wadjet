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

/// What an Annotation is; later slices add cases (pen, images…)
public enum AnnotationKind: Codable, Equatable, Sendable {
    /// `bend` is the on-curve point the Line passes through at t = 0.5; nil = straight
    case line(start: CGPoint, end: CGPoint, bend: CGPoint? = nil)
    /// the filled rect in untransformed geometry space; Black out draws opaque
    /// black whatever the style, Blur and Pixelate show the content beneath
    /// filtered
    case censor(rect: CGRect, method: CensorMethod)
    case shape(ShapeKind, rect: CGRect)
    case counter(center: CGPoint, radius: CGFloat, value: Int, format: CounterFormat)
    /// a Pen path: bezier nodes, optionally closed (closed paths can be filled)
    case path(PathData)
    case magnify(Magnifier)
    case text(TextData)

    enum CodingKeys: String, CodingKey { case line, censor, shape, counter, path, magnify, text }
    enum LineKeys: String, CodingKey { case start, end, bend }
    enum CensorKeys: String, CodingKey { case rect, method }
    enum ShapeKeys: String, CodingKey { case kind, rect }
    enum CounterKeys: String, CodingKey { case center, radius, value, format }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.line) {
            let l = try c.nestedContainer(keyedBy: LineKeys.self, forKey: .line)
            self = .line(start: try l.decodePoint(forKey: .start),
                         end: try l.decodePoint(forKey: .end),
                         bend: try l.decodePointIfPresent(forKey: .bend))
        } else if c.contains(.path) {
            self = .path(try c.decode(PathData.self, forKey: .path))
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
        } else if c.contains(.magnify) {
            self = .magnify(try c.decode(Magnifier.self, forKey: .magnify))
        } else if c.contains(.text) {
            self = .text(try c.decode(TextData.self, forKey: .text))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "an AnnotationKind is a line, a path, a censor, a shape, a counter, a magnify, or a text"))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .line(start, end, bend):
            var l = c.nestedContainer(keyedBy: LineKeys.self, forKey: .line)
            try l.encodePoint(start, forKey: .start)
            try l.encodePoint(end, forKey: .end)
            if let bend { try l.encodePoint(bend, forKey: .bend) }
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
        case let .path(data):
            try c.encode(data, forKey: .path)
        case let .magnify(m):
            try c.encode(m, forKey: .magnify)
        case let .text(data):
            try c.encode(data, forKey: .text)
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

/// how an Annotation composites; Highlighter multiplies (named Blend — not
/// BlendMode, which collides with SwiftUI's in app files)
public enum AnnotationBlend: String, Codable, CaseIterable, Sendable {
    case normal, multiply
}

/// a CGPoint on the wire as `[x, y]` and a CGRect as `[x, y, width, height]` —
/// later Annotation kinds reuse these for their geometry
extension KeyedDecodingContainer {
    func decodePoint(forKey key: Key) throws -> CGPoint {
        let v = try decode([CGFloat].self, forKey: key)
        guard v.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                debugDescription: "a point is exactly [x, y], got \(v.count) elements")
        }
        return CGPoint(x: v[0], y: v[1])
    }
    /// a point that may be absent — like decodePoint but returns nil when the key is missing
    func decodePointIfPresent(forKey key: Key) throws -> CGPoint? {
        guard contains(key) else { return nil }
        return try decodePoint(forKey: key)
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
extension KeyedEncodingContainer {
    mutating func encodePoint(_ p: CGPoint, forKey key: Key) throws {
        try encode([p.x, p.y], forKey: key)
    }
    mutating func encodeRect(_ r: CGRect, forKey key: Key) throws {
        try encode([r.origin.x, r.origin.y, r.width, r.height], forKey: key)
    }
}

/// How an Annotation draws: stroke colour, width, and opacity. `head` sits at
/// the end point, `tail` at the start point; `dash` patterns the stroke;
/// `fill` paints the inside of a shape or a closed path (nil = unfilled);
/// `stroked` lets shapes drop their stroke.
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var colour: RGBAColour
    public var width: CGFloat // stroke width, points
    /// whole-Annotation opacity, separate from colour alpha
    public var opacity: Double
    public var head: LineEnd
    public var tail: LineEnd
    public var dash: LineDash
    /// the inside's colour — shapes, and closed paths; nil = unfilled
    public var fill: RGBAColour?
    /// shapes and closed paths only: false leaves just the fill
    public var stroked: Bool
    /// how the Annotation composites over what's beneath; a Highlighter multiplies
    public var blend: AnnotationBlend
    public init(colour: RGBAColour, width: CGFloat, opacity: Double = 1,
                head: LineEnd = .none, tail: LineEnd = .none, dash: LineDash = .solid,
                fill: RGBAColour? = nil, stroked: Bool = true, blend: AnnotationBlend = .normal) {
        self.colour = colour
        self.width = width
        self.opacity = opacity
        self.head = head
        self.tail = tail
        self.dash = dash
        self.fill = fill
        self.stroked = stroked
        self.blend = blend
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colour = try c.decode(RGBAColour.self, forKey: .colour)
        width = try c.decode(CGFloat.self, forKey: .width)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1 // saved before opacity existed
        head = try c.decodeIfPresent(LineEnd.self, forKey: .head) ?? .none   // saved before ends existed
        tail = try c.decodeIfPresent(LineEnd.self, forKey: .tail) ?? .none
        dash = try c.decodeIfPresent(LineDash.self, forKey: .dash) ?? .solid // saved before dashes existed
        fill = try c.decodeIfPresent(RGBAColour.self, forKey: .fill) // saved before shapes existed
        stroked = try c.decodeIfPresent(Bool.self, forKey: .stroked) ?? true
        blend = try c.decodeIfPresent(AnnotationBlend.self, forKey: .blend) ?? .normal // saved before blends existed
    }
}

extension Annotation {
    /// what the outline strokes with: Lines, paths, and stroked shapes —
    /// a closed path drops its stroke with `stroked` off, like a shape;
    /// a Magnify's source outline and leader
    public var strokeColour: RGBAColour? {
        switch kind {
        case .line, .magnify: style.colour
        case let .path(d): !d.closed || style.stroked ? style.colour : nil
        case .shape: style.stroked ? style.colour : nil
        case .censor, .counter, .text: nil
        }
    }
    /// what the inside fills with: a shape's or closed path's `style.fill`, a
    /// Black out's opaque black or a counter's `style.colour` whatever the
    /// style, nil otherwise. Text: its box's inside is drawn — the pill, or
    /// the glyphs in the text colour
    public var fillColour: RGBAColour? {
        switch kind {
        case .line, .magnify: nil
        case let .path(d): d.closed ? style.fill : nil
        case .shape: style.fill
        case .censor: RGBAColour(red: 0, green: 0, blue: 0, alpha: 1)
        case .counter: style.colour
        case let .text(d): d.format.pill ? TextLayout.pillColour(text: style.colour, fill: style.fill)
                                        : style.colour
        }
    }
    /// the global rect whose pixels it draws from: a sampling Censor's area, a
    /// Magnify's viewport — nil for Annotations that need no live source
    public var sampledRect: CGRect? {
        switch kind {
        case let .censor(_, method) where method.samplesBeneath:
            PathGeometry.path(for: self).boundingBox
        case let .magnify(m): m.viewport
        default: nil
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
