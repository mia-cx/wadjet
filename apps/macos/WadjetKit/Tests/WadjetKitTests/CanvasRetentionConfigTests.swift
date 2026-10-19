import Foundation
import Testing
import WadjetKit

struct CanvasRetentionConfigTests {
    // Proves old and partially written configs keep each unspecified deadline,
    // and never-delete plus customized stages survive a config save/reload.
    @Test(arguments: ["{}", #"{"canvasRetention":{}}"#,
        #"{"canvasRetention":{"deleteAfterDays":0}}"#])
    func defaultsAndRoundTrip(json: String) throws {
        var config = try JSONDecoder().decode(WadjetConfig.self, from: Data(json.utf8))
        #expect(config.canvasRetention.sdrAfterDays == 7)
        #expect(config.canvasRetention.dropUnusedDisplaysAfterDays == 30)
        #expect(config.canvasRetention.deleteAfterDays == (json.contains("deleteAfterDays") ? 0 : 90))
        config.canvasRetention.sdrAfterDays = 1
        config.canvasRetention.dropUnusedDisplaysAfterDays = 2
        config.canvasRetention.deleteAfterDays = 0
        let reopened = try JSONDecoder().decode(WadjetConfig.self, from: JSONEncoder().encode(config))
        #expect(reopened == config)
        #expect(reopened.canvasRetention.settings == .init(daysUntilSDRAndLossyHEIC: 1,
            daysUntilDroppingUnusedDisplays: 2, daysUntilDeletion: 0))
    }

    // Proves an invalid hand edit is rejected before it can reach the policy.
    @Test(arguments: ["sdrAfterDays", "dropUnusedDisplaysAfterDays", "deleteAfterDays"])
    func rejectsNegativeDays(key: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WadjetConfig.self,
                from: Data("{\"canvasRetention\":{\"\(key)\":-1}}".utf8))
        }
    }
}
