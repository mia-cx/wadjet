import Foundation
import WadjetKit

/// Runs History maintenance off the main thread, shortly after launch and
/// every elapsed day. Each run takes the latest live config; runs never overlap.
@MainActor final class CanvasRetentionRunner {
    static let shared = CanvasRetentionRunner()
    private var timer: Timer?
    private var running = false

    func start(store: CanvasStore) {
        guard timer == nil else { return }
        let timer = Timer(fire: Date().addingTimeInterval(5), interval: 86_400, repeats: true) { _ in
            Task { @MainActor in await self.sweep(store: store) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sweep(store: CanvasStore) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let settings = AppState.shared.config.value.canvasRetention.settings
        do {
            let decisions = try await Task.detached(priority: .background) {
                try await store.sweep(settings: settings)
            }.value
            func count(_ action: CanvasRetentionAction) -> Int {
                decisions.filter { $0.actions.contains(action) }.count
            }
            AppLog.line("Canvas sweep: SDR=\(count(.convertToSDR)) lossy=\(count(.reencodeLossyHEIC)) drop-unused-displays=\(count(.dropUnusedDisplays)) deleted=\(count(.delete))")
        } catch {
            AppLog.line("Canvas sweep failed: \(error.localizedDescription)")
        }
    }
}
