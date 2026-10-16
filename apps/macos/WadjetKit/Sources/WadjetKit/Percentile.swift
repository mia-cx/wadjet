public extension Array where Element: Comparable {
    /// The nearest-rank percentile: the smallest element with at least `p` percent (0–100) of the elements at or below it. Nil when empty.
    func percentile(_ p: Double) -> Element? {
        guard !isEmpty else { return nil }
        let rank = Swift.min(count, Swift.max(1, Int((p / 100 * Double(count)).rounded(.up))))
        return sorted()[rank - 1]
    }
}
