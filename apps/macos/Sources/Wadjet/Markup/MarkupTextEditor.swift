import AppKit
import CoreText
import WadjetKit

/// The in-place editor for a Text Annotation: a borderless TextKit 1
/// NSTextView laid exactly over the Annotation's box, so committing changes
/// nothing visually. While it lives, the canvas layer draws the pill only.
final class TextEditorView: NSTextView {
    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?

    /// its own UndoManager on every host — typed undo never lands in the
    /// Editor document's stack (or the screen's LayerHistory)
    private lazy var ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }

    init() {
        // the container variant is the designated init — it constructs the
        // TextKit 1 stack (NSTextStorage/NSLayoutManager), which matches
        // CoreText's word wrapping and line metrics
        super.init(frame: .zero, textContainer: nil)
        isRichText = false
        drawsBackground = false
        allowsUndo = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// the face the text is committed in: font, colour, alignment, opacity,
    /// insets, wrap width — everything but the string, so the caret stays put
    func configure(layout: TextLayout, style: AnnotationStyle) {
        let c = style.colour
        let colour = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch layout.data.format.alignment {
        case .left: .left; case .centre: .center; case .right: .right
        }
        paragraph.minimumLineHeight = layout.lineHeight
        paragraph.maximumLineHeight = layout.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let font = layout.font as NSFont
        self.font = font
        textColor = colour
        insertionPointColor = colour
        alphaValue = CGFloat(style.opacity)
        textContainerInset = layout.padding
        typingAttributes = [
            .font: font,
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
        ]
        defaultParagraphStyle = paragraph
        // 1 pt of slack so TextKit never wraps a line CoreText didn't
        textContainer?.containerSize = NSSize(
            width: (layout.data.width ?? layout.textSize.width) + 1, height: 1e7)
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?(string)
    }

    /// Escape commits
    override func cancelOperation(_ sender: Any?) { onCommit?() }

    /// wadjet is an accessory app: the main menu's edit items don't reach the
    /// panel, so the editor takes its own shortcuts
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), e.charactersIgnoringModifiers?.count == 1 else {
            return super.performKeyEquivalent(with: e)
        }
        switch e.charactersIgnoringModifiers!.lowercased() {
        case "x": cut(nil); return true
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        case "z":
            if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            return true
        default:
            return super.performKeyEquivalent(with: e)
        }
    }
}

/// the canvas layer for a text Annotation: its frame covers the (possibly
/// rotated) box, and draw(in:) renders through the shared WadjetKit routine —
/// glyphs only while no editor is showing them
final class TextAnnotationLayer: CALayer {
    private(set) var annotation: Annotation?
    private(set) var editing = false
    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// updates frame/flag and redraws only when the contents changed
    func show(_ a: Annotation, editing: Bool, scale: CGFloat) {
        let changed = a != annotation || editing != self.editing || contentsScale != scale
        annotation = a
        self.editing = editing
        contentsScale = scale
        let cs = a.frameCorners
        let xs = cs.map(\.x), ys = cs.map(\.y)
        frame = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                       width: (xs.max() ?? 0) - (xs.min() ?? 0),
                       height: (ys.max() ?? 0) - (ys.min() ?? 0))
            .insetBy(dx: -2, dy: -2)
        if changed { needsDisplay() }
    }

    /// the Annotation's data lives in global points; the layer's bounds
    /// origin is its own frame, so shift by the frame's origin
    override func draw(in ctx: CGContext) {
        guard let annotation else { return }
        ctx.translateBy(x: -frame.origin.x, y: -frame.origin.y)
        TextLayout.draw(annotation, in: ctx, text: !editing)
    }
}

extension MarkupController {
    /// the view the editor attaches to and the box's frame in that view's
    /// coordinates: a screen panel converts from global screen space; an
    /// Editor's surface shows Canvas points offset by its canvas bounds
    /// origin, magnified by the scroll view along with everything inside it
    private func editorHost(for box: CGRect) -> (view: NSView, frame: NSRect)? {
        if isScreen {
            guard let panel = panel(containing: box.origin) else { return nil }
            return (panel.view, panel.convertFromScreen(box))
        }
        guard let surface else { return nil }
        let o = surface.canvas.bounds.origin
        return (surface, NSRect(x: box.minX - o.x, y: box.minY - o.y,
                                width: box.width, height: box.height))
    }

    /// puts the editor over the Annotation's box on the host whose region
    /// holds the box's origin, and takes key focus for it
    func startEditing(_ id: Annotation.ID) {
        guard let a = stack.annotations.first(where: { $0.id == id }),
              case let .text(data) = a.kind,
              let host = editorHost(for: TextLayout(data).box) else { return }
        // a placed box's session start is captured where it's placed —
        // re-editing an existing text starts the undo window here
        if textEditStart == nil { textEditStart = stack }
        let tv = TextEditorView()
        tv.onChange = { [weak self] s in self?.editorTextChanged(s) }
        tv.onCommit = { [weak self] in self?.commitEditing() }
        host.view.addSubview(tv)
        editor = tv
        setEditing(id)
        // selecting it too lets the style and format seams restyle the box
        // being typed
        setSelection(id)
        syncEditor()
        tv.string = data.string
        host.view.window?.makeKey()
        host.view.window?.makeFirstResponder(tv)
        if isScreen { AppDelegate.shared?.updateEscHotkey() }
        AppLog.line("markup: editing text")
    }

    /// the editor's final say: the string lands in the stack, an empty or
    /// whitespace-only string drops the Annotation instead
    @discardableResult
    func commitEditing() -> Bool {
        guard let id = editing else { return false }
        let tv = editor
        tv?.removeFromSuperview()
        editor = nil
        setEditing(nil)
        var kept = false
        if var a = stack.annotations.first(where: { $0.id == id }),
           case var .text(d) = a.kind {
            d.string = tv?.string ?? d.string
            a.kind = .text(d)
            kept = !d.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            mutateUnrecorded { s in
                s.replace(a)
                if !kept { s.remove(id: id) }
            }
        }
        // the whole session becomes one undo step — nothing for a dropped box
        recordTextEdit()
        // the selection only makes sense to Select once editing ends
        setSelection(armed == .select && kept ? id : nil)
        render()
        if isScreen { AppDelegate.shared?.updateEscHotkey() }
        AppLog.line("markup: committed text")
        return true
    }

    /// re-syncs the editor's face and frame from the stack Annotation —
    /// never writes the string, so the caret stays put
    func syncEditor() {
        guard let id = editing, let tv = editor,
              let a = stack.annotations.first(where: { $0.id == id }),
              case let .text(data) = a.kind else { return }
        let layout = TextLayout(data)
        tv.configure(layout: layout, style: a.style)
        tv.frameCenterRotation = 0
        var frame = layout.box
        frame.size.width += 1 // the container's slack, in the frame likewise
        tv.frame = editorHost(for: frame)?.frame ?? frame
        // flips are ignored while editing
        tv.frameCenterRotation = a.transform.rotation * 180 / .pi
    }

    /// every keystroke lands in the stack; render() re-syncs the frame as
    /// the layout grows
    private func editorTextChanged(_ s: String) {
        guard let id = editing, var a = stack.annotations.first(where: { $0.id == id }),
              case var .text(d) = a.kind else { return }
        d.string = s
        a.kind = .text(d)
        mutateUnrecorded { $0.replace(a) }
    }
}
