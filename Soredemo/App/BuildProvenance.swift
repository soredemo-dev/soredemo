/// Which build produced *this binary*, baked in at build time rather than read
/// from `git` at launch — a launch-time read reports the checkout's current state,
/// which can differ from the tree that was compiled.
///
/// This file is regenerated wholesale by `scripts/build-app-for-verification.sh`
/// immediately before `xcodebuild` compiles it; hand-edits are overwritten.
/// The committed values are a deliberate placeholder, not a real commit or timestamp —
/// they are what a plain `xcodebuild` or Cmd+B produces, and read as obviously fake so
/// they cannot be mistaken for a real provenance reading.
enum BuildProvenance {
    static let builtAt = "UNBUILT — not built via scripts/build-app-for-verification.sh"
    static let commit = "UNBUILT — not built via scripts/build-app-for-verification.sh"
}
