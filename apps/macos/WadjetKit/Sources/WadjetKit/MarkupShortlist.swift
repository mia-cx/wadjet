import Foundation

/// The Markup group's toolbar layout: pinned items, then `slotCount` slots ranked
/// by use, then the overflow. It is a snapshot taken when the toolbar opens, so
/// uses recorded while it's open move nothing until the next `open`.
public struct MarkupShortlist<Item: Hashable & Codable>: Equatable {
    public static var slotCount: Int { 3 }
    public let pinned: [Item]
    public private(set) var slots: [Item]
    public private(set) var overflow: [Item]
    /// every unpinned item in rank order, so a displaced slot returns to its place
    private let ranked: [Item]

    private init(pinned: [Item], slots: [Item], overflow: [Item], ranked: [Item]) {
        self.pinned = pinned
        self.slots = slots
        self.overflow = overflow
        self.ranked = ranked
    }

    /// Opening the toolbar: re-ranks `ranking` over `catalogue` and lays it out.
    /// Catalogue items named in `pinned` lead, in catalogue order; a pinned name the
    /// catalogue lacks is skipped, so a reserved pin appears once its item joins.
    /// Unused items keep catalogue order, so the first unpinned catalogue items are
    /// the default slots.
    public static func open(_ catalogue: [Item], pinned: Set<Item>, ranking: inout FrecencyRanker<Item>, at date: Date = .now) -> Self {
        ranking.refresh(candidates: catalogue.filter { !pinned.contains($0) },
                        pinned: catalogue.filter(pinned.contains), at: date)
        let ranked = ranking.rankedItems
        return Self(pinned: ranking.pinnedItems,
                    slots: Array(ranked.prefix(slotCount)),
                    overflow: Array(ranked.dropFirst(slotCount)),
                    ranked: ranked)
    }

    /// Arming an overflow item shows it in place of the last slot until the next
    /// `open`; the item it displaces returns to the overflow in rank order. Pinned
    /// and slotted items are already visible and change nothing.
    public mutating func show(_ item: Item) {
        guard overflow.contains(item), !slots.isEmpty else { return }
        slots[slots.count - 1] = item
        overflow = ranked.filter { !slots.contains($0) }
    }
}
