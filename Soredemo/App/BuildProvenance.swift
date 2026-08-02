/// Which build produced *this binary* — not what `git` would report if run
/// right now, which answers a different question: the checkout's current
/// state, not the provenance of a `.app` that may have been built minutes
/// or hours earlier from a different tree.
///
/// This distinction is the one Task 7's coordinator named directly: `open`
/// launches whatever `.app` sits at a remembered path, silently, if a
/// rebuild landed somewhere else or never happened at all — and the
/// verification instructions for `--present-picker` include a line reading
/// "if `bufferSize == contentRect × scale`, D2-13a was not implemented",
/// which a *stale* binary would satisfy while saying nothing true about the
/// code actually on disk today. A subject block that states which process
/// is answering (Task 6) but not which **build** is answering has the same
/// hole one layer up.
///
/// **Both fields are overwritten by `scripts/build-app-for-verification.sh`
/// immediately before `xcodebuild` compiles this file** — a build-time
/// injection, not a runtime `git`/`Date()` read. That is deliberate and
/// load-bearing: reading `git rev-parse HEAD` at *launch* would report the
/// checkout's state at the moment the app happens to run, which can already
/// differ from the tree that was actually compiled (a commit landed after
/// the build, a `git checkout` of another branch) — the exact class of
/// error this file exists to close, recreated one level down if the read
/// moves to runtime. This is why the value is baked into a **source file**
/// the compiler burns into the binary, rather than looked up when the app
/// starts.
///
/// **The placeholder below is committed, and is what a plain `xcodebuild`
/// or Xcode's own Cmd+B produces**, since neither runs the wrapper script.
/// It is written to read as obviously fake — never as a plausible-looking
/// but wrong date or hash — so a subject block built from it cannot be
/// mistaken for a trustworthy reading (`AGENTS.md`: a measurement has no
/// safe default; failure must land outside the value's legal range, not
/// inside it as a quietly wrong instance).
enum BuildProvenance {
    static let builtAt = "UNBUILT — not built via scripts/build-app-for-verification.sh"
    static let commit = "UNBUILT — not built via scripts/build-app-for-verification.sh"
}
