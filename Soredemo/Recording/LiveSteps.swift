/// The last few presses of a take, as the expanded notch lists them — the checklist of the
/// owner's Grok reference, filled from the same accessibility chains the recording's own steps
/// come from (`RecordedSteps.label`), as each click is answered.
///
/// **Shown only to the person recording.** The notch is this app's window, and a display or
/// region capture excludes this app's windows (`CaptureSource.filter`), so the list is never in
/// the video.
enum LiveSteps {
    static let kept = 3

    /// The newest last; past `kept` the oldest falls off. A press with the label of the one just
    /// before it is the same step — `RecordedSteps` folds a double-click the same way.
    static func appending(_ label: String, to steps: [String]) -> [String] {
        guard steps.last != label else { return steps }
        return Array((steps + [label]).suffix(kept))
    }
}
