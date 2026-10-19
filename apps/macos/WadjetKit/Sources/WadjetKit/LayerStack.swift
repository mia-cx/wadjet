import Foundation

/// The Annotations on screen, back to front. A value, so undo is snapshots.
/// `Codable` as a Canvas's `annotations.json`: `{"version":1,"annotations":[…]}`.
public struct LayerStack: Codable, Equatable, Sendable {
    public static let version = 1 // the annotations.json format this build reads and writes
    public internal(set) var annotations: [Annotation] // last draws on top; internal(set) so other WadjetKit files can add operations
    public init(_ annotations: [Annotation] = []) { self.annotations = annotations }
    public var isEmpty: Bool { annotations.isEmpty }
    /// on top
    public mutating func add(_ a: Annotation) { annotations.append(a) }
    public mutating func remove(id: Annotation.ID) { annotations.removeAll { $0.id == id } }
    public mutating func clear() { annotations.removeAll() }

    /// annotations.json; JSONEncoder with [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] like ConfigStore
    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
    public init(json: Data) throws {
        self = try JSONDecoder().decode(LayerStack.self, from: json)
    }

    enum CodingKeys: String, CodingKey { case version, annotations }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        guard v <= LayerStack.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                debugDescription: "annotations.json version \(v) is newer than this build reads")
        }
        annotations = try c.decode([Annotation].self, forKey: .annotations)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LayerStack.version, forKey: .version)
        try c.encode(annotations, forKey: .annotations)
    }
}
