import Foundation

extension WadjetConfig {
    /// History Canvas deadlines in elapsed days. Deletion at zero means never;
    /// the other stages run immediately at zero. Partial sections keep defaults.
    public struct CanvasRetention: Codable, Equatable, Sendable {
        public var sdrAfterDays = 7
        public var dropUnusedDisplaysAfterDays = 30
        public var deleteAfterDays = 90

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sdrAfterDays = try c.decodeIfPresent(Int.self, forKey: .sdrAfterDays) ?? 7
            dropUnusedDisplaysAfterDays = try c.decodeIfPresent(Int.self, forKey: .dropUnusedDisplaysAfterDays) ?? 30
            deleteAfterDays = try c.decodeIfPresent(Int.self, forKey: .deleteAfterDays) ?? 90
            for (key, days) in [(CodingKeys.sdrAfterDays, sdrAfterDays),
                (.dropUnusedDisplaysAfterDays, dropUnusedDisplaysAfterDays), (.deleteAfterDays, deleteAfterDays)] {
                guard days >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c,
                        debugDescription: "Canvas retention days must be at least 0")
                }
            }
        }

        /// Settings passed to each sweep, read afresh from the live config.
        public var settings: CanvasRetentionSettings {
            .init(daysUntilSDRAndLossyHEIC: sdrAfterDays,
                daysUntilDroppingUnusedDisplays: dropUnusedDisplaysAfterDays, daysUntilDeletion: deleteAfterDays)
        }

        private enum CodingKeys: String, CodingKey {
            case sdrAfterDays, dropUnusedDisplaysAfterDays, deleteAfterDays
        }
    }
}
