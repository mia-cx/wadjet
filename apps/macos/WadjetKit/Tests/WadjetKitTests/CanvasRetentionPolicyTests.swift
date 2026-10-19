import Foundation
import Testing
import WadjetKit

struct CanvasRetentionPolicyTests {
    struct StageFixture: Sendable {
        var age: TimeInterval
        var state: CanvasRetentionState = []
        var settings: CanvasRetentionSettings = .init()
        var expected: [CanvasRetentionAction]
    }

    // Proves exact stage boundaries, configurable stages, never-delete, and no repeated irreversible work.
    @Test(arguments: [
        StageFixture(age: -1, expected: []),
        StageFixture(age: 604_799, expected: []),
        StageFixture(age: 604_800, expected: [.convertToSDR, .reencodeLossyHEIC]),
        StageFixture(age: 2_591_999, state: [.sdr, .lossyHEIC], expected: []),
        StageFixture(age: 2_592_000, state: [.sdr, .lossyHEIC], expected: [.dropUnusedDisplays]),
        StageFixture(age: 7_775_999, state: [.sdr, .lossyHEIC, .unusedDisplaysDropped], expected: []),
        StageFixture(age: 7_776_000, expected: [.delete]),
        StageFixture(age: 604_800, state: [.sdr], expected: [.reencodeLossyHEIC]),
        StageFixture(age: 604_800, state: [.lossyHEIC], expected: [.convertToSDR]),
        StageFixture(age: 604_800, state: [.sdr, .lossyHEIC, .unusedDisplaysDropped], expected: []),
        StageFixture(age: 86_400_000, settings: .init(daysUntilDeletion: 0),
                     expected: [.convertToSDR, .reencodeLossyHEIC, .dropUnusedDisplays]),
        StageFixture(age: 86_400_000, state: [.sdr, .lossyHEIC, .unusedDisplaysDropped],
                     settings: .init(daysUntilDeletion: 0), expected: []),
        StageFixture(age: 86_400, settings: .init(daysUntilSDRAndLossyHEIC: 1,
                     daysUntilDroppingUnusedDisplays: 2, daysUntilDeletion: 3),
                     expected: [.convertToSDR, .reencodeLossyHEIC]),
        StageFixture(age: 172_800, state: [.sdr, .lossyHEIC],
                     settings: .init(daysUntilSDRAndLossyHEIC: 1,
                     daysUntilDroppingUnusedDisplays: 2, daysUntilDeletion: 3), expected: [.dropUnusedDisplays]),
        StageFixture(age: 259_200, settings: .init(daysUntilSDRAndLossyHEIC: 1,
                     daysUntilDroppingUnusedDisplays: 2, daysUntilDeletion: 3), expected: [.delete]),
        StageFixture(age: 0, settings: .init(daysUntilSDRAndLossyHEIC: 0,
                     daysUntilDroppingUnusedDisplays: 0, daysUntilDeletion: 0),
                     expected: [.convertToSDR, .reencodeLossyHEIC, .dropUnusedDisplays]),
    ])
    func stages(fixture: StageFixture) {
        let creation = Date(timeIntervalSince1970: 1_000_000)
        let now = creation.addingTimeInterval(fixture.age)
        let id = UUID()
        let decisions = CanvasRetentionPolicy(now: { now }).actionsDue(for: [
            .init(id: id, createdAt: creation, state: fixture.state),
        ], settings: fixture.settings)
        #expect(decisions.flatMap(\.actions) == fixture.expected)
        #expect(decisions.map(\.canvasID) == (fixture.expected.isEmpty ? [] : [id]))
    }

    // Proves the newest transitive host controls degradation, with no restoration of older degraded content.
    @Test func newestHostPropagatesThroughChains() {
        let old = Date(timeIntervalSince1970: 0)
        let middle = old.addingTimeInterval(100 * 86_400)
        let newest = old.addingTimeInterval(200 * 86_400)
        let target = UUID(), bridge = UUID(), olderHost = UUID(), newestHost = UUID()
        let records: [CanvasRetentionRecord] = [
            .init(id: target, createdAt: old, state: [.sdr]),
            .init(id: bridge, createdAt: old, linkedCanvasIDs: [target]),
            .init(id: olderHost, createdAt: middle, linkedCanvasIDs: [target]),
            .init(id: newestHost, createdAt: newest, linkedCanvasIDs: [bridge]),
        ]
        #expect(CanvasRetentionPolicy(now: { newest }).actionsDue(for: records).map(\.canvasID) == [olderHost])
        let atSeven = newest.addingTimeInterval(7 * 86_400)
        let decisions = CanvasRetentionPolicy(now: { atSeven }).actionsDue(for: records)
        #expect(decisions.map(\.canvasID) == [target, bridge, olderHost, newestHost])
        #expect(decisions.map(\.actions) == [
            [.reencodeLossyHEIC], [.convertToSDR, .reencodeLossyHEIC],
            [.delete], [.convertToSDR, .reencodeLossyHEIC],
        ])
        #expect(CanvasRetentionPolicy(now: { atSeven }).actionsDue(for: records.reversed()) == decisions.reversed())
    }

    // Proves links hold an old target until its host is actually removed, and missing/self links do not keep it alive.
    @Test func existingLinksPreventDeletion() throws {
        let created = Date(timeIntervalSince1970: 0)
        let now = created.addingTimeInterval(100 * 86_400)
        let host = UUID(), target = UUID(), missing = UUID()
        let policy = CanvasRetentionPolicy(now: { now })
        let targetRecord = CanvasRetentionRecord(id: target, createdAt: created,
            state: [.sdr, .lossyHEIC, .unusedDisplaysDropped], linkedCanvasIDs: [target, missing])
        let records = [CanvasRetentionRecord(id: host, createdAt: created, linkedCanvasIDs: [target]), targetRecord]
        #expect(policy.actionsDue(for: records).map(\.canvasID) == [host])
        #expect(policy.actionsDue(for: records).flatMap(\.actions) == [.delete])
        let orphan = try #require(policy.actionsDue(for: [targetRecord]).first)
        #expect(orphan.canvasID == target)
        #expect(orphan.actions == [.delete])
    }

    // Proves cycles terminate and retain their members, while Save file Canvases receive no actions at any age.
    @Test func cyclesAndSaveFileProtection() {
        let old = Date(timeIntervalSince1970: 0)
        let now = old.addingTimeInterval(1_000 * 86_400)
        let saved = UUID(), a = UUID(), b = UUID()
        let records: [CanvasRetentionRecord] = [
            .init(id: saved, createdAt: old, keptBySaveFile: true, linkedCanvasIDs: [a]),
            .init(id: a, createdAt: old, linkedCanvasIDs: [b]),
            .init(id: b, createdAt: now, linkedCanvasIDs: [a]),
        ]
        #expect(CanvasRetentionPolicy(now: { now }).actionsDue(for: records).isEmpty)
        #expect(CanvasRetentionPolicy(now: { now }).actionsDue(for: [records[0]]).isEmpty)
        #expect(CanvasRetentionPolicy(now: { now }).actionsDue(for: []).isEmpty)
    }
}
