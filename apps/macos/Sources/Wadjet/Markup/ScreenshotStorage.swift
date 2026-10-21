import Foundation
import WadjetKit

extension AppDelegate {
    /// The screenshots folder from config: Canvases in original/, Save file images in flattened/.
    var screenshotFolders: ScreenshotFolders {
        ScreenshotFolders(root: expandingTilde(AppState.shared.config.value.folders.screenshots))
    }

    /// Where History kept Canvases before they moved to original/.
    static var legacyCanvasesDir: URL {
        historyURL.deletingLastPathComponent().appendingPathComponent("Canvases", isDirectory: true)
    }

    /// Moves container Canvases into original/ (a no-op once they're gone),
    /// then starts retention, so the first sweep sees every Canvas in its new home.
    /// Runs after the folder bookmarks resolve, so a custom folder is reachable.
    func startCanvasStorage() {
        let store = canvasStore, legacy = Self.legacyCanvasesDir
        Task { @MainActor in
            let outcome = await Task.detached(priority: .utility) {
                Result { try store.migrate(from: legacy) }
            }.value
            switch outcome {
            case let .success(report) where !report.moved.isEmpty || report.relinked > 0 || !report.failures.isEmpty:
                AppLog.line("Canvas migration: moved \(report.moved.count) into \(store.directory.path), relinked \(report.relinked), failed \(report.failures.count)")
                for move in report.moved {
                    AppLog.line("Canvas migration: \(move.from.lastPathComponent) -> \(move.to.lastPathComponent)")
                }
                for failure in report.failures { AppLog.line("Canvas migration: \(failure)") }
            case .success: break
            case let .failure(error):
                AppLog.line("Canvas migration failed, retrying next launch: \(error.localizedDescription)")
            }
            CanvasRetentionRunner.shared.start { self.canvasStore }
        }
    }
}
