import Foundation

/// A persisted usage history with an explicitly refreshed presentation snapshot.
/// Each use contributes one point, halving every `halfLife` seconds. Callers can
/// take a prefix of `rankedItems` for toolbar slots, recent fonts, or swatches.
public struct FrecencyRanker<Item: Hashable & Codable>: Codable {
    private struct Usage: Codable {
        var score: Double
        var date: Date
    }

    public let halfLife: TimeInterval
    public private(set) var pinnedItems: [Item] = []
    /// Unpinned candidates, ordered at the last refresh. Ties retain candidate order.
    public private(set) var rankedItems: [Item] = []
    private var usage: [Item: Usage] = [:]

    /// The default half-life is seven days. Dates are supplied at each operation
    /// so tests and callers can use their own clock without persisting a closure.
    public init(halfLife: TimeInterval = 7 * 24 * 60 * 60) {
        precondition(halfLife.isFinite && halfLife > 0)
        self.halfLife = halfLife
    }

    /// Records a use without changing either published list.
    public mutating func recordUse(of item: Item, at date: Date = .now) {
        let previous = usage[item]
        // A clock correction must not amplify earlier uses.
        let effectiveDate = max(date, previous?.date ?? date)
        usage[item] = Usage(score: score(for: item, at: effectiveDate) + 1, date: effectiveDate)
    }

    /// Publishes a new ranking of unique candidates. Pins keep their supplied
    /// order in a separate list and never consume ranked slots. Unused items tie
    /// at zero, allowing the candidate order to supply the initial shortlist.
    public mutating func refresh(
        candidates: [Item], pinned: [Item] = [], at date: Date = .now
    ) {
        var seen = Set<Item>()
        pinnedItems = pinned.filter { seen.insert($0).inserted }
        let candidates = candidates.filter { seen.insert($0).inserted }
        rankedItems = candidates.enumerated().sorted { lhs, rhs in
            let left = score(for: lhs.element, at: date)
            let right = score(for: rhs.element, at: date)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    private func score(for item: Item, at date: Date) -> Double {
        guard let entry = usage[item] else { return 0 }
        return entry.score * pow(0.5, max(0, date.timeIntervalSince(entry.date)) / halfLife)
    }
}
