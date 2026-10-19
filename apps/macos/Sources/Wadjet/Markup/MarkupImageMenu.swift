import SwiftUI
import WadjetKit

/// the Tool menu's controls while an image-kind Annotation is selected:
/// opacity and corner radius sliders, then the border — Auto's difference
/// hairline, a colour, or None
struct ImageStyleControls: View {
    let tool: Tool
    let ctrl: OverlayController
    var styles: MarkupStyles { .shared }
    @State var opacity: Double = 0
    @State var radius: Double = 0
    /// a slider is mid-drag — re-seeding then would fight the user's thumb
    @State var editing = false

    var style: AnnotationStyle { styles.style(for: tool) }
    var placement: ImagePlacement? { MarkupController.active.selected?.placement }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuSliderRow(icon: "circle.lefthalf.filled", label: "Opacity",
                          text: "\(Int((opacity * 100).rounded()))%",
                          value: $opacity, range: 0.1...1, step: 0.05, editing: $editing) {
                styles.restyle(tool) { $0.opacity = opacity }
            }
            MenuSliderRow(icon: "app", label: "Corner radius", text: "\(Int(radius)) pt",
                          value: $radius, range: 0...64, step: 1, editing: $editing) {
                MarkupController.active.updateSelectedPlacement { $0.cornerRadius = CGFloat(radius) }
            }
            // a "Border" section like ToolMenuView's: divider + header + rows
            Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5)
                .padding(.horizontal, 20).padding(.vertical, 3)
            Text("Border").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            MarkupColourRow(tool: tool, target: .stroke, ctrl: ctrl)
            MenuRow(title: "Auto", icon: "circle.lefthalf.filled", on: placement?.border == .difference) {
                MarkupController.active.updateSelectedPlacement { $0.border = .difference }
            }
            MenuRow(title: "None", icon: "circle.slash", on: placement?.border == .hidden) {
                MarkupController.active.updateSelectedPlacement { $0.border = .hidden }
            }
        }
        .onAppear {
            styles.refreshSwatches()
            opacity = style.opacity
            radius = Double(placement?.cornerRadius ?? 0)
        }
        // the selection can change under an open menu — follow it unless a
        // slider is mid-drag
        .onChange(of: style) { _, st in
            guard !editing else { return }
            opacity = st.opacity
        }
        .onChange(of: placement?.cornerRadius) { _, r in
            guard !editing else { return }
            radius = Double(r ?? 0)
        }
    }
}
