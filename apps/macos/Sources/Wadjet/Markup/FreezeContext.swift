import WadjetKit

/// The press that opened a Freeze Frame session: whether a Recording ran and which Shortcut, if any.
/// Every Tool the session switches to resolves against it, so a Recording that stops under an open
/// Freeze Frame, or a toolbar switch, doesn't change what the session shows.
struct FreezeContext {
    var recording = false
    var shortcut: ShortcutOptions? = nil
    /// whether `tool` shows the Freeze Frame in this session
    @MainActor func freezes(_ tool: Tool) -> Bool {
        FreezePolicy.resolve(tool.freezeUse, recording: recording, capture: AppState.shared.config.value.capture, shortcut: shortcut)
    }
}

extension Tool {
    /// the Freeze Frame policy's name for this Tool: Freeze Region picks a target like the Capture Tools
    var freezeUse: FreezePolicy.Use {
        switch kind {
        case .util: .utility
        case .markup where self != .freezeRegion: .markup
        default: .capture
        }
    }
}
