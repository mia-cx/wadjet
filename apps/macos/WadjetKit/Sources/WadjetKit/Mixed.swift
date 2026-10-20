import CoreGraphics
import Foundation

/// One setting read across several selected Annotations: the value they all
/// share, or mixed when any two differ — what a Tool menu shows for a
/// multi-selection, like Illustrator's blank fields and "?" swatches
public enum Mixed<Value: Equatable>: Equatable {
    case same(Value)
    case mixed

    /// nil when there are no values at all
    public init?(_ values: some Sequence<Value>) {
        var it = values.makeIterator()
        guard let first = it.next() else { return nil }
        while let v = it.next() { if v != first { self = .mixed; return } }
        self = .same(first)
    }

    /// the shared value; nil while mixed
    public var value: Value? { if case let .same(v) = self { v } else { nil } }
    public var isMixed: Bool { self == .mixed }
}

extension Mixed: Sendable where Value: Sendable {}

extension AnnotationStyle {
    /// several Annotations' styles resolved field by field
    public struct Shared: Equatable, Sendable {
        public var colour: Mixed<RGBAColour>
        public var width: Mixed<CGFloat>
        public var opacity: Mixed<Double>
        public var head: Mixed<LineEnd>
        public var tail: Mixed<LineEnd>
        public var dash: Mixed<LineDash>
        public var fill: Mixed<RGBAColour?>
        public var stroked: Mixed<Bool>

        /// nil for no styles
        public init?(_ styles: [AnnotationStyle]) {
            guard let colour = Mixed(styles.map(\.colour)), let width = Mixed(styles.map(\.width)),
                  let opacity = Mixed(styles.map(\.opacity)), let head = Mixed(styles.map(\.head)),
                  let tail = Mixed(styles.map(\.tail)), let dash = Mixed(styles.map(\.dash)),
                  let fill = Mixed(styles.map(\.fill)), let stroked = Mixed(styles.map(\.stroked))
            else { return nil }
            self.colour = colour; self.width = width; self.opacity = opacity
            self.head = head; self.tail = tail; self.dash = dash
            self.fill = fill; self.stroked = stroked
        }
    }
}
