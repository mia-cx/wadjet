import CoreGraphics

/// Rectangles contribute both edges and their centre on each axis. Loose lines
/// support Measure's pixel edges; their optional span controls the guide's extent.
public enum SnapTarget: Equatable, Sendable {
    case rect(CGRect)
    case x(CGFloat, span: ClosedRange<CGFloat>? = nil)
    case y(CGFloat, span: ClosedRange<CGFloat>? = nil)
}

/// A guide line in the same coordinate space as the supplied geometry.
public struct SnapGuide: Equatable, Sendable {
    public let start: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

/// Add `offset` to the proposed geometry. Guides already account for both axes
/// of that translation. A zero offset can still have guides for exact alignment.
public struct SnapResult: Equatable, Sendable {
    public let offset: CGPoint
    /// At most one guide per axis, vertical first, then horizontal.
    public let guides: [SnapGuide]
}

/// the axes `snap` may move along — an axis not listed gets offset 0 and no guide
public struct SnapAxes: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let x = SnapAxes(rawValue: 1)
    public static let y = SnapAxes(rawValue: 2)
    public static let both: SnapAxes = [.x, .y]
}

/// Stateless alignment for drawing points and moving Annotation bounds.
public enum SnappingEngine {
    /// Snaps each axis independently to the nearest target within `range` points,
    /// inclusive. Equal distances prefer target order, then the moving rectangle's
    /// min/centre/max anchors, then point order. Rectangles are standardized.
    /// Exclude the moving Annotation from targets. Coordinates must be finite.
    /// `skip` implements holding ⌘ or the Snapping toggle without discarding targets.
    /// `axes` limits snapping to the listed axes — a grip that can't move along
    /// one gets no offset and no guide there.
    public static func snap(
        rect: CGRect? = nil, points: [CGPoint] = [], targets: [SnapTarget],
        range: CGFloat = 6, skip: Bool = false, axes: SnapAxes = .both
    ) -> SnapResult {
        guard !skip, range >= 0 else { return SnapResult(offset: .zero, guides: []) }
        let x = axes.contains(.x)
            ? nearest(moving: features(rect: rect, points: points, xAxis: true),
                      targets: targets.map { features(target: $0, xAxis: true) }, range: range)
            : nil
        let y = axes.contains(.y)
            ? nearest(moving: features(rect: rect, points: points, xAxis: false),
                      targets: targets.map { features(target: $0, xAxis: false) }, range: range)
            : nil
        let offset = CGPoint(x: x?.offset ?? 0, y: y?.offset ?? 0)
        var guides: [SnapGuide] = []
        if let x { guides.append(guide(x, perpendicularOffset: offset.y, xAxis: true)) }
        if let y { guides.append(guide(y, perpendicularOffset: offset.x, xAxis: false)) }
        return SnapResult(offset: offset, guides: guides)
    }

    private struct Feature {
        let value: CGFloat
        let span: ClosedRange<CGFloat>?
    }

    private struct Match {
        let moving: Feature
        let target: Feature
        var offset: CGFloat { target.value - moving.value }
    }

    private static func features(rect: CGRect?, points: [CGPoint], xAxis: Bool) -> [Feature] {
        var result: [Feature] = []
        if let rect, !rect.isNull {
            let rect = rect.standardized
            let values = xAxis ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
            let span = xAxis ? rect.minY...rect.maxY : rect.minX...rect.maxX
            result = values.map { Feature(value: $0, span: span) }
        }
        result += points.map {
            let perpendicular = xAxis ? $0.y : $0.x
            return Feature(value: xAxis ? $0.x : $0.y, span: perpendicular...perpendicular)
        }
        return result
    }

    private static func features(target: SnapTarget, xAxis: Bool) -> [Feature] {
        switch target {
        case .rect(let rect): return features(rect: rect, points: [], xAxis: xAxis)
        case .x(let value, let span): return xAxis ? [Feature(value: value, span: span)] : []
        case .y(let value, let span): return xAxis ? [] : [Feature(value: value, span: span)]
        }
    }

    private static func nearest(moving: [Feature], targets: [[Feature]], range: CGFloat) -> Match? {
        var best: Match?
        // Keep each target's features together so ties prefer the original target,
        // then the moving anchor, before choosing a target edge or centre.
        for targetFeatures in targets {
            for feature in moving {
                for target in targetFeatures {
                    let match = Match(moving: feature, target: target)
                    let distance = abs(match.offset)
                    guard distance <= range else { continue }
                    if let best, distance >= abs(best.offset) { continue }
                    best = match
                }
            }
        }
        return best
    }

    private static func guide(_ match: Match, perpendicularOffset: CGFloat, xAxis: Bool) -> SnapGuide {
        // Every moving feature has an extent. An unbounded target line borrows it.
        let moving = match.moving.span!
        var lower = moving.lowerBound + perpendicularOffset
        var upper = moving.upperBound + perpendicularOffset
        if let target = match.target.span {
            lower = min(lower, target.lowerBound)
            upper = max(upper, target.upperBound)
        }
        let value = match.target.value
        return SnapGuide(start: xAxis ? CGPoint(x: value, y: lower) : CGPoint(x: lower, y: value),
                         end: xAxis ? CGPoint(x: value, y: upper) : CGPoint(x: upper, y: value))
    }
}
