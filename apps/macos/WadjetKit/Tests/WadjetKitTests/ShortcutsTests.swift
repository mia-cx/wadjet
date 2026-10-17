import Testing
import Foundation
import WadjetKit

@MainActor
struct ShortcutsTests {
    @Test(arguments: [
        ("cmd+shift+2", 19, 0x100 | 0x200),   // kVK_ANSI_2
        ("ctrl+opt+r", 15, 0x1000 | 0x800),   // kVK_ANSI_R
        ("cmd+f5", 96, 0x100),                // kVK_F5
        ("shift+space", 49, 0x200),           // kVK_Space
        ("cmd+shift+4", 21, 0x300),           // kVK_ANSI_4
        ("command+option+control+1", 18, 0x100 | 0x800 | 0x1000), // aliases
        ("f8", 100, 0),                       // f-keys need no modifier
        ("cmd+escape", 53, 0x100),
        ("opt+left", 123, 0x800),
        ("CMD+SHIFT+5", 23, 0x300),           // case-insensitive
    ])
    func keyComboParses(_ s: String, code: Int, mods: Int) {
        let c = KeyCombo(s)
        #expect(c?.keyCode == code && c?.carbonModifiers == mods)
    }

    @Test(arguments: [
        ("cmd+shift+2", "shift+cmd+2"),       // canonical order: ctrl opt shift cmd
        ("ctrl+opt+r", "ctrl+opt+r"),
        ("f8", "f8"),
        ("shift+space", "shift+space"),
    ])
    func descriptionRoundTrips(_ s: String, _ canonical: String) {
        let c = KeyCombo(s)
        #expect(c?.description == canonical)
        #expect(KeyCombo(canonical) == c)
    }

    @Test(arguments: ["", "9", "nope", "cmd+shift", "shift+cmd+q+extra", "cmd+nope"])
    func invalidCombosRejected(_ s: String) {
        #expect(KeyCombo(s) == nil)
    }

    @Test func shortcutDecodesWithAndWithoutOptions() throws {
        let json = #"""
        {"keys":"ctrl+opt+cmd+9","tool":"pickColour"}
        """#
        let a = try JSONDecoder().decode(Shortcut.self, from: Data(json.utf8))
        #expect(a.keys.keyCode == 25) // kVK_ANSI_9
        #expect(a.tool == .pickColour)
        #expect(a.workflow == nil)
        #expect(a.options.countdown == nil)

        let b = try JSONDecoder().decode(Shortcut.self, from: Data(#"{"keys":"cmd+f5","tool":"captureRegion","workflow":"Screenshot","options":{"countdown":3,"cursor":false}}"#.utf8))
        #expect(b.workflow == "Screenshot")
        #expect(b.options.countdown == 3 && b.options.cursor == false)
        // invalid combo string -> dataCorrupted naming it
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(KeyCombo.self, from: Data(#""wat""#.utf8)) }
    }

    @Test func defaultConfigHasNoShortcuts() {
        let c = WadjetConfig()
        #expect(c.shortcuts.isEmpty)
        #expect(c.defaultWorkflows.screenshot == "Screenshot")
        #expect(c.defaultWorkflows.recording == "MP4")
    }

    @Test func shortcutNamingMissingWorkflowFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcuts":[{"keys":"cmd+opt+1","tool":"captureRegion","workflow":"Nope"}]}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        let err = try #require(errors.first)
        #expect(err.location == "shortcuts.0.workflow")
        #expect(err.message.contains(#"no Screenshot Workflow named "Nope""#))
    }

    // a pre-#24 config with renamed workflows and no defaultWorkflows still loads
    @Test func legacyConfigWithoutDefaultWorkflowsLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"workflows":[{"name":"Clipboard","takes":"screenshot","steps":[{"type":"copyImage"}]},{"name":"Video","takes":"mp4","steps":[{"type":"showToast"}]}],"tools":{"pickColour":{"format":"lab()"}}}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        #expect(errors.isEmpty)
        #expect(store.value.defaultWorkflows.screenshot == "Clipboard")
        #expect(store.value.defaultWorkflows.recording == "Video")
        #expect(store.value.tools.pickColour.format == .lab) // unrelated keys kept
    }

    // an explicitly dangling defaultWorkflows name still errors
    @Test func danglingDefaultWorkflowNameFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"defaultWorkflows":{"screenshot":"Nope"},"workflows":[{"name":"Clipboard","takes":"screenshot","steps":[{"type":"copyImage"}]}]}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        #expect(errors.first?.location == "defaultWorkflows.screenshot")
        #expect(errors.first?.message.contains(#"no Screenshot Workflow named "Nope""#) == true)
    }

    // a file that sets one kind's default leaves the other to fall back
    @Test func partialDefaultWorkflowsFallBackPerKind() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"defaultWorkflows":{"screenshot":"Clipboard"},"workflows":[{"name":"Clipboard","takes":"screenshot","steps":[{"type":"copyImage"}]},{"name":"Video","takes":"mp4","steps":[{"type":"showToast"}]}]}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        #expect(errors.isEmpty)
        #expect(store.value.defaultWorkflows.screenshot == "Clipboard")
        #expect(store.value.defaultWorkflows.recording == "Video") // injected name fell back
    }

    // even the factory name must error when the file sets it explicitly
    @Test func explicitFactoryNameStillFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"defaultWorkflows":{"screenshot":"Screenshot","recording":"Video"},"workflows":[{"name":"Clipboard","takes":"screenshot","steps":[{"type":"copyImage"}]}]}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        #expect(errors.first?.location == "defaultWorkflows.screenshot")
    }

    @Test func recordingToolNamingScreenshotWorkflowFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"shortcuts":[{"keys":"cmd+opt+2","tool":"recordRegion","workflow":"Screenshot"}]}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        let err = try #require(errors.first)
        #expect(err.location == "shortcuts.0.workflow")
        #expect(err.message.contains(#"no Recording Workflow named "Screenshot""#))
    }
}
