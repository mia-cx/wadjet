import Foundation

extension WadjetConfig {
    /// The Markup group's settings. `clearAfterScreenshot` clears every
    /// Annotation once a Screenshot's file is written; off keeps them on screen.
    /// `tools` holds per-Tool settings keyed by the Markup Tool's raw name
    /// ("draw"); `recentColours` ranks the colours used in Markup for the
    /// colour control's swatches (hex "#RRGGBB").
    public struct Markup: Codable, Equatable, Sendable {
        public var clearAfterScreenshot = false
        public var tools: [String: MarkupTool] = [:]
        public var recentColours = FrecencyRanker<String>()
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clearAfterScreenshot = try c.decodeIfPresent(Bool.self, forKey: .clearAfterScreenshot) ?? false
            tools = try c.decodeIfPresent([String: MarkupTool].self, forKey: .tools) ?? [:]
            recentColours = try c.decodeIfPresent(FrecencyRanker<String>.self, forKey: .recentColours) ?? FrecencyRanker()
        }
    }
    /// one Markup Tool's settings; later slices add theirs (Line ends, Text font…) here.
    /// Shapes also reads `shapes.variant` and each variant's `shape`.
    public struct MarkupTool: Codable, Equatable, Sendable {
        /// nil until the user restyles the Tool; the app then uses the Tool's built-in default
        public var style: AnnotationStyle?
        /// Shapes: the variant it draws, at `markup.tools.shapes.variant`
        public var variant: ShapeVariant?
        /// a Shapes variant's option, at `markup.tools.<variant>.shape`
        public var shape: ShapeKind?
        public init(style: AnnotationStyle? = nil, variant: ShapeVariant? = nil, shape: ShapeKind? = nil) {
            self.style = style
            self.variant = variant
            self.shape = shape
        }
    }
}
