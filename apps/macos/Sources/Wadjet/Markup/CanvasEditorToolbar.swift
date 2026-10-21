import SwiftUI
import WadjetKit

/// The Editor window's root: the AppKit canvas scroll view under the floating
/// Markup toolbar.
struct CanvasEditorRoot: View {
    let doc: CanvasEditorDocument
    let state: EditorState
    let scroll: NSScrollView

    var body: some View {
        ZStack(alignment: .top) {
            CanvasScrollRepresentable(scroll: scroll)
            CanvasEditorToolbar(doc: doc, state: state)
                .padding(.top, 12)
        }
        .ignoresSafeArea()
    }
}

/// hands the window's existing NSScrollView to SwiftUI
struct CanvasScrollRepresentable: NSViewRepresentable {
    let scroll: NSScrollView
    func makeNSView(context: Context) -> NSScrollView { scroll }
    func updateNSView(_ v: NSScrollView, context: Context) {}
}

/// The Editor's floating capsule: every Markup Tool, then the Recrop toggle
/// and — while cropping — the Corner Radius slider. Screen-only rows
/// (More, Clear After Screenshot, Peer Through) don't apply here.
struct CanvasEditorToolbar: View {
    let doc: CanvasEditorDocument
    let state: EditorState
    /// the armed Tool whose menu is up, as a popover off its cell
    @State var menuTool: Tool? = nil
    /// the slider's drag-start value — the undo step's before
    @State var radiusStart: CGFloat = 0
    /// bumped by each Clear with nothing to clear — the Clear cell shakes
    @State var clearRefusals = 0

    var markup: MarkupController { doc.markup }
    /// the screen toolbar's catalogue without More (its menu arms screen
    /// Tools) or Freeze region (it picks on the screen's Freeze Frame only)
    var tools: [Tool] { Tool.allCases.filter { $0.kind == .markup && $0 != .moreMarkup && $0 != .freezeRegion } }
    var maxRadius: Double { Double(doc.canvas.maxCornerRadius) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tools, id: \.self) { t in
                cell(t)
            }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 0.5, height: 36)
                .padding(.horizontal, 4)
            Button { toggleRecrop() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "crop").font(.system(size: 20))
                    Text("Recrop").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(state.recrop ? Color.wadjetAccent : .white)
                .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Recrop")
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(state.recrop ? "On" : "Off")
            if state.recrop {
                Slider(value: radiusBinding, in: 0...max(1, maxRadius)) { editing in
                    if editing {
                        radiusStart = state.radius
                    } else if state.radius != radiusStart {
                        doc.setCrop(state.crop, cornerRadius: state.radius,
                                    undoingTo: (state.crop, radiusStart))
                    }
                }
                .tint(.wadjetAccent)
                .frame(width: 140)
                .padding(.horizontal, 12)
                .accessibilityLabel("Corner Radius")
            }
        }
        .padding(6)
        // dark glass like the screen toolbar — white labels wash out in light mode
        .environment(\.colorScheme, .dark)
        .glassEffect(.regular, in: Capsule())
        .popover(isPresented: Binding(
            get: { menuTool != nil },
            set: { if !$0 { menuTool = nil } }), arrowEdge: .bottom) {
            if let t = menuTool {
                ToolMenuView(tool: t, ctrl: AppDelegate.shared!.overlayCtrl, editor: true)
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    /// live corner-radius edits land in state; the drag's end commits one undo step
    var radiusBinding: Binding<Double> {
        Binding(get: { Double(state.radius) },
                set: { state.radius = CGFloat($0); state.wc?.canvasView?.cropChanged() })
    }

    func toggleRecrop() {
        state.recrop.toggle()
        state.wc?.canvasView?.rebuild()
        state.wc?.zoomToFit(nil)
    }

    func cell(_ t: Tool) -> some View {
        let armed = markup.armed == t
        return Button {
            if t.isAction {
                // the Annotations fade out, then clear as one undo step
                if markup.fadeOutThenClear() == .nothingToClear { clearRefusals += 1 }
            } else if armed {
                if t.hasMenu { menuTool = t }
            } else {
                markup.arm(t)
                MarkupToolbar.shared.armed(t)
            }
        } label: {
            VStack(spacing: 4) {
                t.iconImage.scaledToFit().frame(width: 24, height: 24)
                Text(t.shortTitle).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(armed ? Color.wadjetAccent : .white)
            .frame(width: 64, height: 64)
            .modifier(NothingToClearCue(refusals: t.isAction ? clearRefusals : 0))
            // colour icons can't take the accent, so an accent ring marks the armed Tool
            .background {
                if armed {
                    RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.wadjetAccent, lineWidth: 1.5))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(state.recrop)
        .opacity(state.recrop ? 0.35 : 1)
        .accessibilityLabel(t.title)
        .accessibilityAddTraits(armed ? .isSelected : [])
    }
}
