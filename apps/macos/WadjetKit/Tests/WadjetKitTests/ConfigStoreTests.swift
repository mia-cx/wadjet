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
    }
}
