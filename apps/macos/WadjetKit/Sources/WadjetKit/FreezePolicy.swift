import Foundation

/// Whether opening a Tool takes a Freeze Frame. Layers, least to most
/// specific: `capture.freeze`, `capture.freezeWhileRecording`, the Shortcut's
/// `options.freeze`, its `options.freezeWhileRecording` — each set layer
/// overrides the one before, and the while-recording layers apply only during
/// a Recording.
public enum FreezePolicy {
    /// what the Tool does with the screen, which sets its defaults: Utilities read pixels, Markup draws,
    /// and Capture, Record and Freeze Region pick a target
    public enum Use: Sendable { case utility, markup, capture }
    public static func resolve(_ use: Use, recording: Bool, capture: WadjetConfig.Capture, shortcut: ShortcutOptions?) -> Bool {
        if use == .utility { return true } // Utilities read the Freeze Frame's pixels
        var freeze = capture.freeze
        if recording { freeze = capture.freezeWhileRecording ?? (use == .markup ? false : freeze) }
        if let v = shortcut?.freeze { freeze = v }
        if recording, let v = shortcut?.freezeWhileRecording { freeze = v }
        return freeze
    }
}
