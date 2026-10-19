import Foundation
import Testing
import WadjetKit

struct FrecencyRankerTests {
    // Proves an edited config cannot load a half-life that breaks ranking arithmetic.
    @Test(arguments: [0, -1])
    func rejectsInvalidPersistedHalfLife(halfLife: Int) {
        let json = """
        {"halfLife":\(halfLife),"pinnedItems":[],"rankedItems":[],"usage":{}}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FrecencyRanker<String>.self, from: Data(json.utf8))
        }
    }

    // Proves repeated use wins at equal age, and recent use can beat old frequency.
    @Test(arguments: [0.0, 30.0])
    func frequencyAndRecency(age: TimeInterval) {
        let start = Date(timeIntervalSince1970: 0)
        var ranker = FrecencyRanker<String>(halfLife: 10)
        ranker.recordUse(of: "brush", at: start)
        ranker.recordUse(of: "brush", at: start)
        ranker.recordUse(of: "text", at: start.addingTimeInterval(age))
        ranker.refresh(candidates: ["unused", "text", "brush"], at: start.addingTimeInterval(age))
        #expect(ranker.rankedItems == (age == 0 ? ["brush", "text", "unused"] : ["text", "brush", "unused"]))
    }

    // Proves usage never moves an open toolbar, and pins cannot consume ranked slots.
    @Test func refreshAndPins() {
        let now = Date(timeIntervalSince1970: 0)
        var ranker = FrecencyRanker<String>()
        ranker.refresh(candidates: ["shape", "brush", "text", "select", "brush"], pinned: ["select", "eraser"], at: now)
        ranker.recordUse(of: "text", at: now)
        ranker.recordUse(of: "eraser", at: now)
        #expect(ranker.rankedItems == ["shape", "brush", "text"])
        #expect(ranker.pinnedItems == ["select", "eraser"])
        ranker.refresh(candidates: ["shape", "brush", "text", "eraser", "select"], pinned: ["select", "eraser"], at: now)
        #expect(ranker.rankedItems == ["text", "shape", "brush"])
        #expect(ranker.pinnedItems == ["select", "eraser"])
    }

    // Proves config persistence preserves both the visible snapshot and pending uses.
    @Test func persistence() throws {
        let now = Date(timeIntervalSince1970: 100)
        var original = FrecencyRanker<String>()
        original.refresh(candidates: ["Monaco", "New York"], pinned: ["Noteworthy"], at: now)
        original.recordUse(of: "New York", at: now)
        var restored = try JSONDecoder().decode(FrecencyRanker<String>.self, from: JSONEncoder().encode(original))
        #expect(restored.rankedItems == ["Monaco", "New York"])
        #expect(restored.pinnedItems == ["Noteworthy"])
        restored.refresh(candidates: ["Monaco", "New York"], pinned: ["Noteworthy"], at: now)
        #expect(restored.rankedItems == ["New York", "Monaco"])
    }
}
