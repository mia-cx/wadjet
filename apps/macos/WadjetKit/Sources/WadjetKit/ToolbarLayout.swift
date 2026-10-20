import CoreGraphics

/// How the expanded toolbar lays out its Tool groups (config.json `toolbarLayout`).
/// A prototype switch from the Debug menu; `current` is the shipped layout.
public enum ToolbarLayoutStyle: String, Codable, CaseIterable, Sendable {
    /// one row; only the open group spreads, and the bar re-fits around it
    case current
    /// one row that holds still while the pointer is inside: groups open on a click or a
    /// short dwell, slots never shrink, and the bar grows away from the cell under the pointer
    case steady
    /// one row whose open slot is always as wide as the widest group, so the bar never resizes
    case uniform
    /// a fixed strip of group headers, and under it a bar with the shown group's Tools
    case twoRows

    public var title: String {
        switch self {
        case .current: "Current"
        case .steady: "Steady"
        case .uniform: "Uniform"
        case .twoRows: "Two Rows"
        }
    }
}

/// The measurements of a row of toolbar cells: groups of `cell`-wide cells `gap` apart, groups
/// separated by a `divider` with a `gap` either side, and `edge` before the first slot and after
/// the last. The open group spreads all its cells; a collapsed group shows one cell at the start
/// of its slot.
public struct ToolbarRowGeometry: Equatable, Sendable {
    public var cell: CGFloat
    public var gap: CGFloat
    public var divider: CGFloat
    public var edge: CGFloat
    public init(cell: CGFloat, gap: CGFloat, divider: CGFloat, edge: CGFloat) {
        self.cell = cell; self.gap = gap; self.divider = divider; self.edge = edge
    }

    /// `n` cells side by side
    public func openWidth(_ n: Int) -> CGFloat { n > 0 ? CGFloat(n) * cell + CGFloat(n - 1) * gap : 0 }
    /// Uniform's open slot: the widest group's open width
    public func uniformWidth(_ counts: [Int]) -> CGFloat { max(cell, openWidth(counts.max() ?? 1)) }

    /// One group's slot width. `reserve` is Steady's held width for the group (0 for none).
    public func slotWidth(group: Int, counts: [Int], open: Int, style: ToolbarLayoutStyle, reserve: CGFloat = 0) -> CGFloat {
        let isOpen = group == open
        let natural = isOpen ? openWidth(counts[group]) : cell
        switch style {
        case .current: return natural
        case .uniform: return isOpen ? uniformWidth(counts) : cell
        case .steady: return max(natural, reserve)
        case .twoRows: return isOpen ? natural : 0 // the second bar shows the open group only
        }
    }

    /// The row with `open` spread. `reserve[i]` is Steady's held width for group `i`.
    public func row(counts: [Int], open: Int, style: ToolbarLayoutStyle, reserve: [CGFloat] = []) -> ToolbarRow {
        // Two Rows' bar has no dividers; every other style divides each pair of groups
        let between = style == .twoRows ? 0 : divider + 2 * gap
        var x = edge, slots: [ToolbarRow.Slot] = []
        for g in counts.indices {
            if g > 0 { x += between }
            let w = slotWidth(group: g, counts: counts, open: open, style: style,
                              reserve: g < reserve.count ? reserve[g] : 0)
            slots.append(.init(x: x, width: w))
            x += w
        }
        return ToolbarRow(width: x + edge, slots: slots, open: open, counts: counts,
                          centresOpen: style == .uniform, cell: cell, gap: gap)
    }

    /// Two Rows' header strip: one `cell` per group, `gap` apart, `edge` at both ends. It never
    /// depends on which group is shown, so it never moves while the bar is expanded.
    public func strip(headers n: Int) -> (width: CGFloat, centres: [CGFloat]) {
        (2 * edge + openWidth(n), (0..<n).map { edge + CGFloat($0) * (cell + gap) + cell / 2 })
    }
}

/// A laid-out row, in row space: x runs from the row's leading edge.
public struct ToolbarRow: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public var x: CGFloat
        public var width: CGFloat
    }
    public let width: CGFloat
    public let slots: [Slot]
    let open: Int
    let counts: [Int]
    /// Uniform centres the open group's cells inside its slot; the others lead
    let centresOpen: Bool
    let cell: CGFloat
    let gap: CGFloat

    /// The centre of the open group's cell at `index`, or, with `index` nil, of a collapsed
    /// group's single cell. Nil when that cell isn't in the row.
    public func centre(group: Int, index: Int?) -> CGFloat? {
        guard slots.indices.contains(group) else { return nil }
        let s = slots[group]
        guard let i = index else { return group == open || s.width == 0 ? nil : s.x + cell / 2 }
        guard group == open, counts[group] > i, i >= 0 else { return nil }
        let used = CGFloat(counts[group]) * cell + CGFloat(counts[group] - 1) * gap
        let inset = centresOpen ? (s.width - used) / 2 : 0
        return s.x + inset + CGFloat(i) * (cell + gap) + cell / 2
    }
}

/// Steady's bar shift. The bar's centre sits `offset` from its resting centre, so a cell at
/// row-space `x` in a row `width` wide is on screen at `offset - width / 2 + x`.
public enum SteadyAnchor {
    /// The offset that keeps a cell at the same screen x when the row re-lays out from `before`
    /// to `after`, clamped to `±limit`.
    public static func offset(current: CGFloat, before: (x: CGFloat, width: CGFloat),
                              after: (x: CGFloat, width: CGFloat), limit: CGFloat) -> CGFloat {
        let o = current + (before.x - before.width / 2) - (after.x - after.width / 2)
        return min(max(o, -limit), limit)
    }
    /// The largest shift that keeps a bar `width` wide `margin` inside a screen `screenWidth`
    /// wide, and still covering the centred `keep` width (a notch the bar hangs around).
    public static func limit(width: CGFloat, screenWidth: CGFloat, margin: CGFloat, keep: CGFloat) -> CGFloat {
        max(0, min((screenWidth - width) / 2 - margin, (width - keep) / 2))
    }
}
