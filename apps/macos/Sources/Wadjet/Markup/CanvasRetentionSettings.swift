import SwiftUI
import WadjetKit

/// History's Canvas deadlines, using the same live config as external edits.
@MainActor struct CanvasRetentionRows: View {
    var body: some View {
        Section("History Canvases") {
            days("Convert to SDR and lossy HEIC after", key: \.sdrAfterDays)
            days("Drop unused displays after", key: \.dropUnusedDisplaysAfterDays)
            days("Delete after", key: \.deleteAfterDays, never: true)
        }
    }

    private func days(_ title: String, key: WritableKeyPath<WadjetConfig.CanvasRetention, Int>,
                      never: Bool = false) -> some View {
        let config = AppState.shared.config
        let value = config.value.canvasRetention[keyPath: key]
        let binding = Binding(get: { config.value.canvasRetention[keyPath: key] }, set: { days in
            config.update { $0.canvasRetention[keyPath: key] = days }
        })
        return LabeledContent(title) {
            Stepper(value: binding, in: 0...Int.max) {
                Text(never && value == 0 ? "Never" : value == 1 ? "1 day" : "\(value) days")
                    .monospacedDigit()
            }
            .accessibilityLabel(title)
        }
    }
}
