/// Whose options a Markup Tool menu shows and edits. A selected Annotation's
/// own kind wins over the armed Tool, so any Tool's menu (Select's included)
/// edits a selected Magnify's shape or a Censor's blur radius; with nothing
/// selected the menu sets the armed Tool's defaults for new Annotations.
public enum MarkupMenuSubject: Equatable, Sendable {
    /// nothing is selected: the armed Tool's defaults; nil while Select is armed
    case armed(ToolID?)
    /// an Annotation is selected: its kind's Tool; nil for kinds no Tool draws
    /// (images, windows, nested Canvases), which keep Select's controls
    case selected(ToolID?)

    public init(armed: ToolID?, selected: AnnotationKind?) {
        self.init(armed: armed, selected: selected.map { [$0] } ?? [])
    }

    /// several selected Annotations show their shared kind's Tool when every
    /// one maps to the same Tool (two Lines and a Pen path are all Draw's);
    /// mixed kinds fall back to Select's controls, which only edit the style
    /// they all have
    public init(armed: ToolID?, selected: [AnnotationKind]) {
        guard let first = selected.first else { self = .armed(armed); return }
        let tools = selected.map(Self.tool(for:))
        self = .selected(tools.allSatisfy { $0 == tools[0] } ? Self.tool(for: first) : nil)
    }

    /// the Tool that draws `kind`; nil for kinds no Tool draws (images,
    /// windows, nested Canvases), which keep Select's controls
    static func tool(for kind: AnnotationKind) -> ToolID? {
        switch kind {
        case .line, .path: .draw
        case .censor: .censor
        case .shape: .shapes
        case .counter: .counter
        case .magnify: .magnify
        case .text: .text
        case .window, .image, .canvas: nil
        }
    }

    /// the Tool whose controls the menu shows; nil means Select's
    public var tool: ToolID? { switch self { case let .armed(t), let .selected(t): t } }
}
