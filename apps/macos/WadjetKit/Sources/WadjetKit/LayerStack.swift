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
    /// the front-most visible, unlocked Annotation under `point` — what a click selects
    public func topmost(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.reversed().first {
            !$0.hidden && !$0.locked && PathGeometry.hitTest($0, at: point, tolerance: tolerance)
        }
    }

    /// one step toward the front / back, or all the way
    public enum Restack: Sendable { case up, down, front, back }
    public mutating func restack(_ id: Annotation.ID, _ move: Restack) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        switch move {
        case .up: self.move(id, to: i + 1)
        case .down: self.move(id, to: i - 1)
        case .front: self.move(id, to: annotations.count - 1)
        case .back: self.move(id, to: 0)
        }
    }
    /// `index` is back-to-front, clamped to the stack; no-op for a missing id
    public mutating func move(_ id: Annotation.ID, to index: Int) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        let a = annotations.remove(at: i)
        annotations.insert(a, at: min(max(0, index), annotations.count))
    }
    /// replace the annotation with the same id, in place
    public mutating func replace(_ a: Annotation) {
        if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
    }

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
