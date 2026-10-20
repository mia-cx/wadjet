import Foundation

/// When the island, the toolbar at the top of each display, stays on screen.
/// A Freeze Frame always shows it. Without one, an armed Markup Tool keeps the
/// live toolbar open, Annotations keep the collapsed island with their count,
/// a Recording shows its own island when that option is on, and a Clear's
/// draining Undo ring holds it for a moment (ClearUndo). With none of
/// these, the island goes, however the last one went: a disarm, Clear, Undo,
/// the Eraser, or deleting the last Annotation.
public enum IslandRule {
    /// the live toolbar (no Freeze Frame) stays open; false sends it back to the plain desktop
    public static func keepsLiveToolbar(toolArmed: Bool, hasAnnotations: Bool) -> Bool {
        toolArmed || hasAnnotations
    }
    /// any display shows the island
    public static func showsIsland(toolbarOpen: Bool, hasAnnotations: Bool, recordingIsland: Bool,
                                   undoRing: Bool = false) -> Bool {
        toolbarOpen || hasAnnotations || recordingIsland || undoRing
    }
}
