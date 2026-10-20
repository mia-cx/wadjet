import Testing
import Foundation
@testable import WadjetKit

struct MarkupToolKeyTests {
    // Proves the mapping: each letter finds its Tool and variant, and Caps
    // Lock's uppercase finds the same key; a letter that arms nothing is nil.
    @Test(arguments: [
        ("v" as Character, nil, nil),
        ("e", "eraser", "eraser"),
        ("k", "eraser", "knife"),
        ("l", "draw", "line"),
        ("p", "draw", "pen"),
        ("b", "draw", "brush"),
        ("h", "draw", "highlighter"),
        ("t", "text", nil),
        ("r", "shapes", "rectangle"),
        ("o", "shapes", "ellipse"),
        ("n", "counter", nil),
        ("c", "censor", nil),
        ("m", "magnify", nil),
        ("f", "freezeRegion", nil),
    ])
    func mapping(character: Character, tool: String?, variant: String?) {
        let key = MarkupToolKey.key(typing: character)
        #expect(key?.tool?.rawValue == tool)
        #expect(key?.variant?.id == variant)
        #expect(MarkupToolKey.key(typing: Character(character.uppercased())) == key)
    }

    @Test func unmappedIsNil() {
        // Proves a letter outside the table arms nothing.
        #expect(MarkupToolKey.key(typing: "q") == nil)
    }

    // Proves a key's variant arms what the toolbar icon shows: the Tool
    // declares it, and `arm` makes it the armed one.
    @Test func armsVariant() {
        for key in MarkupToolKey.all where key.variant != nil {
            let tool = key.tool!
            let variant = key.variant!
            #expect(tool.variants.contains(variant))
            var markup = WadjetConfig.Markup()
            markup.arm(variant, of: tool)
            #expect(markup.armedVariant(of: tool) == variant)
        }
    }

    // Proves the table is unambiguous: no letter or (tool, variant) pair
    // repeats, and every letter is one lowercase ASCII letter.
    @Test func noDuplicates() {
        #expect(Set(MarkupToolKey.all.map(\.character)).count == MarkupToolKey.all.count)
        #expect(Set(MarkupToolKey.all.map { "\($0.tool?.rawValue ?? "select"):\($0.variant?.id ?? "-")" })
                    .count == MarkupToolKey.all.count)
        for key in MarkupToolKey.all {
            #expect(String(key.character) == key.character.lowercased())
            #expect(key.character.isASCII && key.character.isLetter)
        }
    }

    // Proves a key press arms a Tool only unmodified and typing one
    // character: ⌘V stays paste, ⇧V types a capital, a dead key arms nothing.
    @Test(arguments: [
        ("v" as String?, false, "v" as Character?),
        ("V", false, "v"),
        ("v", true, nil),
        ("q", false, nil),
        ("", false, nil),
        (nil, false, nil),
        ("vv", false, nil),
    ])
    func pressed(characters: String?, modified: Bool, want: Character?) {
        #expect(MarkupToolKey.key(pressed: characters, modified: modified)?.character == want)
    }
}
