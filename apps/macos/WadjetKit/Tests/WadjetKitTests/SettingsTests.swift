import Testing
import Foundation
import WadjetKit

@MainActor
struct SettingsTests {
    @Test func bookmarksRoundTripThroughConfigStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { _ in }
        #expect(store.value.bookmarks.isEmpty) // absent key decodes to empty

        let mark = Data([0xde, 0xad, 0xbe, 0xef])
        store.update { $0.bookmarks["~/Desktop/Shots"] = mark }
        #expect(store.value.bookmarks["~/Desktop/Shots"] == mark)
        // base64 blob in the file
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(mark.base64EncodedString()))
        // a fresh store reads it back
        let again = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { _ in }
        #expect(again.value.bookmarks["~/Desktop/Shots"] == mark)
    }

    @Test func renameWorkflowUpdatesReferences() {
        var c = WadjetConfig()
        c.shortcuts = [Shortcut(keys: KeyCombo("cmd+1")!, tool: .captureRegion, workflow: "Screenshot")]
        c.renameWorkflow(from: "Screenshot", to: "Shot")
        #expect(c.workflows[0].name == "Shot")
        #expect(c.shortcuts[0].workflow == "Shot")
        #expect(c.defaultWorkflows.screenshot == "Shot")
        #expect(c.defaultWorkflows.recording == "MP4")
    }

    @Test func markupGroupSettingsDefaultAndRoundTrip() throws {
        let c = try JSONDecoder().decode(WadjetConfig.self, from: Data("{}".utf8))
        #expect(c.markup.clearAfterScreenshot == false)
        #expect(c.markup.peerThrough == true)
        #expect(c.markup.snapping == true)
        #expect(c.markup.snapRange == 6)

        var on = WadjetConfig()
        on.markup.clearAfterScreenshot = true
        on.markup.peerThrough = false
        on.markup.snapping = false
        on.markup.snapRange = 10
        let back = try JSONDecoder().decode(WadjetConfig.self, from: JSONEncoder().encode(on))
        #expect(back.markup.clearAfterScreenshot == true)
        #expect(back.markup.peerThrough == false)
        #expect(back.markup.snapping == false)
        #expect(back.markup.snapRange == 10)
    }

    // Proves the colour history stays bounded: the best-ranked colours survive
    // the cap and the oldest single-use colours drop first.
    @Test func recentColourLimitPrunesOldest() {
        let t0 = Date(timeIntervalSince1970: 0)
        var markup = WadjetConfig.Markup()
        for _ in 0 ..< 5 { markup.recordColour("#000000", at: t0) }
        for i in 1 ... 30 {
            markup.recordColour(String(format: "#%06X", i), at: t0.addingTimeInterval(TimeInterval(i) * 3600))
        }
        let used = markup.recentColours.usedItems
        #expect(used.count == WadjetConfig.Markup.recentColourLimit)
        #expect(used.contains("#000000"))
        #expect(used.contains(String(format: "#%06X", 30)))
        for i in 1 ... 7 { #expect(!used.contains(String(format: "#%06X", i))) }
    }

    @Test func stepsAllowedPerKind() {
        let mp4 = Step.allowed(for: .mp4).map(\.title)
        let shot = Step.allowed(for: .screenshot).map(\.title)
        #expect(!mp4.contains("Copy image") && !mp4.contains("Pin to screen"))
        #expect(shot.contains("Copy image") && shot.contains("Pin to screen"))
        #expect(mp4.count == 4 && shot.count == 6)
    }
}
