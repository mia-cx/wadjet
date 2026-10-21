import AppKit
import SwiftUI
import WadjetKit

extension ToolMenuView {
    /// the Markup group's settings live in Select's menu
    @ViewBuilder func markupGroupRows() -> some View {
        divider()
        clearAfterScreenshotRow()
        row("Peer Through", icon: "circle.dashed", on: s.config.value.markup.peerThrough, isToggle: true) {
            s.config.update { $0.markup.peerThrough.toggle() }
        }
        row("Snapping", icon: "square.and.line.vertical.and.square", on: s.config.value.markup.snapping, isToggle: true) {
            s.config.update { $0.markup.snapping.toggle() }
        }
        if s.config.value.markup.snapping { SnapRangeRow() }
    }

    func clearAfterScreenshotRow() -> some View {
        row("Clear After Screenshot", icon: "trash", on: s.config.value.markup.clearAfterScreenshot, isToggle: true) {
            s.config.update { $0.markup.clearAfterScreenshot.toggle() }
        }
    }
}

/// the Snapping range row — MarkupStyleControls.sliderRow's metrics, but it
/// writes markup.snapRange only when the slider's editing ends
struct SnapRangeRow: View {
    @ObservedObject var s = AppState.shared
    @State var v: Double = 6

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler").font(.system(size: 15))
                .foregroundStyle(.white).frame(width: 22)
            Slider(value: $v, in: 1...20, step: 1) { e in
                if !e { s.config.update { $0.markup.snapRange = CGFloat(v) } }
            }
            .tint(.wadjetAccent)
            .controlSize(.small)
            .accessibilityLabel("Snapping range")
            Text("\(Int(v)) pt").font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5)).frame(width: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, 14)
        .onAppear { v = s.config.value.markup.snapRange }
    }
}
