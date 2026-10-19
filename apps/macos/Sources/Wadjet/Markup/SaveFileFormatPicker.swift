import SwiftUI
import WadjetKit

/// Save format belongs to the Step, so one Workflow can keep both an image and a Canvas.
@MainActor
struct SaveFileFormatPicker: View {
    let workflow: Int
    let step: Int
    let folder: String?
    let format: SaveFileFormat

    var body: some View {
        Picker("Format", selection: Binding(get: { format }, set: { value in
            AppState.shared.config.update { $0.workflows[workflow].steps[step] = .saveFile(folder: folder, format: value) }
        })) {
            Text("Image").tag(SaveFileFormat.image)
            Text("Canvas").tag(SaveFileFormat.canvas)
        }
    }
}
