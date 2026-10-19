import Foundation

extension WadjetConfig {
    /// The Markup group's settings. `clearAfterScreenshot` clears every
    /// Annotation once a Screenshot's file is written; off keeps them on screen.
    public struct Markup: Codable, Equatable, Sendable {
        public var clearAfterScreenshot = false
        public init() {}
        public init(from decoder: Decoder) throws {
            clearAfterScreenshot = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(Bool.self, forKey: .clearAfterScreenshot) ?? false
        }
    }
}
