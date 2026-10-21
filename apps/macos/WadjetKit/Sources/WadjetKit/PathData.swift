import CoreGraphics
import Foundation

/// one Pen node: the anchor and its bezier handles in absolute geometry
/// coords; a nil handle = a corner on that side
public struct PathNode: Codable, Equatable, Sendable {
    public var anchor: CGPoint
    public var handleIn: CGPoint?   // incoming handle, steers the segment before the node
    public var handleOut: CGPoint?  // outgoing handle, steers the segment after it
    public init(anchor: CGPoint, handleIn: CGPoint? = nil, handleOut: CGPoint? = nil) {
        self.anchor = anchor
        self.handleIn = handleIn
        self.handleOut = handleOut
    }
    enum CodingKeys: String, CodingKey { case anchor, handleIn = "in", handleOut = "out" }
}

/// a Pen path's node list; `closed` joins the last node back to the first.
/// `rawPoints`/`smoothing` are a Brush stroke's samples and the Smoothing it
/// was fitted at — kept so the Smoothing slider can refit; both nil on Pen.
public struct PathData: Codable, Equatable, Sendable {
    public var nodes: [PathNode]
    public var closed: Bool
    public var rawPoints: [CGPoint]?
    public var smoothing: CGFloat?
    public init(nodes: [PathNode] = [], closed: Bool = false,
                rawPoints: [CGPoint]? = nil, smoothing: CGFloat? = nil) {
        self.nodes = nodes
        self.closed = closed
        self.rawPoints = rawPoints
        self.smoothing = smoothing
    }
    enum CodingKeys: String, CodingKey { case nodes, closed, rawPoints = "raw", smoothing }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decode([PathNode].self, forKey: .nodes)
        closed = try c.decode(Bool.self, forKey: .closed)
        rawPoints = try c.decodeIfPresent([CGPoint].self, forKey: .rawPoints)
        smoothing = try c.decodeIfPresent(CGFloat.self, forKey: .smoothing)
    }

    /// a Brush stroke fitted with StrokeFitter: nodes chain the cubic segments
    /// (node k's handleOut = segment k's control1, node k+1's handleIn =
    /// control2); nil when the samples hold fewer than 2 distinct points
    public static func fitted(_ raw: [CGPoint], smoothing: CGFloat) -> PathData? {
        let stroke = StrokeFitter.fit(raw, smoothing: smoothing)
        guard let first = stroke.segments.first else { return nil }
        var nodes = [PathNode(anchor: first.start, handleOut: first.control1)]
        for s in stroke.segments {
            nodes.append(PathNode(anchor: s.end, handleIn: s.control2))
        }
        // the middle anchors carry both sides: node k+1's handleOut is segment
        // k+1's control1
        for (i, s) in stroke.segments.dropFirst().enumerated() {
            nodes[i + 1].handleOut = s.control1
        }
        return PathData(nodes: nodes, rawPoints: stroke.rawPoints, smoothing: smoothing)
    }

    /// refits from the kept raw samples at a new smoothing; a path without raw
    /// samples (Pen) comes back unchanged
    public func refitted(smoothing: CGFloat) -> PathData {
        guard let rawPoints, let d = Self.fitted(rawPoints, smoothing: smoothing) else { return self }
        return d
    }
}
