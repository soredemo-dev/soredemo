import CheckerLexer
import Foundation
import Testing

// MARK: - why these are package tests and not plugin rules
//
// `Plugins/ArchitectureCheck` attaches to SwiftPM targets. The app lives in
// `Soredemo.xcodeproj`, which the plugin cannot see at all, so the two app-side
// allow-lists below cannot be plugin rules however much they look like ones.
//
// They scan through `SwiftSourceLexer.codeViewLines` — the SAME code view the
// plugin's rules 1, 2 and 4 use — so a banned name inside a comment or a string
// literal does not fire. That sharing is the whole point of the `CheckerLexer`
// target: a second copy of the lexer written here would start at round zero of
// the four evasion-closing rounds the real one has been through, and would then
// drift away from the enforcement it exists to mirror.
//
// A scanner that fires on a comment is a scanner people route around. Being
// precise about what that buys TODAY, because the obvious-sounding version of
// this sentence is false: the files actually scanned here — everything under
// `Soredemo/` except the one permitted file — carry almost no prose about these
// names. `ProjectDocument.swift:146` mentions "a UUID collision" in a `///`
// line, and that is the lot; it would not match `UUID(` in any case. The two
// files thick with such prose are `CGGeometryBridge.swift` and `Minting.swift`,
// which are the PERMITTED files and are never scanned at all.
//
// So comment-immunity is not load-bearing on today's sources. What it buys is
// that the rule stays DOCUMENTABLE: the first person to write
// `// mint identifiers in Minting, never `UUID()` here` at the top of
// `ProjectDocument.swift` — the most natural thing to write, and a thing that
// makes the codebase better — would trip a naive scan on the documentation of
// the rule itself, and the fix they would reach for is deleting the check. The
// evidence that it holds is the mutation pair in this task's report, not the
// current contents of these files: the same banned text was placed in a `//`
// comment, a `/* */` comment, a plain string, a raw string and a `"""` string,
// and the scan stayed green in all five.
//
// SUBSTRING, NOT TOKEN EQUALITY, deliberately — settled for rule 2 in Task 3.
// `contains("CGRect")` matches `` `CGRect` ``, a backtick-escaped identifier
// resolving to the same declaration; token equality would not, because the code
// view keeps the backticks as part of the token's text. For a question about
// which NAMES appear, substring is the stronger mechanism, not a weaker one.
// It over-approximates in the loud direction: `contains("Date(")` would also
// fire on a hypothetical `refreshDate(`. That is a visible false positive, which
// this project's design doc treats as survivable, and a miss is not.

/// `<root>/Tests/AppSourceTests/AppSourceAllowListTests.swift` → `<root>`.
/// Three `deletingLastPathComponent()` calls: one drops the file name, one drops
/// `AppSourceTests`, one drops `Tests`. If this file is ever moved, the count is
/// wrong and `appSourceFiles()` finds nothing — which the `#require` there turns
/// into a loud failure rather than a scan of an empty set.
let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// The app's sources, and ONLY the app's sources.
///
/// Scoped to `Soredemo/` rather than the repository, deliberately:
/// `scripts/cross-boundary-digest-probe.swift` legitimately names `CGRect` and
/// calls `UUID()` — it is a standalone probe, not app code — and `Sources/` is
/// the package, which has its own enforcement in the plugin.
let appSourceDirectory = repositoryRoot.appending(path: "Soredemo")

/// Every `.swift` file under `Soredemo/`.
///
/// A missing or empty app source tree is a FAILURE, not a vacuous pass: an empty
/// scan finds no violations and reads exactly like a clean one. `AGENTS.md`
/// carries this rule because a probe on this plan already reported a green from
/// having measured nothing.
func appSourceFiles() throws -> [URL] {
    let enumerator = try #require(
        FileManager.default.enumerator(at: appSourceDirectory, includingPropertiesForKeys: nil),
        "cannot enumerate \(appSourceDirectory.path(percentEncoded: false))")

    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        if url.pathExtension == "swift" { files.append(url) }
    }
    try #require(!files.isEmpty,
                 "no app sources found at \(appSourceDirectory.path(percentEncoded: false)) — this scan would pass vacuously")
    return files.sorted { $0.path < $1.path }
}

/// `Soredemo/UI/ProjectDocument.swift`, not the absolute path — the form the
/// checker prints, and the form that is greppable from the repository root.
///
/// `repositoryRoot` is a DIRECTORY URL, so its `path` already ends in `/`;
/// appending another one produced `…soredemo-main//Soredemo/…`, matched nothing,
/// and left every reported path absolute. Found by the mutation check in Part 3
/// of this task, which is the entire argument for running one.
func pathRelativeToRepositoryRoot(_ url: URL) -> String {
    let root = repositoryRoot.path(percentEncoded: false)
    let prefix = root.hasSuffix("/") ? root : root + "/"
    let path = url.path(percentEncoded: false)
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}

/// One violation, in the `file:line:` form the checker prints, so a failure here
/// reads the same way a plugin failure does.
/// `permittedPath` is repository-relative and matched WHOLE, not by file name.
///
/// Matching on `lastPathComponent` would allow-list the file wherever it moved
/// to. `#require(count == 1)` blocks a *second* file of that name, so the hole is
/// relocation rather than duplication: moving `Minting.swift` into
/// `Soredemo/UI/` would keep it permitted while destroying the thing the test
/// stands for — that these values enter at one place you can point at. The
/// permitted path is part of the claim, so it is part of the assertion.
func violations(
    banned: [String],
    permittedPath: String,
    in files: [URL]
) throws -> [String] {
    // The permitted file must exist AT THAT PATH. If it were renamed or moved
    // away, this scan would still pass — the rename direction is the safe one,
    // because the file's contents would then be scanned and fail loudly — but the
    // CLAIM the test stands for would be about a place that no longer exists.
    let permitted = files.filter { pathRelativeToRepositoryRoot($0) == permittedPath }
    try #require(permitted.count == 1,
                 """
                 expected exactly one \(permittedPath), found \(permitted.count). \
                 If it moved, move the allow-list entry with it — the path is part \
                 of the claim, not an implementation detail of the scan.
                 """)

    let scanned = files.filter { pathRelativeToRepositoryRoot($0) != permittedPath }
    try #require(!scanned.isEmpty,
                 "only \(permittedPath) exists — nothing outside the allow-list was scanned")

    var found: [String] = []
    var linesScanned = 0
    for file in scanned {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            linesScanned += 1
            for name in banned where line.contains(name) {
                found.append("\(pathRelativeToRepositoryRoot(file)):\(index + 1): names '\(name)'")
            }
        }
    }
    try #require(linesScanned > 0, "no lines were examined — the scan would pass vacuously")
    return found
}

// MARK: - rule 5: the CoreGraphics bridge

/// **Rule 2** (`ARCHITECTURE.md` D6, the only numbering) keeps `CGRect`, `CGPoint`,
/// `CGSize` and `CGFloat` out of the
/// PACKAGE, enforced by the plugin. This is the app-side half — **rule 5**, and
/// both numbers are D6's: they may appear in
/// exactly one file, the bridge, where CoreGraphics geometry is converted into
/// this project's own types on entry and back out on exit. Nothing in between
/// speaks in pixels (ARCHITECTURE.md D3).
///
/// **The mirror: `ArchitectureChecker.bannedCGTypes` in
/// `Sources/architecture-checker/main.swift` holds the same four names for the
/// package.** `grep bannedCGTypes` finds both sides, which is the point of naming
/// it here. They are mirrored rather than shared deliberately — two rules over
/// two different bodies of source, either of which may gain a name the other must
/// not — but a fifth banned type means editing both, and nothing enforces that.
/// The only target both sides can reach is `CheckerLexer`, which is the one
/// target outside plugin enforcement, so a shared list would sit in the
/// least-guarded place in the package.
@Test func coreGraphicsGeometryTypesAppearOnlyInTheBridge() throws {
    let found = try violations(
        banned: ["CGRect", "CGPoint", "CGSize", "CGFloat"],
        permittedPath: "Soredemo/Capture/CGGeometryBridge.swift",
        in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            a CoreGraphics geometry type reached the app outside the bridge:
            \(found.joined(separator: "\n"))
            Convert at Soredemo/Capture/CGGeometryBridge.swift and pass the \
            package's own types onward; see ARCHITECTURE.md D3.
            """)
}

// MARK: - rule 3's app-side half: where non-determinism enters

/// The needles for rule 3's app-side half, at file scope so that
/// `everyAmbientNeedleMatchesACallSiteInACompiledFixture` can prove each one
/// still matches something. Inline in the test, they could only ever be
/// asserted absent from the app — and a typo is absent from everything.
let ambientBannedNames: [String] = [
    // ── ambient time ────────────────────────────────────────────────
    // `Date(` covers `Date()` and `Date(timeIntervalSinceNow:)`, and
    // `NSDate(` besides; `Date.init` covers the explicit spelling, which
    // shares no substring with it.
    "Date(", "Date.init", "Date.now",
    "timeIntervalSinceNow", "timeIntervalSinceReferenceDate",
    "DispatchTime.now", "DispatchWallTime.now",
    // The clock TYPES, not just their `now` — obtaining one at all is the
    // step that has to happen somewhere auditable.
    "ContinuousClock", "SuspendingClock",
    "CFAbsoluteTimeGetCurrent",
    "mach_absolute_time", "mach_approximate_time",
    // Advances during sleep where `mach_absolute_time` does not (D2-4)
    // — a different reading, not a spelling variant of the one above,
    // and just as ambient. Added Task 5 review round 1: `Minting`
    // gained `continuousNow()` and this list was not updated with it,
    // so the claim below ("enters only through Minting") was true by
    // hand-check, not by test, for exactly the gap this file exists
    // to close.
    "mach_continuous_time",
    // Subsumes `clock_gettime_nsec_np`.
    "clock_gettime", "gettimeofday",
    // C `clock()` — processor time, a different reading from the two
    // above and still ambient. Verified open on both sides by Task
    // 5.5's sweep; the package side bans `_clock` by symbol. Broad on
    // purpose, like `time(` below: it also fires on a hypothetical
    // `refreshClock(`, which is the loud direction.
    "clock(",
    // C `time()`. Broad on purpose: Swift's camelCase means a lowercase
    // `time` immediately before `(` is close to unwritable by accident.
    "time(",
    "NSDate", "systemUptime",

    // ── ambient randomness ──────────────────────────────────────────
    "UUID(", "UUID.init",
    // The ObjC class, as ANY reference — the same over-approximation
    // `NSDate` already gets one section up, and `NSUUID` is exactly the
    // sibling D2-16 lists as the third staleness finding. `UUID(` above
    // happens to catch `NSUUID()`, because the constructor call contains
    // it; it does not catch `NSUUID.init`, a stored `let x: NSUUID`, or
    // a cast. Task 5.5 verified this open on both sides.
    "NSUUID",
    // CommonCrypto's CSPRNG. The PACKAGE side needs no entry: rule 1's
    // import allow-list is Foundation plus declared siblings, and
    // `CCRandomGenerateBytes` needs `import CommonCrypto`, so no package
    // target can reach it in the first place. The app target has no such
    // rule, which is why this side has one. Task 5.5.
    "CCRandomGenerateBytes",
    // The `drand48` family. ONE needle for the whole family, where the
    // package side names four symbols: a text scan pays nothing for the
    // wider match, and a family is what this list keeps going stale one
    // member at a time. It therefore also catches `erand48`, which the
    // package side deliberately does NOT ban (its state is an argument,
    // not process-global — see the note there). That asymmetry is the
    // cheap direction and is stated rather than tidied away.
    "rand48", "seed48", "lcong48",
    // `.random(` catches `Int.random(in:)`, `Double.random(in:)` and
    // `Bool.random()`. It does NOT catch `.randomElement(`, because the
    // character after `random` is `E` — hence the separate entry.
    ".random(", "randomElement",
    // Subsumes `shuffled()`.
    "shuffle",
    "SystemRandomNumberGenerator",
    // Subsumes `arc4random_uniform` and `arc4random_buf`.
    "arc4random",
    // `Security`'s CSPRNG — a distinct source from `arc4random`, not a
    // spelling of it. `arc4random` reads the kernel's PRNG directly;
    // `SecRandomCopyBytes` goes through `Security`'s own CSPRNG. Both are
    // Minting-shaped ambient randomness, and `SecRandomCopyBytes` compiles
    // and links with plain `import Foundation` — no `import Security`
    // needed on Darwin — so nothing about the app's imports would flag it.
    // Task 5.5.
    "SecRandomCopyBytes",

    // ── ambient hashing ─────────────────────────────────────────────
    "SHA256",

    // ── ambient identity (boot epoch) ───────────────────────────────
    // `Minting.bootEpoch()` reads `kern.bootsessionuuid` through this
    // call. Not time and not randomness, but the same shape of
    // problem: a value only the environment can supply, entering the
    // app at one audited place. Added alongside `mach_continuous_time`
    // in the same review round, for the same reason — this file's
    // list has to be re-derived every time `Minting` gains a new
    // ambient source, not assumed to already cover it.
    "sysctlbyname",
    // A display's persistent identity, from
    // `CGDisplayCreateUUIDFromDisplayID` — added in Task 9 alongside
    // `Minting.displayUUID(of:)`, in the same commit, because this
    // list has to be re-derived every time `Minting` gains an ambient
    // source rather than assumed to already cover it. It is also the
    // only route from a `CGDirectDisplayID` to the `UUID`
    // `DisplayGeometry` requires, so banning it here is what makes
    // the `UUID(` ban above unevadable for display identity
    // specifically: without it a caller could read the `CFUUID`
    // anywhere and only the final `UUID(uuidString:)` would be
    // caught, which is a check on the last line of the wrong file.
    "CGDisplayCreateUUIDFromDisplayID",
]


/// Architecture rule 3 — no ambient time or randomness — is checked over the
/// LINK-TIME SYMBOLS in the package's object files (`Tests/DeterminismTests`).
/// `Soredemo/Support/Minting.swift` is in the **app** target, so nothing checks
/// it, and nothing stops `ProjectDocument.swift` calling `UUID()` directly.
///
/// That would produce no wrong result — a UUID is a UUID — which is exactly why
/// it needs a test rather than a review habit. It would make the sentence
/// "non-determinism enters at one audited place" false while `Minting.swift`'s
/// own doc comment, `AGENTS.md` and the design doc all still assert it. That is
/// the same failure as `NormalizationContext` having no caller: a true-sounding
/// sentence with nothing underneath it.
///
/// `SHA256` is here for the same reason and one more: `ContentDigest` documents
/// at length that the package COMPARES digests and never computes one, because
/// computing needs CryptoKit and rule 1 forbids it. The producer is `Minting`,
/// and it must stay the only one.
///
/// **The list below is derived from `bannedSymbols` in
/// `Tests/DeterminismTests/SymbolDeterminismTests.swift`, one text spelling per
/// construct, and it was four entries long until Task 19.** Those four —
/// `UUID(`, `Date(`, `SHA256`, `SystemRandomNumberGenerator` — caught none of
/// `Date.now`, `Int.random(in:)`, `UUID.init()`, `Date.init()`, `Bool.random()`
/// or `arc4random()`, all six of which were appended to `ContentView.swift` and
/// observed passing. The package side had already enumerated every one of them;
/// this side was a strictly smaller subset of a problem solved next door, and the
/// row in `ROADMAP.md` that reads "ambient time, randomness and hashing confined
/// to `Minting.swift`" was broader than the check under it. The doc comment above
/// warns about a true-sounding sentence with nothing underneath it, which is what
/// that sentence had become.
///
/// **This is a text scan, and the design doc rejected text scanning for exactly
/// this rule** (F7, § Determinism): it is a proxy for a semantic question and it
/// leaks. That verdict stands and is not being reversed here — the package side
/// reads link-time symbols and always will. The app target has no test target and
/// its object files are not where `nm` can be pointed from a package test, so text
/// is what is available on this side of the boundary. What text cannot reach is
/// therefore a **known gap with a reachability row**, in the design doc's
/// `ArchitectureCheck` gap table, alongside every other gap in this repository.
/// It shipped without one, which is why nobody noticed the list was short.
@Test func ambientTimeRandomnessAndHashingEnterOnlyThroughMinting() throws {
    let found = try violations(
        banned: ambientBannedNames,
        permittedPath: "Soredemo/Support/Minting.swift",
        in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            an ambient value was minted outside Soredemo/Support/Minting.swift:
            \(found.joined(separator: "\n"))
            Identifiers, timestamps and digests enter at that one boundary and \
            are passed onward as plain values — that is what makes derivation a \
            deterministic function of its input.
            """)
}

// MARK: - the keystroke ban: no allow-listed file, because there is no legitimate caller

/// Like `violations(banned:permittedPath:in:)`, but with **no permitted
/// file**.
///
/// The other two scans are about where something may happen; this one is
/// about something that may not happen anywhere. Passing an allow-listed path
/// would be worse than useless: the only file that would ever want one is
/// `InputObserver.swift`, which is precisely the file the rule is about.
func violationsEverywhere(banned: [String], in files: [URL]) throws -> [String] {
    try #require(!files.isEmpty, "no app sources were scanned — this scan would pass vacuously")
    var found: [String] = []
    var linesScanned = 0
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            linesScanned += 1
            for name in banned where line.contains(name) {
                found.append("\(pathRelativeToRepositoryRoot(file)):\(index + 1): names '\(name)'")
            }
        }
    }
    try #require(linesScanned > 0, "no lines were examined — the scan would pass vacuously")
    return found
}

/// **`ROADMAP.md`'s `input-observation` row: "the package must never receive
/// an unfiltered keystroke — there is then nothing to redact later."**
///
/// `InputObserver.approvedShortcut(forKeyCode:flags:)` is the behavioural half
/// of that claim, and it is checked behaviourally in `§ 7.3` of
/// `scripts/cross-boundary-digest-probe.swift` — including with the filter
/// removed, observed red. This is the other half, and it is a different
/// statement: not "the filter refuses ordinary typing", but **"no code in
/// this app can turn a key event into text at all"**. A filter can be
/// bypassed by a second code path; this cannot, because the APIs that would
/// do it are not nameable.
///
/// The list is the ways a `CGEvent` or an `NSEvent` yields characters:
/// `CGEventKeyboardGetUnicodeString` and its `CGEventField` spelling,
/// `NSEvent.characters` / `.charactersIgnoringModifiers`, and `UCKeyTranslate`
/// (with the Text Input Source lookup that feeds it), which is the manual
/// keycode → character route someone would reach for after finding the first
/// three unavailable. Key *codes* and modifier flags stay legal: they are
/// hardware positions and a bitmask, and they are what the allow-list matches
/// on.
///
/// **This does not claim to be exhaustive**, and a text scan cannot be — it is
/// the same known gap the ambient-value scan above documents at length, on the
/// same side of the same boundary, for the same reason (the app target has no
/// object files a package test can point `nm` at). What it does is make the
/// obvious routes cost a deliberate edit to this file.
@Test func noAppSourceReadsKeystrokeText() throws {
    let found = try violationsEverywhere(
        banned: [
            // CoreGraphics: the event's own characters.
            //
            // **`keyboardGetUnicodeString` is the entry that does the work,
            // and it was missing.** The C symbol below it is the spelling the
            // header uses and the one this list originally carried alone —
            // but it does not exist in Swift, so it was dead text guarding
            // nothing while the natural Swift call sailed through. Measured,
            // both spellings compiled against this SDK:
            //
            //     CGEventKeyboardGetUnicodeString(e, 4, &n, &buf)
            //       error: 'CGEventKeyboardGetUnicodeString' has been replaced
            //       by instance method 'CGEvent.keyboardGetUnicodeString(
            //       maxStringLength:actualStringLength:unicodeString:)'
            //
            //     e.keyboardGetUnicodeString(maxStringLength: 4,
            //                                actualStringLength: &n,
            //                                unicodeString: &buf)
            //       compiles.
            //
            // The C spelling is kept anyway, labelled: it costs a line, it is
            // what someone reading `CGEvent.h` will try first, and a rule
            // whose ban list omits the name in the documentation invites the
            // ban to be read as narrower than it is. But it is NOT what makes
            // this test bite — for that spelling the compiler is the
            // enforcement, and for the Swift one this list is.
            "keyboardGetUnicodeString",
            "CGEventKeyboardGetUnicodeString",
            // **The setter, banned too.** Writing text into a keyboard event
            // is not reading one, so it is not literally the leak this test
            // is named for — but it is the same capability from the other
            // side, and it is worse in two ways. A process that sets a
            // keystroke's text is holding that text, which is the state this
            // rule exists to make unreachable; and a `.listenOnly` tap that
            // modifies an event is not listen-only, so the ban also protects
            // the claim that this app never alters someone else's input.
            "keyboardSetUnicodeString",
            "keyboardEventUnicodeString",
            // AppKit: `.characters` also covers `.charactersIgnoringModifiers`,
            // which begins with the same substring including the dot.
            ".characters",
            // The manual keycode → character route, and the input source it
            // needs. Either name alone is enough to make the attempt visible.
            "UCKeyTranslate",
            "TISGetInputSourceProperty",
        ],
        in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            an app source can read the text of a keystroke:
            \(found.joined(separator: "\n"))
            Keyboard observation matches key CODES and modifier flags against \
            InputObserver.approvedShortcuts and records that table's own \
            identifier. Nothing in this app is permitted to learn what was typed \
            — including in order to discard it, because a value that existed can \
            be logged, and there is then something to redact later.
            """)
}

// MARK: - a required-presence scan: the mirror image of the three bans above

/// Every code line under `Soredemo/` containing `needle`, in `file:line:` form
/// with the line's own code-view text attached.
///
/// Read through `SwiftSourceLexer.codeViewLines` like every other scan here,
/// so a mention in a doc comment does not count — which matters more for this
/// scan than for the bans: the file this one is about documents the call at
/// length, and a scan that counted prose would report the requirement
/// satisfied by the sentence describing it.
func codeLinesNaming(_ needle: String, in files: [URL]) throws -> [(location: String, text: String)] {
    try #require(!files.isEmpty, "no app sources were scanned — this scan would pass vacuously")
    var found: [(location: String, text: String)] = []
    var linesScanned = 0
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in SwiftSourceLexer.codeViewLines(of: text).enumerated() {
            linesScanned += 1
            if line.contains(needle) {
                found.append((location: "\(pathRelativeToRepositoryRoot(file)):\(index + 1)",
                              text: line.trimmingCharacters(in: .whitespaces)))
            }
        }
    }
    try #require(linesScanned > 0, "no lines were examined — the scan would pass vacuously")
    return found
}

/// **The other three scans in this file say where something may not happen.
/// This one says that something must.**
///
/// `InputObserver` takes its secure-input predicate as an injected argument so
/// the interval logic — open, close, the two end reasons, the suppression —
/// can be exercised without another application's password field, which is the
/// only thing that makes `IsSecureEventInputEnabled()` true. That injection
/// buys real coverage and it opens a hole exactly one character wide:
/// defaulting the parameter to `{ false }` disables the privacy guarantee
/// outright, and every test in this package and every behavioural check that
/// passes its own predicate in stays green, because none of them ever
/// evaluates the default.
///
/// So both halves are pinned:
///
/// 1. `IsSecureEventInputEnabled` appears on **exactly one** code line. Zero
///    means nothing reads the real predicate. More than one means there is a
///    second reader, and a second reader is a second policy — the thing this
///    file exists to prevent for `UUID()` and for CoreGraphics geometry.
/// 2. That line is the **default argument** of the injection point. Moving the
///    read anywhere else — into `handle`, into a helper — would satisfy (1)
///    while making the injected predicate no longer the single source of the
///    answer, which is the property `§ 7.4` of the probe relies on.
///
/// **This is strictly weaker than the probe's `§ 7.7`**, which enables secure
/// input for real and asserts the observer goes silent. It pins spelling; that
/// one pins behaviour. It is here because it fires under `swift test` without
/// anyone running the probe, and the probe is documented as running nothing
/// automatically — the same trade this file already accepts for `Minting`,
/// where a text scan stands next to a link-time symbol check.
@Test func theSecureInputPredicateIsReadExactlyOnceAndOnlyAtTheInjectionPoint() throws {
    let readers = try codeLinesNaming("IsSecureEventInputEnabled", in: try appSourceFiles())

    #expect(readers.count == 1,
            """
            expected exactly one app source line reading IsSecureEventInputEnabled, found \(readers.count):
            \(readers.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            Zero means the real predicate is never read and the secure-input guarantee is off. \
            More than one means there are two policies about when capture is suppressed, and \
            nothing keeps them in step.
            """)

    guard let reader = readers.first else { return }
    #expect(reader.text.contains("secureInputIsEnabled:"),
            """
            IsSecureEventInputEnabled is read at \(reader.location), which is not the injection \
            point's default argument:
            \(reader.text)
            It belongs on the `secureInputIsEnabled:` parameter of InputObserver.init and nowhere \
            else — that parameter is what lets the interval logic be tested without a password \
            field, and it only means anything while the default IS the real predicate.
            """)
}

/// The line number out of a `codeLinesNaming` location (`path:line`).
///
/// Ordering checks need it: "this call happens inside that function, after
/// that other call" is a claim about position in the file, and position is
/// what a text scan can actually see.
func lineNumber(of location: String) -> Int {
    Int(location.split(separator: ":").last.map(String.init) ?? "") ?? -1
}

/// **The poll must actually be started, and started where the tap exists.**
///
/// This is the hole the whole polling round would otherwise have left one
/// level above where it was closed. `InputObserver.startPolling()` and
/// `pollTapEnabled()` are driven **directly** by `§ 7.10` of the probe,
/// because `start()` creates a real `CGEvent` tap and that needs Input
/// Monitoring. So the probe cannot see whether the shipping path ever
/// schedules the timer, and `theTapsEnabledFlagIsReadExactlyOnceAndOnlyInThe
/// Observer` cannot either: `CGEvent.tapIsEnabled` stays named exactly once,
/// inside a `pollTapEnabled()` nobody calls.
///
/// Delete the one production call and: 360 tests pass, 222 probe checks pass,
/// `xcodebuild` succeeds, and the shipping app never polls — so
/// `tapDisabledIntervals` is permanently empty and `tapEnabledPolls`
/// permanently zero. That is exactly the "an empty list reads as no gaps"
/// state this round existed to close, reintroduced at the one point no other
/// check can reach.
///
/// Three claims, because the call can be broken three ways:
///
/// 1. it exists, exactly once, and is not merely the declaration;
/// 2. it sits inside `start(onObservation:)` — after that function begins and
///    before `stop()` does;
/// 3. it comes **after** the tap has been created and enabled. Moved above
///    `CGEvent.tapCreate`, the first poll reads a `nil` tap, takes the
///    `tapPollsWithNoTap` path, and the timer then polls a tap it never sees
///    — green everywhere, and blind.
/// `disableTapForVerification()` exists so a human step can take a real
/// `CFMachPort` down and watch the poll find it. It must never be reachable
/// from anything the product runs.
///
/// **A scan, not a promise in a doc comment.** This project has twice written
/// "keep these the same" or "never call this" in prose and had it missed one
/// file away; the three scans below it are the mechanism that held where prose
/// did not. Zero call sites, one declaration.
@Test func theVerificationOnlyTapDisableIsNeverCalledFromProductCode() throws {
    let files = try appSourceFiles()
    let mentions = try codeLinesNaming("disableTapForVerification", in: files)
    let declarations = mentions.filter { $0.text.contains("func disableTapForVerification") }
    let calls = mentions.filter { !$0.text.contains("func disableTapForVerification") }

    #expect(declarations.count == 1,
            "expected one disableTapForVerification declaration, found \(declarations.count)")
    #expect(calls.isEmpty,
            """
            disableTapForVerification() is called from product code at:
            \(calls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            It disables the event tap through the real port. Nothing the product runs may call it; \
            only a spike, which is outside this scan.
            """)
}

@Test func theTapPollIsStartedByStartAndNotOnlyDefined() throws {
    let files = try appSourceFiles()
    let mentions = try codeLinesNaming("startPolling", in: files)
    let declarations = mentions.filter { $0.text.contains("func startPolling") }
    let calls = mentions.filter { !$0.text.contains("func startPolling") }

    #expect(declarations.count == 1, "expected one startPolling declaration, found \(declarations.count)")
    #expect(calls.count == 1,
            """
            expected exactly one call to startPolling() in the app, found \(calls.count):
            \(calls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            Zero means the shipping app never polls the tap's enabled flag, and every check in this \
            package and in the probe still passes — they drive startPolling()/pollTapEnabled() \
            directly, because start() needs Input Monitoring.
            """)

    guard let call = calls.first else { return }
    #expect(call.location.hasPrefix("Soredemo/Capture/InputObserver.swift:"),
            "startPolling() is called from \(call.location), not from InputObserver")

    // The three landmarks the call must sit between, each named once so a
    // rename fails this test loudly rather than silently widening it.
    let startDeclaration = try codeLinesNaming("public func start(onObservation", in: files)
    let stopDeclaration = try codeLinesNaming("public func stop()", in: files)
    let tapCreate = try codeLinesNaming("CGEvent.tapCreate", in: files)
    let tapEnabled = try codeLinesNaming("CGEvent.tapEnable(tap: created", in: files)
    for (name, landmark) in [("start(onObservation:)", startDeclaration), ("stop()", stopDeclaration),
                             ("CGEvent.tapCreate", tapCreate),
                             ("CGEvent.tapEnable(tap: created", tapEnabled)] {
        try #require(landmark.count == 1, """
                     expected exactly one \(name) in the app sources, found \(landmark.count) — \
                     this scan's landmarks must be unique or its ordering claims mean nothing
                     """)
    }

    let callLine = lineNumber(of: call.location)
    #expect(lineNumber(of: startDeclaration[0].location) < callLine
                && callLine < lineNumber(of: stopDeclaration[0].location),
            """
            startPolling() is called at \(call.location), which is not inside \
            start(onObservation:) (\(startDeclaration[0].location) … \(stopDeclaration[0].location)).
            """)
    #expect(lineNumber(of: tapCreate[0].location) < callLine
                && lineNumber(of: tapEnabled[0].location) < callLine,
            """
            startPolling() is called at \(call.location), before the tap is created \
            (\(tapCreate[0].location)) or enabled (\(tapEnabled[0].location)). The first poll \
            would read a nil tap and count itself as tapPollsWithNoTap, and nothing downstream \
            would look different.
            """)
}

/// **A rejected alternative that is only prose is a rejected alternative
/// nobody is stopped from taking.**
///
/// `AXUIElementSetMessagingTimeout` bounds an AX call, which would make
/// keeping the hit-test on the tap callback thread viable again — it is the
/// clever-looking answer, and D2-18 rejects it: it trades "a call with no
/// upper bound" for "a bounded call that fails by timing out", and a timeout
/// failure is data loss of exactly the kind `clicksDroppedByBacklog` is, in a
/// worse place. The delay is still spent on the callback thread and there is
/// no queue to absorb a burst.
///
/// This is the zero-occurrence form of the three scans above. It costs one
/// line and turns a paragraph someone has to have read into a diff someone has
/// to defend.
@Test func theRejectedAXTimeoutIsNotReachedFor() throws {
    let found = try violationsEverywhere(banned: ["AXUIElementSetMessagingTimeout"],
                                         in: try appSourceFiles())
    #expect(found.isEmpty,
            """
            an app source calls AXUIElementSetMessagingTimeout:
            \(found.joined(separator: "\n"))
            Rejected in the Phase 2 design doc, D2-18: bounding the call trades an unbounded wait \
            for a timeout failure, which is the same data loss as a queue drop, spent on the \
            callback thread, with no queue to absorb a burst. If this is being reconsidered, the \
            place to argue it is D2-18.
            """)
}

/// **`AXObserver.chain` is the synchronous walk, and only `AXObserver` may
/// call it.**
///
/// Its own doc comment says not to call it from the tap callback, and a doc
/// comment is what the previous two rounds of this task demonstrated is not a
/// mechanism. The defect it guards against — a second app file calling the
/// synchronous walk from a callback — is exactly the one this whole round
/// exists to prevent, and it would look green everywhere.
///
/// `enqueue(_:onRecord:)` is the entry point for everyone else.
@Test func theSynchronousAXWalkIsCalledOnlyFromWithinAXObserver() throws {
    let callers = try codeLinesNaming("chain(at:", in: try appSourceFiles())
    let outside = callers.filter { !$0.location.hasPrefix("Soredemo/Capture/AXObserver.swift:") }
    #expect(outside.isEmpty,
            """
            the synchronous AX walk is called outside AXObserver:
            \(outside.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            Use AXObserver.enqueue(_:onRecord:). chain(at:source:) blocks its caller for as long as \
            the target application takes to answer, and on the tap callback thread a hung target \
            costs the whole pointer track — see AXObserver's header.
            """)
}

/// **The tap's own enabled flag must still be read, and read in one place.**
///
/// `InputObserver` polls `CGEvent.tapIsEnabled(tap:)` because the notification
/// channel it used to rely on was measured never to fire for a `.listenOnly`
/// tap: a deliberate callback stall swept 10/50/100/200/400/800/1600 ms
/// produced 0 `kCGEventTapDisabledByTimeout` notifications at every rung —
/// including the rungs where the flag showed the tap really was disabled —
/// with a `.defaultTap` control receiving the notification in the same run.
/// (Those rungs are sustained overload rather than a per-callback budget; that
/// correction is in `AXObserver`'s header and does not affect this scan, which
/// is about the channel and not the threshold.)
///
/// The poll is injectable (`tapIsEnabledOverride`) so the probe can drive it
/// without Input Monitoring, and that injection has a failure mode this scan
/// exists for: **delete the real read and every check stays green**, because
/// the probe always passes its own. Zero occurrences means nothing in the
/// shipping app ever asks the OS whether the tap is alive, which is precisely
/// the state that shipped an hour ago; more than one means two policies about
/// what "the tap is up" means.
///
/// It pins the count and the file, not the line — the read sits inside a
/// `lock.withLock` block whose surrounding text is not a stable thing to
/// assert on.
@Test func theTapsEnabledFlagIsReadExactlyOnceAndOnlyInTheObserver() throws {
    let readers = try codeLinesNaming("CGEvent.tapIsEnabled", in: try appSourceFiles())

    #expect(readers.count == 1,
            """
            expected exactly one app source line reading CGEvent.tapIsEnabled, found \(readers.count):
            \(readers.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            Zero means nothing in the shipping app asks the OS whether the tap is still alive, and \
            a .listenOnly tap is disabled WITHOUT the notification being delivered — so the blind \
            windows would all be found by a channel that was measured never to fire, and an empty \
            list of them reads as 'no gaps'.
            """)

    guard let reader = readers.first else { return }
    #expect(reader.location.hasPrefix("Soredemo/Capture/InputObserver.swift:"),
            "the tap's enabled flag is read at \(reader.location), not in InputObserver: \(reader.text)")
}

/// The same shape one row over: **`AXObserver`'s accessibility predicate is
/// injected, and the default has to stay the real reader.**
///
/// `AXObserver` takes `accessibilityIsGranted` as an argument so that
/// `hitTestsReturnedNothingWithoutAccessibility` can be exercised in both
/// directions by `§ 8.3` of the probe — which is a bare `swiftc` binary whose
/// TCC reads are attributed to the shell that launched it, so the real
/// predicate cannot answer about the right subject there at all.
///
/// That injection opens the same one-character hole the secure-input one does,
/// and this one is quieter: defaulting it to `{ true }` leaves every check in
/// this package and every check in the probe green, because none of them ever
/// evaluates the default — while a whole recording made without the
/// Accessibility grant would consist of empty chains attributed to *the
/// clicks*, reading as "nobody clicked on anything" rather than as
/// `Degradation.noElementIdentity`. That is the silence-is-not-a-value failure
/// this project has now written down four times.
///
/// Weaker than its neighbour in one respect, and deliberately: it pins the
/// **count** and the **file**, not the exact line, because the default
/// argument is too long to fit on one line and a check that required it to
/// would be a check about formatting. Zero occurrences means the default was
/// replaced by a constant; two means there is a second policy about what the
/// Accessibility grant implies, which is what `CapturePermissions` exists to
/// prevent.
@Test func theAccessibilityPredicateIsReadOnceAndOnlyInTheObserverThatInjectsIt() throws {
    let readers = try codeLinesNaming("CapturePermissions.status(of: .accessibility)",
                                      in: try appSourceFiles())

    #expect(readers.count == 1,
            """
            expected exactly one app source line reading CapturePermissions.status(of: \
            .accessibility), found \(readers.count):
            \(readers.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            Zero means AXObserver's accessibility predicate no longer defaults to the real reader, \
            and a recording made without the grant would attribute its empty chains to the clicks. \
            More than one means two policies about what that grant implies.
            """)

    guard let reader = readers.first else { return }
    #expect(reader.location.hasPrefix("Soredemo/Capture/AXObserver.swift:"),
            """
            the Accessibility grant is read at \(reader.location), not at AXObserver's injection \
            point:
            \(reader.text)
            """)
}

// MARK: - the content rule: what an observation log may never carry

/// **`ObservationLog`'s "what a record may contain" section, enforced.**
///
/// Task 11's Addition C required the content rule to be stated in the schema's
/// own documentation — it is, on `ObservationLog` — and asked whether the
/// mechanism that already enforces the keystroke half could cover the rest. It
/// can, for the same reason and with the same limits: **a producer cannot write
/// what it cannot read**, so banning the APIs that read user content is a
/// stronger statement than any rule about what the writer does with it.
///
/// The banned list is the ways this app could learn something a recording does
/// not already show:
///
///   * `kAXValueAttribute` and `kAXValueDescriptionAttribute` — the text
///     *inside* a control, as distinct from the label *on* it. This is the
///     natural next attribute for somebody extending `AXElementRecord`, and it
///     is the one that would put a half-typed password into a log while
///     `IsSecureEventInputEnabled()` was never consulted, because that
///     predicate governs the event tap and says nothing about an AX walk this
///     process performs itself.
///   * `kAXSelectedTextAttribute` / `kAXSelectedTextRangeAttribute` — the same
///     thing, narrowed to what is highlighted.
///   * `NSPasteboard` — the clipboard is ambient user content in its entirety,
///     and reading it is never a step towards describing a click.
///   * `kCGWindowName`, `CGWindowListCopyWindowInfo` and
///     `CGWindowListCreateDescriptionFromArray` — an enumeration of every
///     window on the machine, including every document **not** being recorded.
///     An earlier spike wrote 444 KB of window titles into a capture log.
///
/// **`kAXTitleAttribute` is deliberately absent from this list, and that is a
/// correction to the task brief rather than an omission.** The brief described
/// `AXChainRecord` as storing "roles and frames and deliberately not titles or
/// values"; it stores titles, on purpose, and `AXObserver.title(of:)` carries
/// the argument at the point of the read. A title belongs to something the
/// recording already shows and is what makes "the Save button" identifiable in
/// derivation. Values, keystrokes, the pasteboard and other applications'
/// windows are none of those things. The line this list draws is **in-frame**
/// versus **ambient**, not "text" versus "not text".
///
/// **The named gap: `SCWindow.title`.** ScreenCaptureKit's own window title is
/// not textually separable from `NSWindow.title`, which
/// `ProjectDocument.makeWindowControllers` sets legitimately on a window this
/// app owns. A `.title` entry here would fire on both. The live site — a debug
/// `print` in `SoredemoApp.swift` that named the picked window — was found by
/// writing this test and removed in the same commit; what remains is that a new
/// one would not be caught by this scan. It is the same class of known gap the
/// two scans above document at length, on the same side of the same boundary,
/// for the same reason.
@Test func noAppSourceReadsUserContent() throws {
    let found = try violationsEverywhere(
        banned: [
            // AX: the contents of a control, not the label on it.
            "kAXValueAttribute",
            "kAXValueDescriptionAttribute",
            "kAXSelectedTextAttribute",
            "kAXSelectedTextRangeAttribute",
            // The clipboard.
            "NSPasteboard",
            // Every window on the machine, including the unrecorded ones.
            "kCGWindowName",
            "CGWindowListCopyWindowInfo",
            "CGWindowListCreateDescriptionFromArray",
        ],
        in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            an app source can read content an observation log may never carry:
            \(found.joined(separator: "\n"))
            See ObservationLog's "What a record may contain" section, which is the schema's \
            own statement of this rule. A record carries instants, normalised coordinates, AX \
            roles, AX titles, frames, and counts. It never carries what a person typed, the \
            contents of a control, the pasteboard, or an enumeration of other applications' \
            windows.
            """)
}

/// **The bottleneck the content rule's closed attribute list depends on.**
///
/// `AXObserver.ReadableAXAttribute` makes `copyAttribute` closed: the set of AX
/// attributes this app can name is six cases, and `kAXValueAttribute` is not one
/// of them. That is the fix for the string-literal bypass —
/// `copyAttribute("AXValue", of: element)` was invisible to
/// `noAppSourceReadsUserContent`, because `SwiftSourceLexer.codeViewLines` blanks
/// string content by design.
///
/// **But a closed enum makes `copyAttribute` closed, not exclusive.** Nothing
/// about it stops a new file calling `AXUIElementCopyAttributeValue` directly
/// with `"AXValue" as CFString` — the original Critical, one call deeper, with
/// the enum intact, the scan silent and every gate green. This test is what
/// makes the enum a bottleneck rather than a convention: the raw AX read happens
/// at exactly one place, and that place is the one whose parameter type is the
/// permitted list.
///
/// Same shape as `theTapsEnabledFlagIsReadExactlyOnceAndOnlyInTheObserver`,
/// `theSecureInputPredicateIsReadExactlyOnceAndOnlyAtTheInjectionPoint` and
/// `theAccessibilityPredicateIsReadOnceAndOnlyInTheObserverThatInjectsIt`, and
/// for the same reason: a rule about where something may happen is only a rule
/// if the number of places is asserted.
///
/// **Zero is a failure too, and not a pedantic one.** `AXObserver`'s entire
/// element description — role, title, position, size, parent, children — is this
/// one call. Zero means the walk reads nothing and every `AXElementRecord` is
/// empty, which is byte-identical on disk to Accessibility not being granted.
@Test func theRawAXAttributeReadHappensAtExactlyOnePlace() throws {
    let readers = try codeLinesNaming("AXUIElementCopyAttributeValue(",
                                      in: try appSourceFiles())

    #expect(readers.count == 1,
            """
            expected exactly one app source line calling AXUIElementCopyAttributeValue, \
            found \(readers.count):
            \(readers.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            Zero means AXObserver stopped describing elements at all, which produces empty \
            AXElementRecords indistinguishable from Accessibility being ungranted. More than one \
            means the ReadableAXAttribute list is no longer the only way to name an attribute, \
            and a raw "AXValue" string at the second call site is invisible to \
            noAppSourceReadsUserContent — the exact bypass that list exists to close.
            """)

    guard let reader = readers.first else { return }
    #expect(reader.location.hasPrefix("Soredemo/Capture/AXObserver.swift:"),
            """
            the raw AX attribute read is at \(reader.location), not in AXObserver:
            \(reader.text)
            """)
    #expect(reader.text.contains("attribute.name"),
            """
            the one raw AX read does not go through ReadableAXAttribute.name:
            \(reader.text)
            It takes its attribute string from somewhere else, so the permitted list is no longer \
            what decides which attributes this app can read.
            """)
}

// MARK: - the needles must be able to fire

/// One call site per entry in `ambientBannedNames`, and it is **compiled**.
///
/// That is the whole mechanism: the compiler is what proves each spelling is a
/// real API on this SDK, and the scan below is what proves each needle still
/// matches one. `CCRandomGenerateBytse` fails the second check; a needle for an
/// API that does not exist fails the first.
///
/// `import ColorSync` is load-bearing and was found by this fixture failing to
/// compile without it: `CGDisplayCreateUUIDFromDisplayID` is declared in
/// `ColorSync.framework`, not CoreGraphics, despite the prefix — the same fact
/// `Minting.swift`'s header records at the top of the file.
let ambientConstructFixture = """
import ColorSync
import CommonCrypto
import CoreGraphics
import CryptoKit
import Foundation

func ambientProbe() {
    _ = Date()
    _ = Date.init()
    _ = Date.now
    _ = Date().timeIntervalSinceNow
    _ = Date.timeIntervalSinceReferenceDate
    _ = DispatchTime.now()
    _ = DispatchWallTime.now()
    _ = ContinuousClock()
    _ = SuspendingClock()
    _ = CFAbsoluteTimeGetCurrent()
    _ = mach_absolute_time()
    _ = mach_approximate_time()
    _ = mach_continuous_time()
    var ts = timespec(); _ = clock_gettime(CLOCK_MONOTONIC, &ts)
    var tv = timeval(); _ = gettimeofday(&tv, nil)
    _ = clock()
    _ = time(nil)
    _ = NSDate()
    _ = ProcessInfo.processInfo.systemUptime

    _ = UUID()
    _ = UUID.init()
    _ = NSUUID()
    var bytes = [UInt8](repeating: 0, count: 8)
    _ = CCRandomGenerateBytes(&bytes, 8)
    _ = Int.random(in: 0..<10)
    _ = [1, 2, 3].randomElement()
    _ = [1, 2, 3].shuffled()
    var generator = SystemRandomNumberGenerator(); _ = generator.next()
    _ = arc4random()
    _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
    _ = drand48()
    var state: [UInt16] = [0, 0, 0]; _ = seed48(&state)
    var wide: [UInt16] = [0, 0, 0, 0, 0, 0, 0]; lcong48(&wide)

    _ = SHA256.hash(data: Data())

    var size = 0; _ = sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
    _ = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())
}
"""

/// Typechecks a fixture with the real compiler, and fails loudly if it does not
/// compile. `-typecheck` rather than `-emit-object`: the question here is
/// whether every spelling in the fixture is real API on this SDK, and nothing
/// downstream reads a symbol.
func typecheck(_ source: String, named name: String) throws {
    let directory = URL(filePath: NSTemporaryDirectory())
        .appending(path: "appsource-fixture-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "\(name).swift")
    try source.write(to: file, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["swiftc", "-swift-version", "6", "-typecheck",
                         file.path(percentEncoded: false)]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    let errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    try #require(process.terminationStatus == 0,
                 "fixture \(name) did not typecheck — a needle names an API this SDK does not have:\n\(errorText)")
}

/// **THE RED THIS FILE DID NOT HAVE.**
///
/// The three ban scans above can only ever assert that nothing in `Soredemo/`
/// matches. A misspelled needle matches nothing either, so it is green forever,
/// and the only evidence any of them ever fired was probe output pasted into a
/// task report and then deleted. The package side has had this since Task 5
/// (`everyBannedSymbolIsStillWhatTheConstructEmits` and
/// `theScanRejectsAModuleThatReadsTheClockOrTheSystemRNG`, which between them
/// pin every entry in `bannedSymbols`); this side inherited the gap and then
/// grew by seven entries under it.
///
/// This closes it for the ambient list — the one Task 11.5 extended. The
/// CoreGraphics, keystroke and user-content lists still have no fixture; that
/// is recorded in ARCHITECTURE.md D6a rather than here.
@Test func everyAmbientNeedleMatchesACallSiteInACompiledFixture() throws {
    try typecheck(ambientConstructFixture, named: "AmbientConstructs")

    let lines = SwiftSourceLexer.codeViewLines(of: ambientConstructFixture)
    try #require(lines.count > 1, "the fixture is empty — this check would pass vacuously")

    let unmatched = ambientBannedNames.filter { needle in
        !lines.contains { $0.contains(needle) }
    }
    #expect(unmatched.isEmpty,
            """
            these needles match nothing in a fixture that calls every banned construct:
            \(unmatched.joined(separator: "\n"))
            Either the spelling is wrong — in which case the scan above has been green for a
            reason that has nothing to do with the app's sources — or the construct is missing
            from ambientConstructFixture, in which case the needle is unproven. A ban list is
            worth exactly the reason on each line and the evidence that the line can fire.
            """)
}
