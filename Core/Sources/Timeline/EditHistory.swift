import Foundation

/// Undo and redo for a value.
///
/// **Why a stack of values rather than a stack of inverse operations.**
/// `../opensource/Screen Record Opensource/a native editor`'s `EditorUndo` wraps
/// `UndoManager` and registers a closure per mutation that undoes it. That is the right design
/// for what it edits: a mutable object graph where a change touches one clip in place, and
/// snapshotting the graph per keystroke would be expensive.
///
/// `EditTimeline` is a value. Every edit already produces a whole new one, so the previous
/// state is simply the value that was there before — no inverse to write, none to get wrong,
/// and no way for an inverse to drift from the operation it is supposed to undo. That last
/// point is the real argument: an inverse is a second implementation of an edit, and two
/// implementations of one rule is the shape this project keeps finding bugs in.
///
/// **The cost is memory, and it is negligible here.** A timeline is a handful of clips —
/// two integers and an id each — so a hundred of them is a few kilobytes. A general NLE
/// editing hours of multi-track footage could not make this trade; this one can, and saying
/// which assumption it rests on is what makes it a decision.
///
/// **Not tied to `UndoManager`.** This target is deterministic — no AppKit, no ambient state —
/// and the app tier drives ⌘Z into it. That also makes the whole rule testable without a
/// window, which is where the interesting cases are: coalescing, the redo branch, the bound.
public struct EditHistory<Value: Equatable & Sendable>: Sendable {
    /// One step, and the name a menu shows for it — "Undo Split at playhead", not "Undo".
    public struct Step: Sendable {
        public let name: String
        public let value: Value
    }

    /// The current value. Never in either stack: `past` is what came before it and `future`
    /// what was undone away from it, so a value is in exactly one place at a time.
    public private(set) var current: Value
    private var past: [Step] = []
    private var future: [Step] = []
    private let limit: Int

    /// 200 steps. Deep enough that a person editing for an hour does not hit it, shallow
    /// enough to bound the memory at a few hundred kilobytes of timelines.
    public init(_ initial: Value, limit: Int = 200) {
        precondition(limit > 0, "a history that can hold nothing is not a history")
        self.current = initial
        self.limit = limit
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    /// The names a menu shows. `nil` when there is nothing to undo or redo.
    public var undoName: String? { past.last?.name }
    public var redoName: String? { future.last?.name }
    public var depth: Int { past.count }

    /// Records a new value under an action name.
    ///
    /// **A value equal to the current one records nothing.** Committing a no-op — dragging a
    /// handle and putting it back, splitting on a boundary — would otherwise put a step in the
    /// history that undoes to the state it is already in, and a person pressing ⌘Z would see
    /// nothing happen.
    ///
    /// **Recording clears the redo branch**, which is what every editor does and what a person
    /// expects: once you edit after undoing, the thing you undid is no longer ahead of you.
    public mutating func record(_ name: String, _ value: Value) {
        guard value != current else { return }
        past.append(Step(name: name, value: current))
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
        current = value
    }

    /// Steps back. Returns the value now current, or `nil` when there is nothing to undo.
    @discardableResult
    public mutating func undo() -> Value? {
        guard let step = past.popLast() else { return nil }
        // The name travels with the value being LEFT, so redo can offer the same wording the
        // undo did — "Redo Split at playhead" is the same action, seen from the other side.
        future.append(Step(name: step.name, value: current))
        current = step.value
        return current
    }

    @discardableResult
    public mutating func redo() -> Value? {
        guard let step = future.popLast() else { return nil }
        past.append(Step(name: step.name, value: current))
        current = step.value
        return current
    }

    /// Replaces the value and forgets everything — reopening a recording, not editing one.
    public mutating func reset(to value: Value) {
        current = value
        past.removeAll()
        future.removeAll()
    }
}
