import Testing
import Foundation
import WadjetKit

final class FakeKeychain: Keychain {
    var items: [String: String] = [:]
    func save(_ secret: String, account: String) throws { items[account] = secret }
}

/// Polls until `condition` holds or 5 s pass; returns false on timeout.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
}

@MainActor
struct ConfigStoreTests {
    @Test func retentionDaysDefaultsToSevenAndRejectsZero() throws {
        let minimal = try JSONDecoder().decode(WadjetConfig.self, from: Data("{}".utf8))
        #expect(minimal.retentionDays == 7)

        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"retentionDays":0}"#.utf8).write(to: url)
        var errors: [ConfigError] = []
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        #expect(errors.count == 1)
        #expect(errors[0].location == "retentionDays")
        #expect(errors[0].message.contains("at least 1"))
    }

    @Test func savedConfigSurvivesReload() {
        let url = tempFile()
        let a = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        a.update { $0.tools.pickColour.format = .oklch }
        a.update { $0.tools.measure.mode = .vertical }
        let b = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        #expect(b.value.tools.pickColour.format == .oklch)
        #expect(b.value.tools.measure.mode == .vertical)
    }

    // atomic: editor replaces the file (vim); in-place: it truncates and writes (VS Code, >)
    @Test(arguments: [true, false])
    func outsideEditIsPickedUp(atomic: Bool) async throws {
        let url = tempFile()
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        let data = Data(#"{"tools":{"pickColour":{"format":"lab()"}}}"#.utf8)
        try data.write(to: url, options: atomic ? .atomic : [])
        #expect(await eventually { store.value.tools.pickColour.format == .lab })
        #expect(store.value.tools.measure.mode == .spacing) // missing key keeps the default
    }

    @Test(arguments: [
        (content: #"{"tools": "#, location: nil, part: "line"),
        (content: #"{"tools":{"pickColour":{"format":"Purple"}}}"#, location: "tools.pickColour.format", part: nil),
    ] as [(content: String, location: String?, part: String?)])
    func badEditKeepsLastGoodValue(bad content: String, location: String?, part: String?) async throws {
        let url = tempFile()
        var errors: [ConfigError] = []
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        store.update { $0.tools.pickColour.format = .hsl }
        try Data(content.utf8).write(to: url, options: .atomic)
        #expect(await eventually { !errors.isEmpty })
        let error = try #require(errors.first)
        #expect(error.file == url)
        #expect(error.location == location)
        if let part { #expect(error.message.contains(part)) }
        #expect(store.value.tools.pickColour.format == .hsl)
        #expect(try Data(contentsOf: url) == Data(content.utf8)) // never clobber a half-finished edit
    }

    // an outside edit the watcher hasn't delivered yet must not be overwritten
    // by the next update() — update() reads the file first when it changed
    @Test func updateRightAfterOutsideEditKeepsTheEdit() throws {
        let url = tempFile()
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        try Data(#"{"tools":{"pickColour":{"format":"lab()"}}}"#.utf8).write(to: url, options: .atomic)
        store.update { $0.tools.measure.mode = .vertical }
        #expect(store.value.tools.pickColour.format == .lab)
        #expect(store.value.tools.measure.mode == .vertical)
        let reloaded = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        #expect(reloaded.value.tools.pickColour.format == .lab)
        #expect(reloaded.value.tools.measure.mode == .vertical)
    }

    // a half-written outside edit blocks the write instead of being clobbered
    @Test func updateRightAfterBrokenEditLeavesTheFile() throws {
        let url = tempFile()
        var errors: [ConfigError] = []
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { errors.append($0) }
        let broken = Data(#"{"tools": "#.utf8)
        try broken.write(to: url, options: .atomic)
        store.update { $0.tools.measure.mode = .vertical }
        #expect(try Data(contentsOf: url) == broken)
        #expect(!errors.isEmpty)
        #expect(store.value.tools.measure.mode == .vertical) // in-memory change still applies
    }

    // the initial load normalizes: a file missing newer keys gains them
    @Test func firstLoadAddsMissingKeys() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tools":{"pickColour":{"format":"lab()"}}}"#.utf8).write(to: url)
        _ = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["folders"] != nil)
        #expect(obj?["workflows"] != nil)
        #expect((obj?["tools"] as? [String: Any])?["pickColour"] != nil) // her values kept
    }

    // once running, a live edit is never rewritten — odd formatting stays
    @Test func liveEditKeepsItsBytes() async throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"folders":{}}"#.utf8).write(to: url)
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        let written = Data(#"{ "tools" : { "measure" : { "mode" : "Vertical" } } }"#.utf8)
        try written.write(to: url, options: .atomic)
        #expect(await eventually { store.value.tools.measure.mode == .vertical })
        #expect(try Data(contentsOf: url) == written) // the file she just saved is untouched
    }

    // a key this version doesn't model survives normalize AND later writes
    @Test func unknownKeysSurvive() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"future":{"x":1},"tools":{"pickColour":{"format":"lab()"}}}"#.utf8).write(to: url)
        let store = ConfigStore(file: url, defaults: WadjetConfig(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["future"] != nil && obj?["folders"] != nil) // first load wrote both
        store.update { $0.tools.measure.mode = .vertical }
        obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["future"] != nil) // our own writes keep it too
    }

    // clearing a nested optional inside a modelled section stays cleared
    @Test func clearedNestedOptionalStaysGone() throws {
        struct Cfg: Codable, Equatable, Sendable {
            var tools = Tools()
            struct Tools: Codable, Equatable, Sendable { var token: String? = nil }
        }
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tools":{"token":"abc"},"future":7}"#.utf8).write(to: url)
        let store = ConfigStore(file: url, defaults: Cfg(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        store.update { $0.tools.token = nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("abc") && !text.contains("\"token\""))
        #expect(text.contains("future")) // unknown top-level keys still kept
        let reloaded = ConfigStore(file: url, defaults: Cfg(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        #expect(reloaded.value.tools.token == nil)
    }

    @Test func plaintextSecretLeavesForTheKeychain() throws {
        struct Vault: Codable, Equatable, Sendable { var token: Secret? = nil }
        let url = tempFile()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"token": "hunter2"}"#.utf8).write(to: url)
        let fake = FakeKeychain()
        let store = ConfigStore(file: url, defaults: Vault(), keychain: fake) { Issue.record("unexpected error: \($0)") }
        let account = try #require(store.value.token?.account)
        #expect(fake.items == [account: "hunter2"])
        let file = try String(contentsOf: url, encoding: .utf8)
        #expect(!file.contains("hunter2"))
        let parsed = try JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any]
        #expect(parsed?["token"] as? [String: String] == ["keychain": account])
        // clearing the optional must remove it, not resurrect the raw key
        store.update { $0.token = nil }
        let cleared = try String(contentsOf: url, encoding: .utf8)
        #expect(!cleared.contains("hunter2") && !cleared.contains("\"token\""))
        let reloaded = ConfigStore(file: url, defaults: Vault(), keychain: FakeKeychain()) { Issue.record("unexpected error: \($0)") }
        #expect(reloaded.value.token == nil)
    }
}
