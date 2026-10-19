import CoreGraphics
import CoreText
import Foundation

/// Resolves Text's family names and weights to CTFonts, and slices the
/// installed family list into the menu's pinned / recent / all sections.
public enum TextFonts {
    /// the menu's name for the system font (no "SF Pro" family is installed)
    public static let system = "SF Pro"
    public static let pinned = ["Noteworthy", system, "Monaco"]
    public static let recentCount = 10

    /// the font Text draws with. A missing family falls back to the system
    /// font at that weight; the saved family name stays as-is.
    public static func font(family: String, weight: TextWeight, size: CGFloat) -> CTFont {
        if family == system {
            let base = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithFontDescriptor(
                    CTFontDescriptorCreateWithAttributes([:] as CFDictionary), size, nil)
            var attrs = (CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(base))
                as? [CFString: Any]) ?? [:]
            var traits = (attrs[kCTFontTraitsAttribute] as? [CFString: Any]) ?? [:]
            traits[kCTFontWeightTrait] = weight.trait
            attrs[kCTFontTraitsAttribute] = traits
            return CTFontCreateWithFontDescriptor(
                CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        }
        guard let best = member(of: family, nearestTo: weight) else {
            return font(family: system, weight: weight, size: size)
        }
        return CTFontCreateWithFontDescriptor(best, size, nil)
    }

    /// the weights `family` actually ships, light→heavy; all nine for the
    /// system font, empty for a missing family
    public static func weights(of family: String) -> [TextWeight] {
        if family == system { return TextWeight.allCases }
        return Set(members(of: family).compactMap { d -> TextWeight? in
            guard let w = weightTrait(of: d) else { return nil }
            return TextWeight.nearest(w)
        }).sorted { $0.trait < $1.trait }
    }

    /// the family's non-italic member descriptors
    static func members(of family: String) -> [CTFontDescriptor] {
        let query = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary)
        let members = CTFontDescriptorCreateMatchingFontDescriptors(query, nil)
            as? [CTFontDescriptor] ?? []
        return members.filter {
            (symbolicTraits(of: $0) & CTFontSymbolicTraits.italicTrait.rawValue) == 0
        }
    }

    static func symbolicTraits(of d: CTFontDescriptor) -> UInt32 {
        (traits(of: d)?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
    }
    static func weightTrait(of d: CTFontDescriptor) -> CGFloat? {
        guard let n = traits(of: d)?[kCTFontWeightTrait] as? NSNumber else { return nil }
        return CGFloat(n.doubleValue)
    }
    static func traits(of d: CTFontDescriptor) -> [CFString: Any]? {
        (CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any])
    }

    /// the member nearest `weight`'s trait; ties go heavier
    static func member(of family: String, nearestTo weight: TextWeight) -> CTFontDescriptor? {
        members(of: family).min { a, b in
            let da = abs((weightTrait(of: a) ?? 0) - weight.trait)
            let db = abs((weightTrait(of: b) ?? 0) - weight.trait)
            return da == db ? (weightTrait(of: a) ?? 0) > (weightTrait(of: b) ?? 0) : da < db
        }
    }

    /// the menu's three sections; no family appears twice
    public struct Sections: Equatable, Sendable {
        public var pinned: [String]
        public var recent: [String]
        public var all: [String]
    }

    /// `installed` is the family's name list (NSFontManager's); `recent` has
    /// already been refreshed with `refresh(candidates: usedItems, pinned: pinned)`
    public static func sections(installed: [String], recent: FrecencyRanker<String>) -> Sections {
        let installedSet = Set(installed)
        let pinned = TextFonts.pinned
        let recentItems = recent.rankedItems
            .filter { installedSet.contains($0) && !pinned.contains($0) }
            .prefix(recentCount)
        let recentSet = Set(recentItems)
        let all = installed
            .filter { !$0.hasPrefix(".") && !pinned.contains($0) && !recentSet.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Sections(pinned: pinned, recent: Array(recentItems), all: all)
    }
}
