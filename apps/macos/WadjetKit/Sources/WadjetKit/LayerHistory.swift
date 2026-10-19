import Foundation

/// Undo and redo for a LayerStack: one snapshot per user action, so a whole
/// drag or a Clear is one step. The caller owns the stack: it reports each
/// action's before and after, and swaps in what undo and redo return.
/// Screen Markup uses it; the Editor reuses it.
public struct LayerHistory: Sendable {
    private var undos: [LayerStack] = []
    private var redos: [LayerStack] = []
    public init() {}
    /// one action took the stack from `before` to `after`. An action that
    /// changed nothing records nothing; a real one drops the redo steps.
    public mutating func record(from before: LayerStack, to after: LayerStack) {
        guard before != after else { return }
        undos.append(before)
        redos.removeAll()
    }
    /// the stack before the last action, or nil with nothing to undo;
    /// `current` becomes the redo step
    public mutating func undo(from current: LayerStack) -> LayerStack? {
        guard let prev = undos.popLast() else { return nil }
        redos.append(current)
        return prev
    }
    /// the stack undo last left, or nil; `current` becomes an undo step again
    public mutating func redo(from current: LayerStack) -> LayerStack? {
        guard let next = redos.popLast() else { return nil }
        undos.append(current)
        return next
    }
    /// History ends once nothing is left and the session is closed (the
    /// toolbar today, the Editor window later): call it on close, and on any
    /// change made while closed.
    public mutating func end(ifCleared stack: LayerStack) {
        if stack.isEmpty { self = LayerHistory() }
    }
}
