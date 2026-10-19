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
        guard let selected else { self = .armed(armed); return }
        let tool: ToolID? = switch selected {
        case .line, .path: .draw
        case .censor: .censor
        case .shape: .shapes
        case .counter: .counter
        case .magnify: .magnify
        case .text: .text
        case .window, .image, .canvas: nil
        }
        self = .selected(tool)
    }

    /// the Tool whose controls the menu shows; nil means Select's
    public var tool: ToolID? { switch self { case let .armed(t), let .selected(t): t } }
}
