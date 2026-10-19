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

/// a Pen path's node list; `closed` joins the last node back to the first
public struct PathData: Codable, Equatable, Sendable {
    public var nodes: [PathNode]
    public var closed: Bool
    public init(nodes: [PathNode] = [], closed: Bool = false) {
        self.nodes = nodes
        self.closed = closed
    }
}
