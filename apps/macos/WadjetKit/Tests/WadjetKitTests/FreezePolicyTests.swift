import Foundation
import Testing
import WadjetKit

struct FreezePolicyTests {
    struct Fixture: Sendable {
        var use: FreezePolicy.Use
        var recording: Bool
        var freeze: Bool = true
        var freezeWhileRecording: Bool? = nil
        var shortcutFreeze: Bool? = nil
        var shortcutFreezeWhileRecording: Bool? = nil
        var expected: Bool
    }

    // Each row names which layer decided it.
    @Test(arguments: [
        Fixture(use: .capture, recording: false, expected: true), // global default
        Fixture(use: .capture, recording: false, freeze: false, expected: false), // global off
        Fixture(use: .capture, recording: false, freezeWhileRecording: false, expected: true), // while-recording sleeps outside a Recording
        Fixture(use: .capture, recording: true, expected: true), // while-recording inherits global
        Fixture(use: .capture, recording: true, freezeWhileRecording: false, expected: false), // while-recording overrides global
        Fixture(use: .capture, recording: true, freeze: false, freezeWhileRecording: true, expected: true),
        Fixture(use: .capture, recording: true, freezeWhileRecording: false, shortcutFreeze: true, expected: true), // Shortcut overrides while-recording
        Fixture(use: .capture, recording: false, shortcutFreeze: false, expected: false), // Shortcut overrides global
        Fixture(use: .capture, recording: true, freezeWhileRecording: false, shortcutFreeze: true, shortcutFreezeWhileRecording: false, expected: false), // Shortcut while-recording overrides all
        Fixture(use: .capture, recording: false, freeze: false, shortcutFreezeWhileRecording: true, expected: false), // Shortcut while-recording sleeps outside a Recording
        Fixture(use: .markup, recording: false, expected: true), // Markup freezes outside a Recording
        Fixture(use: .markup, recording: true, expected: false), // Markup draws live during a Recording by default
        Fixture(use: .markup, recording: true, freezeWhileRecording: true, expected: true), // explicit while-recording beats the Markup default
        Fixture(use: .markup, recording: true, freeze: false, shortcutFreeze: true, expected: true), // Shortcut beats the Markup default
        Fixture(use: .utility, recording: true, freeze: false, freezeWhileRecording: false, shortcutFreeze: false, shortcutFreezeWhileRecording: false, expected: true), // Utilities always freeze
    ])
    func layers(fixture f: Fixture) {
        var capture = WadjetConfig.Capture()
        capture.freeze = f.freeze
        capture.freezeWhileRecording = f.freezeWhileRecording
        let shortcut = ShortcutOptions(freeze: f.shortcutFreeze, freezeWhileRecording: f.shortcutFreezeWhileRecording)
        #expect(FreezePolicy.resolve(f.use, recording: f.recording, capture: capture, shortcut: shortcut) == f.expected)
    }

    // Proves the most specific set layer wins in every combination.
    @Test func everyCombination() {
        for use in [FreezePolicy.Use.utility, .markup, .capture] {
            for recording in [false, true] {
                for g in [false, true] {
                    for gWR in [Bool?.none, true, false] {
                        for sc in [Bool?.none, true, false] {
                            for scWR in [Bool?.none, true, false] {
                                var capture = WadjetConfig.Capture()
                                capture.freeze = g
                                capture.freezeWhileRecording = gWR
                                let shortcut = ShortcutOptions(freeze: sc, freezeWhileRecording: scWR)
                                let expected = use == .utility ? true
                                    : ((recording ? scWR : nil) ?? sc
                                        ?? (recording ? (gWR ?? (use == .markup ? false : nil)) : nil) ?? g)
                                #expect(FreezePolicy.resolve(use, recording: recording, capture: capture, shortcut: shortcut) == expected)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func configRoundTrip() throws {
        // an old config without the new keys decodes to inherit
        let old = try JSONDecoder().decode(WadjetConfig.self, from: Data("""
            {"capture":{"freeze":false},"shortcuts":[{"keys":"cmd+1","tool":"draw"}]}
            """.utf8))
        #expect(old.capture.freeze == false)
        #expect(old.capture.freezeWhileRecording == nil)
        #expect(old.shortcuts[0].options.freeze == nil)
        #expect(old.shortcuts[0].options.freezeWhileRecording == nil)

        var cfg = old
        cfg.capture.freezeWhileRecording = true
        cfg.shortcuts[0].options.freeze = false
        cfg.shortcuts[0].options.freezeWhileRecording = true
        let back = try JSONDecoder().decode(WadjetConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back.capture.freezeWhileRecording == true)
        #expect(back.shortcuts[0].options.freeze == false)
        #expect(back.shortcuts[0].options.freezeWhileRecording == true)

        // inherit stays out of the file
        let json = String(decoding: try JSONEncoder().encode(WadjetConfig()), as: UTF8.self)
        #expect(!json.contains("freezeWhileRecording"))
    }
}
