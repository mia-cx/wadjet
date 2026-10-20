/// A Markup Tool Key: one unmodified letter that arms a Markup Tool or one of
/// its variants, like design apps. `all` is the one table the screen's key
/// monitor, the Editor's keyDown, and Settings › Shortcuts read.
public struct MarkupToolKey: Equatable, Sendable {
    /// lowercase; means wherever the current keyboard layout types it
    public let character: Character
    /// nil is Select, which has no ToolID because no Shortcut can name it
    public let tool: ToolID?
    /// the variant it arms; nil keeps the Tool's armed one (Censor's method,
    /// Freeze region's variant)
    public let variant: ToolVariant?

    private init(_ character: Character, _ tool: ToolID?, _ variant: ToolVariant?) {
        self.character = character
        self.tool = tool
        self.variant = variant
    }

    public static let all: [MarkupToolKey] = [
        .init("v", nil, nil),
        .init("a", .directSelect, nil),
        .init("e", .eraser, EraserVariant.eraser.variant),
        .init("k", .eraser, EraserVariant.knife.variant),
        .init("l", .draw, DrawVariant.line.variant),
        .init("p", .draw, DrawVariant.pen.variant),
        .init("b", .draw, DrawVariant.brush.variant),
        .init("h", .draw, DrawVariant.highlighter.variant),
        .init("t", .text, nil),
        .init("r", .shapes, ShapeVariant.rectangle.variant),
        .init("o", .shapes, ShapeVariant.ellipse.variant),
        .init("n", .counter, nil),
        .init("c", .censor, nil),
        .init("m", .magnify, nil),
        .init("f", .freezeRegion, nil),
    ]

    /// the key `character` types, any case (Caps Lock types uppercase); nil
    /// when it arms nothing
    public static func key(typing character: Character) -> MarkupToolKey? {
        all.first { $0.character == Character(character.lowercased()) }
    }

    /// the key a key press arms: `characters` is the event's
    /// charactersIgnoringModifiers (so the current layout decides), `modified`
    /// whether ⌘, ⌥, ⌃, or ⇧ was held. A held modifier, or a press typing
    /// more or less than one character, arms nothing.
    public static func key(pressed characters: String?, modified: Bool) -> MarkupToolKey? {
        guard !modified, let characters, characters.count == 1, let c = characters.first else { return nil }
        return key(typing: c)
    }
}
