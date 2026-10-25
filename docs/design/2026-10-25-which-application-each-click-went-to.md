# Which application each click went to

2026-10-25. Step 1's missing field in `2026-10-25-beyond-a-screen-recorder.md` ("What this asks
of the code"): the application a click went to, as its **bundle identifier**, recorded with the
click. The read-only "is this demo out of date" check needs it to find the application again —
an application's name is its display name, which changes with the language and the version.

## A sentence in the parent document is wrong

That document says *"the ancestor chain stops at the window"*. It does not: `AXObserver` walks
up to 30 levels and records the root, which for a click in an application is its
`AXApplication` element, and `RecordedSteps` already reads that element's title as the step's
application name. Corrected there in the same change. The field that is missing is not the
application but its identity.

## Decisions

- **`ApplicationIdentifier`, a type with a validating initialiser and a hand-written
  `init(from:)`.** It is written into the observation log, and a `.soredemo` package is a
  document people share: the value on the decode path is untrusted. A bundle identifier is
  letters, digits, `-` and `.`, at most 255 characters (`CFBundleIdentifier`'s documented
  alphabet); anything else is refused, on both paths. Synthesised `Codable` is not used, for the
  reason AGENTS.md gives about every type that validates.
- **`AXChainRecord.application`, optional, encoded only when present.** A log written before this
  field decodes unchanged; a record without it means "not recorded", consistent with every other
  `nil` in the record. It is read from the hit element only — the element under the click is in
  the application the click went to, and the ancestors are in the same process.
- **Read through the seam the walk already has.** `AXElementSource` gains
  `application(of:)`; the live source asks `AXUIElementGetPid`, then `proc_pidpath` for that
  process's executable, then the bundle enclosing it through Foundation's `Bundle`. No AppKit:
  `Capture` may not import it (`HeadlessCheck`), and `NSRunningApplication` would be the only
  reason to.
- **Not counted in `axCalls`: it is not a round trip.** The header does not say whether
  `AXUIElementGetPid` asks the other process, so it was measured against a real attribute read,
  on an element another process owns (the Dock's; positive control — the path resolved to
  `com.apple.dock`): **10 ns a call against 18 368 ns for reading `AXRole`**, three orders of
  magnitude apart. It reads the element's own field. `proc_pidpath` is about 1 µs.
- **`RecordedStep.applicationIdentifier`** carries it to the steps. Its first reader is the
  out-of-date check, the next item; until then it is code with no caller, recorded as such.

## How it is verified

- `ApplicationIdentifier`: accepts `com.apple.Keynote` and `dev.soredemo.mac`; refuses the empty
  string, a space, a slash, a 256-character string — on `init` and on decode. Mutation: the
  alphabet check removed.
- `AXChainRecord` round-trips with the field, and a record written without it decodes with
  `nil` — the byte-exact form of an existing fixture is unchanged. Mutation: the field encoded as
  `null` when absent.
- The walk, on the fake source: the fake answers an identifier the walk could not have derived
  (`org.example.not-derived`), and the record carries it. The producer-value rule.
- `RecordedSteps`: the step carries its press's identifier.
- The live path: one recording made, the log read, the identifier is the recorded application's.
