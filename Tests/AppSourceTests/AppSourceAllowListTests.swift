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
        banned: [
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
            // C `time()`. Broad on purpose: Swift's camelCase means a lowercase
            // `time` immediately before `(` is close to unwritable by accident.
            "time(",
            "NSDate", "systemUptime",

            // ── ambient randomness ──────────────────────────────────────────
            "UUID(", "UUID.init",
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
        ],
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
