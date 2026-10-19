import Testing
import Foundation
@testable import WadjetKit

struct ToolVariantTests {
    // Proves scroll cycling: a fresh config arms the first variant, `by: 1`
    // walks the declared order and wraps to it, `by: -1` arms the last.
    @Test(arguments: [
        (ToolID.draw, ["line", "pen", "brush", "highlighter"]),
        (.shapes, ["rectangle", "ellipse", "polygon", "star"]),
        (.censor, ["blackOut", "blur", "pixelate"]),
        (.eraser, ["eraser", "knife"]),
    ])
    func cycling(tool: ToolID, ids: [String]) {
        var markup = WadjetConfig.Markup()
        #expect(markup.armedVariant(of: tool)?.id == ids[0])
        var visited: [String] = []
        for _ in 0..<ids.count {
            markup.cycleVariant(of: tool, by: 1)
            visited.append(markup.armedVariant(of: tool)!.id)
        }
        #expect(visited == Array(ids.dropFirst()) + [ids[0]])
        var fresh = WadjetConfig.Markup()
        fresh.cycleVariant(of: tool, by: -1)
        #expect(fresh.armedVariant(of: tool)?.id == ids.last)
    }

    // Proves the toolbar icon tells variants apart: every variant has a
    // symbol, and no two of a Tool's variants share one.
    @Test(arguments: [ToolID.draw, .shapes, .censor, .eraser])
    func symbols(tool: ToolID) {
        let symbols = tool.variants.map(\.symbol)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == symbols.count)
    }

    // Proves Censor cycles methods: each step writes `censorMethod`, and a
    // tuned strength survives a full lap because nothing gets written then.
    @Test func censorCycling() {
        var markup = WadjetConfig.Markup()
        markup.cycleVariant(of: .censor, by: 1)
        #expect(markup.tools["censor"]?.censorMethod == .defaultBlur)
        markup.cycleVariant(of: .censor, by: 1)
        #expect(markup.tools["censor"]?.censorMethod == .defaultPixelate)
        markup.tools["censor"]?.censorMethod = .blur(radius: 30)
        markup.cycleVariant(of: .censor, by: 3)
        #expect(markup.tools["censor"]?.censorMethod == .blur(radius: 30))
    }
}
