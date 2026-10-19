import Foundation

extension WadjetConfig {
    /// The Markup group's settings. `clearAfterScreenshot` clears every
    /// Annotation once a Screenshot's file is written; off keeps them on screen.
    /// `peerThrough` shows what's beneath an Annotation through a feathered
    /// circle under the pointer while nothing is armed. `snapping` aligns
    /// drawing, moving, and resizing with windows, displays, and other
    /// Annotations within `snapRange` points.
    /// `tools` holds per-Tool settings keyed by the Markup Tool's raw name
    /// ("draw", "text"); `recentColours` ranks the colours used in Markup for
    /// the colour control's swatches (hex "#RRGGBB"); `recentFonts` the font
    /// families picked in Text for the font list's recent section;
    /// `toolRanking` ranks Markup Tools by raw name for the toolbar's
    /// shortlist (and the menu bar's last Markup Tool).
    public struct Markup: Codable, Equatable, Sendable {
        public var clearAfterScreenshot = false
        public var peerThrough = true
        public var snapping = true
        public var snapRange: CGFloat = 6
        public var tools: [String: MarkupTool] = [:]
        public var recentColours = FrecencyRanker<String>()
        public var toolRanking = FrecencyRanker<String>()
        public var recentFonts = FrecencyRanker<String>()
        /// the colour history's bound — enough recents to pick from, no hoarding
        public static let recentColourLimit = 24
        /// the Text Tool's default format — the last font picked etc.
        public var textFormat: TextFormat {
            get { tools["text"]?.textFormat ?? .default }
            set { tools["text", default: MarkupTool()].textFormat = newValue }
        }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clearAfterScreenshot = try c.decodeIfPresent(Bool.self, forKey: .clearAfterScreenshot) ?? false
            peerThrough = try c.decodeIfPresent(Bool.self, forKey: .peerThrough) ?? true
            snapping = try c.decodeIfPresent(Bool.self, forKey: .snapping) ?? true
            snapRange = try c.decodeIfPresent(CGFloat.self, forKey: .snapRange) ?? 6
            tools = try c.decodeIfPresent([String: MarkupTool].self, forKey: .tools) ?? [:]
            recentColours = try c.decodeIfPresent(FrecencyRanker<String>.self, forKey: .recentColours) ?? FrecencyRanker()
            toolRanking = try c.decodeIfPresent(FrecencyRanker<String>.self, forKey: .toolRanking) ?? FrecencyRanker()
            recentFonts = try c.decodeIfPresent(FrecencyRanker<String>.self, forKey: .recentFonts) ?? FrecencyRanker()
        }
        /// records a colour use; the history keeps the `recentColourLimit` best-ranked colours
        public mutating func recordColour(_ hex: String, at date: Date = .now) {
            recentColours.recordUse(of: hex, at: date)
            recentColours.prune(keeping: Self.recentColourLimit, at: date)
        }
    }
    /// one Markup Tool's settings; later slices add theirs (Line ends…) here.
    /// Shapes also reads `shapes.variant` and each variant's `shape`; Step
    /// counter reads `counter.format` and `counter.size`; `textFormat` is
    /// Text's type default.
    public struct MarkupTool: Codable, Equatable, Sendable {
        /// nil until the user restyles the Tool; the app then uses the Tool's built-in default
        public var style: AnnotationStyle?
        /// the Tool's last-picked variant — a ShapeVariant for Shapes at
        /// `markup.tools.shapes.variant`, a Draw variant ("line"/"pen"/…)
        /// for Draw
        public var variant: String?
        /// a Shapes variant's option, at `markup.tools.<variant>.shape`
        public var shape: ShapeKind?
        /// Censor's default method for new Annotations; nil = .blackOut
        public var censorMethod: CensorMethod?
        /// Step counter: numbers or letters, at `markup.tools.counter.format`
        public var format: CounterFormat?
        /// Step counter: the circle's diameter in points, at
        /// `markup.tools.counter.size`; Eraser: its diameter, at `markup.tools.eraser.size`
        public var size: CGFloat?
        /// Magnify's default options for new Annotations, at
        /// `markup.tools.magnify.magnifier`; nil = the stock magnifier
        public var magnifier: MagnifierOptions?
        /// Censor: the categories Smart Redact blacks out, at `markup.tools.censor.smartRedact`; nil = every category
        public var smartRedact: Set<SmartRedactCategory>?
        /// Brush variants' Smoothing, 0…1; nil = the default
        public var smoothing: Double?
        /// Text's default format; nil until it changes, then the app uses .default
        public var textFormat: TextFormat?
        public init(style: AnnotationStyle? = nil, variant: String? = nil, shape: ShapeKind? = nil,
                    censorMethod: CensorMethod? = nil, format: CounterFormat? = nil, size: CGFloat? = nil,
                    magnifier: MagnifierOptions? = nil, smartRedact: Set<SmartRedactCategory>? = nil,
                    smoothing: Double? = nil, textFormat: TextFormat? = nil) {
            self.style = style
            self.variant = variant
            self.shape = shape
            self.censorMethod = censorMethod
            self.format = format
            self.size = size
            self.magnifier = magnifier
            self.smartRedact = smartRedact
            self.smoothing = smoothing
            self.textFormat = textFormat
        }
    }
}
