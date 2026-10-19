import Foundation

/// how a Step counter labels its value
public enum CounterFormat: String, Codable, CaseIterable, Sendable {
    case numbers, letters
    /// numbers: "1", "2"…; letters count bijective base 26: A…Z, AA, AB…
    /// (1 = A, 27 = AA). Values below 1 label as 1/A.
    public func label(_ value: Int) -> String {
        switch self {
        case .numbers:
            return String(max(1, value))
        case .letters:
            var v = max(1, value), s = ""
            while v > 0 {
                v -= 1
                s = String(UnicodeScalar(UInt8(ascii: "A") + UInt8(v % 26))) + s
                v /= 26
            }
            return s
        }
    }
}

extension LayerStack {
    /// the value a plain Step counter click places in `format`: one past the
    /// newest (last in stack order) counter in that format, or 1
    public func nextCounterValue(_ format: CounterFormat) -> Int {
        for a in annotations.reversed() {
            if case let .counter(_, _, value, f) = a.kind, f == format { return value + 1 }
        }
        return 1
    }

    /// a removed counter's sequence counts down to close the gap: counters of
    /// its format after it in stack order decrement while each continues the
    /// run (value == the previous one's + 1) — a repeated or restarted value
    /// ends it. LayerStack.remove calls this before removing.
    mutating func renumberCounters(removing id: Annotation.ID) {
        guard let i = annotations.firstIndex(where: { $0.id == id }),
              case let .counter(_, _, v, f) = annotations[i].kind else { return }
        var prev = v
        for j in annotations.indices.dropFirst(i + 1) {
            guard case let .counter(c, r, value, format) = annotations[j].kind,
                  format == f else { continue }
            guard value == prev + 1 else { return }
            prev = value
            annotations[j].kind = .counter(center: c, radius: r, value: value - 1, format: format)
        }
    }
}
