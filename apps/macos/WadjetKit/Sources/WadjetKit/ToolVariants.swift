/// One of a Markup Tool's variants: its menu tile, a step scroll cycles to,
/// and the toolbar icon while it's armed.
public struct ToolVariant: Equatable, Sendable {
    /// the name config.json stores at `markup.tools.<tool>.variant`
    public let id: String
    public let title: String
    /// SF Symbol
    public let symbol: String
    public init(id: String, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

extension ToolID {
    /// the Tool's variants in menu and scroll order; empty when it has none.
    /// A Tool gains variants here, and scroll and the toolbar icon follow.
    public var variants: [ToolVariant] {
        switch self {
        case .eraser: EraserVariant.allCases.map(\.variant)
        case .draw: DrawVariant.allCases.map(\.variant)
        case .shapes: ShapeVariant.allCases.map(\.variant)
        case .censor: CensorMethod.methods.map(\.variant)
        case .freezeRegion: FreezeVariant.allCases.map(\.variant)
        default: []
        }
    }
}

extension WadjetConfig.Markup {
    /// the Tool's armed variant — what new Annotations draw with: Censor's
    /// method, else `tools.<tool>.variant`, else the first; nil without variants
    public func armedVariant(of tool: ToolID) -> ToolVariant? {
        if tool == .censor { return (tools["censor"]?.censorMethod ?? .blackOut).variant }
        let variants = tool.variants
        return variants.first { $0.id == tools[tool.rawValue]?.variant } ?? variants.first
    }

    /// arms the variant `step` places from the armed one, wrapping at both
    /// ends. Writes only the Tool's default, never a selected Annotation.
    public mutating func cycleVariant(of tool: ToolID, by step: Int) {
        let all = tool.variants
        guard let armed = armedVariant(of: tool), let i = all.firstIndex(of: armed) else { return }
        let next = all[((i + step) % all.count + all.count) % all.count]
        guard next != armed else { return }
        if tool == .censor {
            // Censor stores a method (with its strength), not a variant name
            tools["censor", default: WadjetConfig.MarkupTool()].censorMethod =
                CensorMethod.methods.first { $0.variant == next }
        } else {
            tools[tool.rawValue, default: WadjetConfig.MarkupTool()].variant = next.id
        }
    }
}
