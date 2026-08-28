import CheckerLexer
import Foundation
import Testing

// MARK: - why these are package tests and not plugin rules
//
// The app lives in `Soredemo.xcodeproj`, which `Plugins/ArchitectureCheck` cannot
// see. These scans read `SwiftSourceLexer.codeViewLines`, so a banned name in a
// comment or a string literal does not fire; and they match by substring, not token
// equality, so the backtick-escaped spelling of a name matches too.

/// `<repo>/Core/Tests/AppSourceTests/<this file>` → `<repo>`. **Four levels, not three, since
/// the package moved into `Core/`**: the package root and the repository root stopped being
/// the same directory, and this scan is about the repository — it reaches `Soredemo/` and
/// `scripts/`, which are outside the package entirely. Move this file and the count is wrong;
/// `appSourceFiles()`'s own `#require` then fails loudly rather than scanning an empty set.
let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // AppSourceTests/
    .deletingLastPathComponent()   // Tests/
    .deletingLastPathComponent()   // Core/ — the PACKAGE root, not the repository's
    .deletingLastPathComponent()   // the repository root

/// The SwiftPM package's root. **Since the package moved into `Core/` these are two different
/// directories**, and nearly every scan in this file is about one or the other rather than
/// about "the root": `Sources/…` and `Tests/…` belong to the package, `Soredemo/` and
/// `scripts/` do not.
let packageRoot = repositoryRoot.appending(path: "Core")

/// The app's sources, and ONLY the app's sources. Scoped to `Soredemo/` because
/// `scripts/cross-boundary-digest-probe.swift` legitimately names `CGRect` and
/// calls `UUID()`, and `Core/Sources/` has its own enforcement in the plugin.
let appSourceDirectory = repositoryRoot.appending(path: "Soredemo")

/// Every `.swift` file under `Soredemo/`. A missing or empty tree is a FAILURE,
/// not a vacuous pass: an empty scan finds no violations and reads like a clean one.
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

/// Repository-relative path — the form the checker prints and the form that is
/// greppable from the root. `repositoryRoot.path` already ends in `/`; appending
/// a second one matched nothing and left every reported path absolute.
func pathRelativeToRepositoryRoot(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    // **Package files report PACKAGE-relative paths, app files repository-relative ones.**
    // Both were the same string until the package moved into `Core/`. Reporting
    // `Core/Sources/Capture/…` afterwards would have meant editing every one of the sixty-odd
    // path literals in these scans, and would have made a package-internal rule read as if it
    // knew where the package happened to be checked out inside a repository. It does not, and
    // should not: `Sources/Capture/CaptureSession.swift` is the file's name within its package.
    for root in [packageRoot, repositoryRoot] {
        let base = root.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
    }
    return path
}

/// One violation, in the `file:line:` form the checker prints. Each permitted path is
/// repository-relative and matched WHOLE, not by file name: matching on
/// `lastPathComponent` would keep the file permitted wherever it moved to.
///
/// A SET, not one path, since Phase 3A-3: `Sources/Headless` legitimately has two
/// environment boundaries — `Minting.swift` (ambient→package mappings) and
/// `MonotonicStopwatch.swift` (elapsed time) — and each is a file whose every member
/// reads the environment, so each whole-file permit still costs nothing. Every path is
/// `#require`d present individually, so a set cannot hide a stale entry behind a live
/// one. `violations(banned:permittedPath:in:)` below keeps the single-path spelling.
func violations(
    banned: [String],
    permittedPaths: Set<String>,
    in files: [URL]
) throws -> [String] {
    // Each permitted file must exist AT THAT PATH. A rename is the safe direction
    // — the file is then scanned and fails loudly — but the claim the test stands
    // for would be about a place that no longer exists.
    for path in permittedPaths.sorted() {
        let permitted = files.filter { pathRelativeToRepositoryRoot($0) == path }
        try #require(permitted.count == 1,
                     """
                     expected exactly one \(path), found \(permitted.count). \
                     If it moved, move the allow-list entry with it — the path is part \
                     of the claim, not an implementation detail of the scan.
                     """)
    }

    let scanned = files.filter { !permittedPaths.contains(pathRelativeToRepositoryRoot($0)) }
    try #require(!scanned.isEmpty,
                 "only the permitted files exist — nothing outside the allow-list was scanned")

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

/// The single-permitted-file spelling, for the scans that have exactly one boundary.
func violations(
    banned: [String],
    permittedPath: String,
    in files: [URL]
) throws -> [String] {
    try violations(banned: banned, permittedPaths: [permittedPath], in: files)
}

// MARK: - rule 5: the CoreGraphics bridge

/// The app-side half of the CoreGraphics-geometry ban (ARCHITECTURE.md D6), and since
/// Phase 3A-3 a **zero-permit** claim: no app source names one of the four types at all.
/// `CGGeometryBridge.swift` moved into `Sources/Headless`, so the app target holds no
/// conversion boundary of its own — it calls the bridge through `import Headless`, which
/// names no CG type at the call site. Mirrors `ArchitectureChecker.bannedCGTypes`, which
/// does the same for the package; a fifth banned type means editing both, unenforced.
@Test func noAppSourceNamesACoreGraphicsGeometryType() throws {
    let found = try violationsEverywhere(
        banned: ["CGRect", "CGPoint", "CGSize", "CGFloat"],
        in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            a CoreGraphics geometry type is named in the app target:
            \(found.joined(separator: "\n"))
            Convert in Sources/Capture/CGGeometryBridge.swift and pass the \
            package's own types onward; see ARCHITECTURE.md D3.
            """)
}

// MARK: - rule 3's app-side half: where non-determinism enters

/// The needles for rule 3's app-side half, at file scope so that
/// `everyAmbientNeedleMatchesACallSiteInACompiledFixture` can prove each one still
/// matches something — inline, a typo would be absent from everything.
let ambientBannedNames: [String] = [
    // ── ambient time ────────────────────────────────────────────────
    // `Date(` covers `Date()`, `Date(timeIntervalSinceNow:)` and `NSDate(`;
    // `Date.init` shares no substring with it.
    "Date(", "Date.init", "Date.now",
    "timeIntervalSinceNow", "timeIntervalSinceReferenceDate",
    "DispatchTime.now", "DispatchWallTime.now",
    // The clock TYPES, not just their `now` — obtaining one at all is the
    // step that has to happen somewhere auditable.
    "ContinuousClock", "SuspendingClock",
    "CFAbsoluteTimeGetCurrent",
    "mach_absolute_time", "mach_approximate_time",
    // Advances during sleep where `mach_absolute_time` does not (D2-4) — a
    // different reading, not a spelling variant, and just as ambient.
    "mach_continuous_time",
    // Subsumes `clock_gettime_nsec_np`.
    "clock_gettime", "gettimeofday",
    // C `clock()` — processor time, a different reading and still ambient. Broad
    // on purpose: it also fires on a hypothetical `refreshClock(`, the loud direction.
    "clock(",
    // C `time()`. Broad on purpose: Swift's camelCase means a lowercase
    // `time` immediately before `(` is close to unwritable by accident.
    "time(",
    "NSDate", "systemUptime",

    // ── ambient randomness ──────────────────────────────────────────
    "UUID(", "UUID.init",
    // The ObjC class, as ANY reference: `UUID(` above catches `NSUUID()` but not
    // `NSUUID.init`, a stored `let x: NSUUID`, or a cast.
    "NSUUID",
    // CommonCrypto's CSPRNG. The package side needs no entry — rule 1's import
    // allow-list keeps `import CommonCrypto` out of every package target.
    "CCRandomGenerateBytes",
    // The `drand48` family in one needle where the package side names four symbols.
    // It therefore also catches `erand48`, which the package side deliberately does
    // not ban; a text scan pays nothing for the wider match.
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
    // `Security`'s CSPRNG — a distinct source from `arc4random`, not a spelling of
    // it, and it links with plain `import Foundation`, so no import check flags it.
    "SecRandomCopyBytes",

    // ── ambient hashing ─────────────────────────────────────────────
    "SHA256",

    // ── ambient identity (boot epoch) ───────────────────────────────
    // `Minting.bootEpoch()` reads `kern.bootsessionuuid` through this call: not
    // time and not randomness, but the same shape — a value only the environment
    // can supply, entering the app at one audited place.
    "sysctlbyname",
    // A display's persistent identity, behind `Minting.displayUUID(of:)` — and the
    // only route from a `CGDirectDisplayID` to a `UUID`, so banning it is what makes
    // the `UUID(` ban unevadable for display identity.
    "CGDisplayCreateUUIDFromDisplayID",
]


/// Rule 3's app-side half, and since Phase 3A-3 a **strictly stronger claim than it
/// used to make**: no app source reads an ambient value AT ALL. `Minting.swift` moved
/// into `Sources/Headless`, so the app target no longer contains the boundary — it
/// asks `Headless` for minted values. A permitted-file scan would now name a path
/// outside the set it scans; zero-permit is what the arrangement actually supports,
/// and it happens to be the claim worth making.
///
/// The needles ban ambient NAMES (`Date(`, `UUID(`, `SHA256`, the clocks, `sysctl`),
/// not the word `Minting` — `ContentView` and `ProjectDocument` go on calling it.
/// Derived from `bannedSymbols` in `Tests/DeterminismTests/SymbolDeterminismTests
/// .swift`; a text scan is the weaker instrument, and the only one available here.
@Test func noAppSourceReadsAnAmbientValueAtAll() throws {
    let found = try violationsEverywhere(banned: ambientBannedNames, in: try appSourceFiles())

    #expect(found.isEmpty,
            """
            an app source read an ambient value directly:
            \(found.joined(separator: "\n"))
            Identifiers, timestamps and digests enter through Headless's Minting \
            and are passed onward as plain values — that is what makes derivation a \
            deterministic function of its input. The app target holds no boundary of \
            its own to widen.
            """)
}

/// The same scan over `Sources/Headless`, whose permitted boundary is
/// `MonotonicStopwatch.swift` — a file whose every member reads the clock, so the
/// whole-file permit costs nothing, the same granularity argument `Minting.swift`
/// already carries. The permit was `MP4Exporter.swift` through Phase 3A-1: a
/// general-purpose exporter in which two expressions needed a clock, so the permit
/// covered ~150 lines that did not — a future `UUID()` or wall-clock read anywhere
/// in it would have passed unaudited (ROADMAP named this exemption-scope creep).
/// `MP4Exporter` now holds a `MonotonicStopwatch` and never names a clock.
@Test func ambientTimeRandomnessAndHashingEnterHeadlessOnlyThroughMonotonicStopwatch() throws {
    // `headlessSourceFiles()` is declared in `HeadlessEntryRuleTests.swift`, this
    // same target — reused so the file list has exactly one definition.
    let found = try violations(
        banned: ambientBannedNames,
        permittedPaths: ["Sources/Compositing/MonotonicStopwatch.swift",
                         "Sources/Capture/Minting.swift"],
        in: try headlessSourceFiles())

    #expect(found.isEmpty,
            """
            an ambient value was read in Sources/Headless outside \
            MonotonicStopwatch.swift:
            \(found.joined(separator: "\n"))
            Sources/Headless legitimately touches wall time and the GPU, but an \
            unaudited ambient read defeats the point of naming the one file that \
            does — take a MonotonicStopwatch instead, and if the stopwatch cannot \
            express the need, widen that file, not the permit.
            """)
}

// MARK: - the keystroke ban: no allow-listed file, because there is no legitimate caller

/// Like `violations(banned:permittedPath:in:)`, but with **no permitted file**:
/// this rule is about something that may not happen anywhere. The only file that
/// would ever want an exemption is the one the rule is about.
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

/// **No code in this app can turn a key event into text at all** — a different and
/// stronger claim than "the shortcut filter refuses ordinary typing", because a filter
/// can be bypassed by a second code path and an unnameable API cannot. The list is the
/// ways a `CGEvent` or `NSEvent` yields characters, plus the manual `UCKeyTranslate`
/// route. Key CODES and modifier flags stay legal: they are what the filter matches on.
@Test func noAppSourceReadsKeystrokeText() throws {
    let found = try violationsEverywhere(
        banned: [
            // CoreGraphics: the event's own characters. The Swift spelling is
            // what bites — the C symbol below it does not exist in Swift, so it
            // guarded nothing on its own, and is kept only as documentation.
            "keyboardGetUnicodeString",
            "CGEventKeyboardGetUnicodeString",
            // The setter, banned too: a process that writes a keystroke's text is
            // holding that text, and a `.listenOnly` tap that modifies an event
            // is not listen-only.
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
        in: try firstPartySourceFiles())

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

/// Every code line under `Soredemo/` containing `needle`, in `file:line:` form with
/// the line's own text attached. Read through `codeViewLines`, so the doc comment
/// describing a required call cannot itself satisfy the requirement.
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

/// **The other scans say where something may not happen; this one says something
/// must.** `InputObserver`'s secure-input predicate is injected so the interval logic
/// can be tested without a password field, and defaulting that parameter to
/// `{ false }` would disable the guarantee with every other check still green. So both
/// halves are pinned: exactly one read, and it is the injection point's default.
@Test func theSecureInputPredicateIsReadExactlyOnceAndOnlyAtTheInjectionPoint() throws {
    let readers = try codeLinesNaming("IsSecureEventInputEnabled", in: try firstPartySourceFiles())

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

/// The line number out of a `codeLinesNaming` location (`path:line`), for the
/// ordering checks below: position in the file is what a text scan can see.
func lineNumber(of location: String) -> Int {
    Int(location.split(separator: ":").last.map(String.init) ?? "") ?? -1
}

/// `startPolling()` is called exactly once, inside `start(onObservation:)`, after the
/// tap is created and enabled.
@Test func theTapPollIsStartedByStartAndNotOnlyDefined() throws {
    let files = try firstPartySourceFiles()
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
    #expect(call.location.hasPrefix("Sources/Capture/InputObserver.swift:"),
            "startPolling() is called from \(call.location), not from InputObserver")

    // The three landmarks the call must sit between, each named once so a
    // rename fails this test loudly rather than silently widening it.
    //
    // **Scoped to `InputObserver.swift`, not to every app source.** This test makes an
    // ORDERING claim about one file — that `startPolling()` sits between `start()` and
    // `stop()` in that file — and a landmark from another file cannot participate in it.
    // Searching everywhere was fine while `stop()` was unique in the app; it stopped being
    // so when `PointerSampler` and `WindowFollower` arrived, each with the timer teardown
    // that method name is correct for. Widening the match to something like
    // `InputObserver.stop` would have been the wrong repair: the uniqueness that matters is
    // within the file whose line numbers are being compared.
    let observerFile = files.filter {
        pathRelativeToRepositoryRoot($0) == "Sources/Capture/InputObserver.swift"
    }
    try #require(observerFile.count == 1, "InputObserver.swift was not among the scanned files")
    let startDeclaration = try codeLinesNaming("public func start(onObservation", in: observerFile)
    let stopDeclaration = try codeLinesNaming("public func stop()", in: observerFile)
    let tapCreate = try codeLinesNaming("CGEvent.tapCreate", in: observerFile)
    let tapEnabled = try codeLinesNaming("CGEvent.tapEnable(tap: created", in: observerFile)
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

/// `AXUIElementSetMessagingTimeout` is the clever-looking answer D2-18 rejects: it
/// trades an unbounded wait for a timeout failure, which is the same data loss as a
/// queue drop, still on the callback thread. Prose alone stops nobody from taking it.
@Test func theRejectedAXTimeoutIsNotReachedFor() throws {
    let found = try violationsEverywhere(banned: ["AXUIElementSetMessagingTimeout"],
                                         in: try firstPartySourceFiles())
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

/// **Nothing counts straddling observations yet**, which is why the tautology
/// register's first row cannot fail. So assert the counter's ABSENCE: when this fires,
/// write the real cross-check and delete this test in the same commit — do not exempt.
@Test func nothingInTheAppCountsStraddlingObservationsYet() throws {
    let found = try violationsEverywhere(banned: ["straddl", "Straddl"],
                                         in: try firstPartySourceFiles())
    #expect(found.isEmpty,
            """
            an app source now names a straddle, in code rather than in prose:
            \(found.joined(separator: "\n"))
            The tautology register's first row exists because no such counter existed. If this is \
            that counter, the register row is now falsifiable and must be rewritten to cross-check \
            it against the log's own straddling records — and this test deleted in the same commit. \
            Exempting it puts the register back where it was, minus the note saying so.
            """)
}

/// **`AXObserver.chain` is the synchronous walk, and only `AXObserver` may call it.**
/// A second app file calling it from the tap callback would look green everywhere, and
/// its own doc comment is not a mechanism. `enqueue(_:onRecord:)` is the entry point.
@Test func theSynchronousAXWalkIsCalledOnlyFromWithinAXObserver() throws {
    let callers = try codeLinesNaming("chain(at:", in: try firstPartySourceFiles())
    let outside = callers.filter { !$0.location.hasPrefix("Sources/Capture/AXObserver.swift:") }
    #expect(outside.isEmpty,
            """
            the synchronous AX walk is called outside AXObserver:
            \(outside.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
            Use AXObserver.enqueue(_:onRecord:). chain(at:source:) blocks its caller for as long as \
            the target application takes to answer, and on the tap callback thread a hung target \
            costs the whole pointer track — see AXObserver's header.
            """)
}

/// **The tap's own enabled flag must still be read, and read in one place.** The
/// `kCGEventTapDisabledByTimeout` notification was measured never to fire for a
/// `.listenOnly` tap — 0 notifications at every rung of a swept callback stall — so
/// `InputObserver` polls `CGEvent.tapIsEnabled` instead. That poll is injectable, so
/// deleting the real read leaves every check green. Pins the count and file, not line.
@Test func theTapsEnabledFlagIsReadExactlyOnceAndOnlyInTheObserver() throws {
    let readers = try codeLinesNaming("CGEvent.tapIsEnabled", in: try firstPartySourceFiles())

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
    #expect(reader.location.hasPrefix("Sources/Capture/InputObserver.swift:"),
            "the tap's enabled flag is read at \(reader.location), not in InputObserver: \(reader.text)")
}

/// `AXObserver`'s accessibility predicate is injected the same way, and defaulting it
/// to `{ true }` leaves every check green while a recording made without the grant
/// becomes empty chains attributed to the clicks rather than
/// `Degradation.noElementIdentity`. Pins the count and the file, not the exact line.
@Test func theAccessibilityPredicateIsReadOnceAndOnlyInTheObserverThatInjectsIt() throws {
    let readers = try codeLinesNaming("CapturePermissions.status(of: .accessibility)",
                                      in: try firstPartySourceFiles())

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
    #expect(reader.location.hasPrefix("Sources/Capture/AXObserver.swift:"),
            """
            the Accessibility grant is read at \(reader.location), not at AXObserver's injection \
            point:
            \(reader.text)
            """)
}

// MARK: - the content rule: what an observation log may never carry

/// **`ObservationLog`'s "what a record may contain" section, enforced** by the same
/// mechanism as the keystroke ban: a producer cannot write what it cannot read, so the
/// ban is on the APIs that read user content — a control's contents, selected text,
/// the pasteboard, every window on the machine. `kAXTitleAttribute` is deliberately
/// absent; the line drawn is **in-frame** versus **ambient**, not text versus not-text.
/// Named gap: `SCWindow.title` is not textually separable from the `NSWindow.title`
/// this app sets legitimately on its own window.
@Test func noAppSourceReadsUserContent() throws {
    let found = try violationsEverywhere(
        banned: [
            // AX: the contents of a control, not the label on it.
            "kAXValueAttribute",
            "kAXValueDescriptionAttribute",
            "kAXSelectedTextAttribute",
            "kAXSelectedTextRangeAttribute",
            // The clipboard's READERS. `NSPasteboard` itself is handled below, because
            // writing to it and reading from it are different acts and only one of them is
            // what this rule is about — but the readers stay banned everywhere, including
            // inside the one place the type is allowed to appear.
            ".readObjects(",
            ".pasteboardItems",
            ".string(forType:",
            ".data(forType:",
            ".propertyList(forType:",
            // Every window on the machine, including the unrecorded ones.
            "kCGWindowName",
            "CGWindowListCreateDescriptionFromArray",
        ],
        in: try firstPartySourceFiles())

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

/// **`NSPasteboard` appears exactly once, and it writes.**
///
/// The content rule above bans the APIs that READ user content, and the clipboard is one of
/// them. Copying a finished export is the opposite act: it puts a file this app just wrote onto
/// the pasteboard so that pasting into Mail or Slack attaches the video. Banning the type
/// outright would forbid that too, and narrowing the ban to reading METHODS would leave the
/// type reachable everywhere — so the type is allowed at exactly one line, named here, while
/// every reading member stays banned everywhere including there.
///
/// **One line, not one file.** A file-shaped exemption is a hole the size of a file; a count of
/// one fails the moment a second use appears, which is when somebody should have to come here
/// and say what it is for. Same shape as the accessibility-grant reader above, and the same
/// reason `ProbeCoverageTests` names its single exemption in one place.
private let theOnlyPasteboardUse = "Soredemo/Export/ExportQueue.swift"

@Test func theClipboardIsWrittenInExactlyOnePlaceAndNeverRead() throws {
    let uses = try violationsEverywhere(banned: ["NSPasteboard"], in: try firstPartySourceFiles())
    #expect(uses.count == 1, """
            expected exactly one app source line naming NSPasteboard, found \(uses.count):
            \(uses.joined(separator: "\n"))
            The clipboard is on the content rule's banned list because it READS what a person \
            has copied. One line writing a finished export to it is the exception; a second use \
            is somebody adding a reason that has not been written down.
            """)
    guard let use = uses.first else { return }
    #expect(use.hasPrefix("\(theOnlyPasteboardUse):"), """
            NSPasteboard is named at \(use), not in the export queue where the one permitted \
            use lives. If this moved, move the constant with it rather than widening the rule.
            """)
}

/// **The bottleneck the content rule's closed attribute list depends on.**
/// `ReadableAXAttribute` makes `copyAttribute` closed but not exclusive: a direct
/// `AXUIElementCopyAttributeValue` with `"AXValue" as CFString` is invisible to the
/// scan above, because `codeViewLines` blanks string content. Zero is a failure too —
/// empty `AXElementRecord`s are byte-identical to Accessibility being ungranted.
@Test func theRawAXAttributeReadHappensAtExactlyOnePlace() throws {
    let readers = try codeLinesNaming("AXUIElementCopyAttributeValue(",
                                      in: try firstPartySourceFiles())

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
    #expect(reader.location.hasPrefix("Sources/Capture/AXObserver.swift:"),
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


// MARK: - the one narrowed exception, and its shape

/// **`CGWindowListCopyWindowInfo` is banned everywhere but one file, and its SHAPE is
/// pinned there.** It was on `noAppSourceReadsUserContent`'s list outright, for a good
/// reason: called the usual way — `.optionAll` with `kCGNullWindowID` — it enumerates every
/// window on the machine, including ones this recording is not capturing, and each entry
/// carries `kCGWindowName`.
///
/// Following a window that moves mid-recording needs one thing that no permitted API
/// supplies: the LIVE frame of the single window already being recorded. `SCWindow.frame`
/// is a snapshot from the content query and never updates, which is the defect
/// `WindowFollower` exists to fix. So the ban is narrowed rather than lifted: the call may
/// appear only in `CGGeometryBridge`, and only in the scoped shape.
///
/// The two assertions below are the whole exception. The first keeps the call from
/// spreading; the second keeps it from widening in place — an enumerating variant in the
/// permitted file would otherwise pass silently. `kCGWindowName` stays banned everywhere,
/// including there, so no name can be read even from the one window that may be looked up.
@Test func theScopedWindowLookupIsConfinedAndStaysScoped() throws {
    let bridge = "Sources/Capture/CGGeometryBridge.swift"
    let escaped = try violations(banned: ["CGWindowListCopyWindowInfo"],
                                 permittedPaths: [bridge],
                                 in: try firstPartySourceFiles())
    #expect(escaped.isEmpty, """
        the scoped window lookup appeared outside \(bridge):
        \(escaped.joined(separator: "\n"))
        Route the read through CGGeometryBridge.windowBounds; see its comment for why the \
        exception is drawn this narrowly.
        """)

    // `bridge` is a package-relative path, like every other literal in these scans.
    let text = try String(contentsOf: packageRoot.appending(path: bridge), encoding: .utf8)
    let callLines = SwiftSourceLexer.codeViewLines(of: text)
        .filter { $0.contains("CGWindowListCopyWindowInfo") }
    #expect(callLines.count == 1,
            "expected exactly one call in \(bridge), found \(callLines.count)")
    let call = try #require(callLines.first)
    #expect(call.contains(".optionIncludingWindow"),
            "the permitted call must be scoped to one window: \(call)")
    for widening in ["optionAll", "optionOnScreenOnly", "kCGNullWindowID"] {
        #expect(!call.contains(widening),
                "the permitted call widened to an enumeration via \(widening): \(call)")
    }
}

// MARK: - the needles must be able to fire

/// One call site per entry in `ambientBannedNames`, and it is **compiled**: the
/// compiler proves each spelling is real API on this SDK, the scan below proves each
/// needle still matches one. `import ColorSync` is load-bearing —
/// `CGDisplayCreateUUIDFromDisplayID` is declared there, not in CoreGraphics.
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

/// Typechecks a fixture with the real compiler and fails loudly if it does not
/// compile. `-typecheck` rather than `-emit-object`: the question is whether every
/// spelling is real API on this SDK, and nothing downstream reads a symbol.
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

/// **THE RED THIS FILE DID NOT HAVE.** A misspelled needle matches nothing, so a ban
/// scan asserting nothing matches is green forever. Closed here for the ambient list;
/// the other three lists still have no fixture, recorded in ARCHITECTURE.md D6a.
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

// MARK: - D6a-V — unexercised public API, counted by the lexer and not by grep

/// Every `.swift` file under `Sources/` AND `Soredemo/` — the whole first-party
/// tree. A deadness verdict needs both halves: `TimeRange` lives in
/// `Sources/Timeline` and its would-be callers live in `Sources/Graph`.
func firstPartySourceFiles() throws -> [URL] {
    var files: [URL] = []
    // One from each root, which is what "first party" now spans.
    for root in [packageRoot.appending(path: "Sources"),
                 repositoryRoot.appending(path: "Soredemo")] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                                      "cannot enumerate \(root.path(percentEncoded: false))")
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
    }
    try #require(!files.isEmpty, "no first-party sources found — this scan would pass vacuously")
    return files.sorted { $0.path < $1.path }
}

/// **`docs/ARCHITECTURE.md`'s D6a-V table as a machine check** — a table whose whole
/// meaning is a set of call-site counts must not be maintained by hand. Counted with
/// `codeLinesNaming` and never `grep`, so a doc comment and the checker's own exemption
/// list do not count as usage; and only uses OUTSIDE the declaring file count, since
/// `shadowRadius`'s six occurrences are all inside its own type.
@Test func theUnexercisedPublicAPITableMatchesTheTree() throws {
    let files = try firstPartySourceFiles()

    let expectations: [(needle: String, declaringFile: String, expected: Int, claim: String)] = [
        ("Minting.now()", "Sources/Capture/Minting.swift", 0,
         "a wall-clock reading callers can take"),
        // The needle is the ARGUMENT label at a call site, comma and all. Bare `fileExtension:`
        // also matched `SubtitleFile.Format.fileExtension`'s own declaration in another module —
        // a different API with the same word, which this table has no opinion about. The comma
        // is what distinguishes `addMedia(data, fileExtension: x)` from `var fileExtension:`.
        (", fileExtension:", "Soredemo/Project/ProjectDocument.swift", 0,
         "media can be added under a minted name"),
        // The needle is the PROPERTY ACCESS, not the bare word. `CALayer` has a `shadowRadius`
        // too, and `CameraSelfView` sets it on the self-view panel's layer — a different API in
        // a different framework that this table has no opinion about, counted as a third use of
        // `RenderPlan`'s. Same collision as `fileExtension:` above and the same fix: name the
        // thing being claimed about. Both real uses read it off a style.
        ("style.shadowRadius", "Sources/Render/RenderPlan.swift", 2,
         "the stage draws a shadow AND a person can change it. 0 → 1 was the recorder-parity "
         + "decision (2026-08-19) making CoreImageFrameRenderer.shadowImage read it; 1 → 2 is "
         + "the style picker (2026-08-21) carrying it through StageStyleModel.apply, which "
         + "rebuilds the whole struct so its validating initialiser runs once per change"),
        ("blockingFailures()", "Sources/Capture/CapturePermissions.swift", 1,
         "callers can ask what blocks recording. 0 → 1 is the permission page (2026-08-23): "
         + "the menu bar item opens it on launch when something a recording needs is missing, "
         + "which is exactly the question this function answers"),
        ("noMicrophoneTrack", "Sources/Capture/CapturePermissions.swift", 0,
         "a denied microphone degrades mildly — measured false, so nothing produces it"),
        ("TimeRange", "Sources/Timeline/TimeRange.swift", 0,
         "an epoch-less interval type is useful — its stated first caller moved to HostRange"),
    ]

    for e in expectations {
        // `codeLinesNaming` blanks comments and strings but matches bare substrings, so
        // `CMTimeRange(start:...)` counted as a use of `TimeRange`. Require the character
        // before the match to be a non-identifier one.
        let uses = try codeLinesNaming(e.needle, in: files)
            .filter { !$0.location.hasPrefix(e.declaringFile) }
            .filter { line in
                var searchRange = line.text.startIndex..<line.text.endIndex
                while let found = line.text.range(of: e.needle, range: searchRange) {
                    let precededByIdentifierCharacter = found.lowerBound > line.text.startIndex
                        && (line.text[line.text.index(before: found.lowerBound)].isLetter
                            || line.text[line.text.index(before: found.lowerBound)].isNumber
                            || line.text[line.text.index(before: found.lowerBound)] == "_")
                    if !precededByIdentifierCharacter { return true }
                    searchRange = found.upperBound..<line.text.endIndex
                }
                return false
            }
        #expect(uses.count == e.expected, """
            D6a-V says `\(e.needle)` has \(e.expected) use(s) outside \(e.declaringFile); \
            the tree has \(uses.count).
            It claims: \(e.claim)
            \(uses.map { "  \($0.location): \($0.text)" }.joined(separator: "\n"))
            Update docs/ARCHITECTURE.md's D6a-V table in the same commit that moves this number.
            """)
    }
}

/// **D6a-N's checkable rows, pinned:** does each component some sentence claims exists
/// appear in CODE, or only in the sentences claiming it? Deliberately a curated list
/// and not the general rule — "every occurrence falls inside comments" was measured at
/// 72 candidates, mostly rejected alternatives, and a 97%-false-positive gate gets
/// switched off.
@Test func componentsAssertedInProseDoNotExistOnlyInProse() throws {
    let appFiles = try appSourceFiles()

    // `Inspector`: **this assertion is inverted, and the inversion is the point.**
    // `StageWindow.swift`'s header claimed an inspector while the word appeared exactly
    // once in `Soredemo/` — inside that claim. The tripwire fired when `review-ui` built a
    // real one, which is what it was for; D6a-N's row was retired in the same commit. It
    // now guards the opposite direction: the sentence must not outlive the code again.
    let inspectorInCode = try codeLinesNaming("Inspector", in: appFiles)
    #expect(!inspectorInCode.isEmpty, """
        `Inspector` appears in app PROSE but no longer in app CODE — the exact fault D6a-N
        recorded, in the other direction. Either restore the inspector or delete the sentences
        claiming one, in the same commit.
        """)
    #expect(inspectorInCode.contains { $0.text.contains("FramingReviewInspector") }, """
        the inspector in code is not the review surface. `review-ui`'s row is satisfied by an
        inspector that shows each framing decision's origin, review state and reason — not by
        any view that happens to be called one.
        """)

    // `SoredemoCore` must never be a TARGET, and this nail carries its reason rather
    // than its state: the name belongs to the Foundation-only PRODUCT, so a directory
    // of it would put app logic inside an identity defined by excluding it.
    let coreTargetExists = FileManager.default.fileExists(
        atPath: packageRoot.appending(path: "Sources/SoredemoCore").path(percentEncoded: false))
    #expect(!coreTargetExists, """
        `Sources/SoredemoCore` exists as a directory. `SoredemoCore` is the Foundation-only product
        name; a target under it would break ARCHITECTURE.md rule 1. Platform-touching code belongs in
        the `Headless` target instead. If this is deliberate, the five documents above change in the
        same commit.
        """)
}

// MARK: - the Settings scene, which renders empty in the wrong container

/// **A `Settings` scene's content must not be a `NavigationSplitView`.**
///
/// Measured on the shipping app 2026-08-26: the settings window opened and showed nothing at
/// all. A `Settings` scene sizes itself to its content's ideal size; a `NavigationSplitView`
/// has none of its own, and a `.frame` applied outside it does not give it one. Apple's own
/// guidance is that a settings scene groups its panes with a `TabView`, which is also what
/// supplies the centred tab bar every Mac settings window has.
///
/// **Scoped to the file the scene names**, not to the whole app: `StageWindow` is a
/// `NavigationSplitView` and should be — it is a document window, which is the case the
/// container is for. What is banned is that container in THIS window.
///
/// A scan rather than a test, because the app target has no test target and a SwiftUI `body`
/// is not something the cross-boundary probe can run. It reads the code view, so a
/// `NavigationSplitView` named in a comment — including the one in the paragraph above — does
/// not fire.
@Test func theSettingsSceneDoesNotUseANavigationSplitView() throws {
    let settingsFiles = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Settings/SettingsWindow.swift" }
    try #require(settingsFiles.count == 1, """
        Soredemo/Settings/SettingsWindow.swift is not where it was. This scan names it, so a rename \
        has to move the name with it rather than turning the check off.
        """)
    let found = try codeLinesNaming("NavigationSplitView", in: settingsFiles)
    #expect(found.isEmpty, """
        SettingsWindow builds a NavigationSplitView at \(found.map(\.location).joined(separator: ", ")).
        A `Settings` scene sizes to its content's ideal size and a split view has none, so the \
        window renders empty — measured on the shipping app. Group the panes with a `TabView`, \
        which is what the scene styles as a settings window.
        """)
}

/// And the scene really is built from `Settings`, so the check above is about the window a
/// person opens with ⌘, rather than about a file nothing presents.
@Test func theSettingsSceneIsAStandardSettingsScene() throws {
    let appFiles = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/App/SoredemoApp.swift" }
    try #require(appFiles.count == 1)
    let scenes = try codeLinesNaming("SettingsWindow(", in: appFiles)
    #expect(!scenes.isEmpty, """
        SoredemoApp never constructs SettingsWindow, so ⌘, opens something else — or nothing — \
        and the container check above is about a view no scene presents.
        """)
}

/// **No app source reaches a private selector by name.**
///
/// `NSApp.sendAction(Selector("showSettingsWindow:"))` was how a `Settings` scene was opened
/// before `SettingsLink` existed. Since macOS 14 it logs `Please use SettingsLink for opening
/// the Settings scene` at runtime — observed on this app on 2026-08-26 — and is documented as
/// no longer working. It is easy to reach for again, because it is what every older answer
/// says and because it compiles and fails silently.
///
/// **The needle is the CALL SHAPE, not the selector name, and the first version of this check
/// was vacuous because of it.** `violations` reads `SwiftSourceLexer`'s code view, which blanks
/// string-literal CONTENT so that a banned name mentioned in prose does not fire — and a
/// selector name lives inside a string literal by nature, so `"showSettingsWindow:"` was
/// invisible to the scan. Measured: putting the old call back left the check green. Banning
/// `sendAction(Selector(` bans the shape instead, which is code and which the code view sees.
///
/// Nothing legitimate in this app builds a selector at runtime; the one that did is gone. A
/// future case that genuinely needs one names itself here.
@Test func noAppSourceReachesAPrivateSelectorByName() throws {
    let found = try violations(banned: ["sendAction(Selector("], permittedPaths: [],
                               in: try appSourceFiles())
    #expect(found.isEmpty, """
        \(found.joined(separator: "\n"))
        A selector built from a string is a private API reached by name: it compiles, it is not \
        checked, and it fails silently when the framework moves. The Settings case is the one \
        this app had — use `SettingsLink`, which is what the runtime warning names.
        """)
}

/// **Exactly one control in this app defers its preview refresh to the end of a drag.**
///
/// Every other one publishes to `StageCompositor` and asks for a redraw on every change, so a
/// paused preview moves with the thumb. That was not true until 2026-08-26: the camera's six
/// sliders, the style sliders and the camera's two drag handles all committed on release, and
/// what a person saw was a control whose number moved while the picture did not — until they
/// let go, or pressed play. Both of the reasons written down for it were wrong by then. A style
/// commit does not rebuild an `AVVideoComposition`, and `StageWindow`'s own redraw task says so;
/// and a seek per drag tick is safe, because AVPlayer supersedes a seek that is already in
/// flight rather than queueing it.
///
/// The exception is the zoom Amount slider, which is different in kind: it re-derives the zoom
/// BLOCKS and rebuilds the camera's baked path, which is work rather than a redraw. It names
/// itself here so a second exception has to be argued rather than added.
///
/// Read through the code view, so the paragraphs above naming the modifier do not fire.
@Test func onlyTheZoomAmountSliderDefersItsPreviewRefresh() throws {
    let deferred = try codeLinesNaming("onEditingChanged", in: try appSourceFiles())
    // The FILE and the COUNT, not the line: a line number moves with every edit above it, and a
    // check that has to be renumbered is a check people renumber without reading.
    let files = Set(deferred.map { $0.location.split(separator: ":").first.map(String.init) ?? "" })
    #expect(deferred.count == 1 && files == ["Soredemo/Editor/StageWindow.swift"], """
        \(deferred.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        A control that commits on release leaves a paused preview showing the old picture while \
        its own number moves. If this one genuinely needs to — because it re-derives something \
        rather than redrawing — say so beside the zoom Amount slider and name it here.
        """)
}

/// **The editor's opening size is a floor, not a one-shot.**
///
/// It was a courtesy applied once ever, guarded by a `UserDefaults` flag, and it failed twice
/// for two different reasons — the flag written before the frame was applied, and then the
/// scene changing identity so AppKit restored a 900 × 512 frame from a new autosave key with
/// the flag already spent. Both are in `sizeGenerouslyOnFirstOpen`'s header.
///
/// A flag is spent by things that are not a decision. The rule is a property now: the window
/// never opens smaller than a share of its screen, growing what is under and leaving what is
/// over. This checks that no flag has crept back in, because the obvious repair to "it opens
/// too big for me" is to add one.
@Test func theEditorsOpeningSizeIsNotGuardedByAFlag() throws {
    let files = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/App/WindowConfigurator.swift" }
    try #require(files.count == 1, "WindowConfigurator.swift is not where this scan names it")
    let found = try codeLinesNaming("UserDefaults", in: files)
    #expect(found.isEmpty, """
        \(found.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        A one-shot flag is how this failed twice: it is spent by things that are not a person's \
        decision, and there is no second chance in it. If the window should stop growing, change \
        `openingFraction` or the comparison — do not add a flag.
        """)
}

/// **The menu bar panel's two settings rows are built from one shape.**
///
/// Frame rate and Countdown are the same kind of row — an icon, a label, a popup — and they
/// were built two different ways: one a `labelsHidden` picker pinned to 76 points, the other a
/// `Picker(label:)` whose popup sized itself to its widest entry. They came out different
/// lengths, which is what a person sees. Matching the two numbers would have left the two
/// shapes free to drift apart again, so there is one row builder and both rows go through it.
///
/// Checked as "exactly one popup style in this file", which is the mechanical consequence: a
/// second row that built its own popup would have to declare one.
@Test func theMenuBarPanelHasOneSettingsRowShape() throws {
    let panel = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Recording/MenuBarRecorder.swift" }
    try #require(panel.count == 1, "MenuBarRecorder.swift is not where this scan names it")
    let popups = try codeLinesNaming("pickerStyle(.menu)", in: panel)
    #expect(popups.count == 1, """
        \(popups.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Two rows declaring their own popup is how Frame rate and Countdown came to be different \
        lengths. Route the new row through `settingRow(icon:title:selection:options:)`.
        """)
}

/// **The full-screen presentation options are complete, or AppKit throws.**
///
/// `autoHideToolbar` must be accompanied by `autoHideMenuBar`, and `autoHideMenuBar` by
/// `autoHideDock` or `hideDock`. An incomplete set is not a partial effect — it is an
/// exception at the moment a person enters full screen, which is the worst place for one.
/// The rule is documented and easy to half-remember, so it is checked rather than recalled.
@Test func theFullScreenPresentationOptionsAreALegalCombination() throws {
    let files = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/App/WindowConfigurator.swift" }
    try #require(files.count == 1, "WindowConfigurator.swift is not where this scan names it")
    let text = try String(contentsOf: files[0], encoding: .utf8)
    let code = SwiftSourceLexer.codeViewLines(of: text).joined(separator: "\n")

    guard code.contains(".autoHideToolbar") else { return }   // nothing to check
    #expect(code.contains(".autoHideMenuBar"), """
        .autoHideToolbar is set without .autoHideMenuBar. AppKit requires the pair; the toolbar \
        will not hide and entering full screen raises an exception.
        """)
    #expect(code.contains(".autoHideDock") || code.contains(".hideDock"), """
        .autoHideMenuBar is set without a Dock option. AppKit requires one of .autoHideDock or \
        .hideDock alongside it.
        """)
    // And they are undone on the way out, so leaving full screen does not leave the menu bar
    // hiding over an ordinary desktop.
    #expect(code.contains("didExitFullScreenNotification"), """
        nothing restores the presentation options when the window leaves full screen.
        """)
}

/// **The editor scene asks for no default size, because that disables full screen.**
///
/// Measured 2026-08-26 in an isolated SwiftUI `Window` scene, reading the window's own
/// `collectionBehavior` back after it settled: with `.defaultSize` it is
/// `primary | fullScreenNone | moveToActiveSpace`; without it, `primary | fullScreenPrimary |
/// moveToActiveSpace`. `.fullScreenNone` is what makes the green button show a "+" and a tiling
/// menu with no Full Screen row, and it is re-asserted after every SwiftUI update, so removing
/// it from a view does not stick.
///
/// The editor's opening size comes from `sizeGenerouslyOnFirstOpen` instead, which gives it most
/// of the screen without telling AppKit the window is fixed.
///
/// Scoped to the app's scene file and read through the code view, so this paragraph does not
/// fire. The Permissions window is a different case — it is genuinely fixed-size and has no
/// business going full screen — and it does not use this modifier either.
@Test func noWindowSceneAsksForADefaultSize() throws {
    let files = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/App/SoredemoApp.swift" }
    try #require(files.count == 1, "SoredemoApp.swift is not where this scan names it")
    let found = try codeLinesNaming(".defaultSize(", in: files)
    #expect(found.isEmpty, """
        \(found.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        A scene with a default size is marked `.fullScreenNone` by SwiftUI, and the green button \
        then offers tiling and nothing else. Size the window from `WindowConfigurator` instead.
        """)
}

// MARK: - Hiding the desktop's icons: the obligation, and the four ways it can be dropped

/// The one file allowed to write another application's preferences and kill its process.
private let theOnlyDesktopIconsFile = "Soredemo/Recording/DesktopIcons.swift"

private func desktopIconsFile() throws -> [URL] {
    let files = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == theOnlyDesktopIconsFile }
    try #require(files.count == 1, """
        \(theOnlyDesktopIconsFile) is not where these scans name it. A rename has to move the \
        name with it rather than turning four checks off at once.
        """)
    return files
}

/// **The debt is recorded before the write that creates it, and cleared after the restore that
/// pays it.** Both orderings are the same ordering, and this project has already shipped it
/// backwards once: `editorFirstOpenSizeApplied` was written before the frame it was recording,
/// so anything failing in between spent a courtesy that had never been given.
///
/// Backwards here is worse than a window opening small. Setting the flag after the preference
/// write leaves a window in which the desktop is hidden and nothing knows a restore is owed;
/// clearing it before the restore forgets an obligation that has not been met. Either way
/// somebody is left with a Mac whose desktop icons are gone and no way to connect that to a
/// screen recorder they used yesterday.
@Test func theDesktopIconDebtIsRecordedBeforeTheWriteAndClearedAfterTheRestore() throws {
    let files = try desktopIconsFile()
    let text = try String(contentsOf: files[0], encoding: .utf8)
    let lines = SwiftSourceLexer.codeViewLines(of: text)
    func firstLine(containing needle: String, after start: Int = 0) throws -> Int {
        let index = lines.dropFirst(start).firstIndex { $0.contains(needle) }
        return try #require(index, "no code line contains \(needle) in \(theOnlyDesktopIconsFile)")
    }
    // hide(): the flag goes down before the preference is written.
    let owedSet = try firstLine(containing: "set(true, forKey: owedKey)")
    let hidWritten = try firstLine(containing: "false as CFBoolean")
    #expect(owedSet < hidWritten, """
        DesktopIcons writes CreateDesktop at line \(hidWritten + 1) before recording the debt at \
        line \(owedSet + 1). A crash in between hides the desktop with nothing left that knows to \
        put it back.
        """)
    // restore(): the flag is cleared after the restart, not before it.
    let restart = try firstLine(containing: "restartFinder()", after: hidWritten + 1)
    let owedCleared = try firstLine(containing: "removeObject(forKey: owedKey)")
    #expect(restart < owedCleared, """
        DesktopIcons clears the debt at line \(owedCleared + 1) before restoring at line \
        \(restart + 1). A failure in between forgets an obligation that was never met, and the \
        next launch will not retry it.
        """)
}

/// **`SIGTERM`, never `terminate()` — and the wrong one leaves a Mac with no Finder.**
///
/// Measured 2026-08-27: `NSRunningApplication.terminate()` sends a polite `quit` Apple Event,
/// Finder honours it as a genuine quit, and launchd does NOT bring it back — no Finder after
/// six seconds. `kill(pid, SIGTERM)` is an unclean exit as far as launchd is concerned and
/// Finder was back in 0.25 s.
///
/// This is banned rather than commented because `terminate()` is the tidier-looking call and
/// "replace the raw `kill` with the Cocoa API" is exactly the change somebody makes while
/// cleaning up, with no way to discover what it broke short of quitting their own Finder.
@Test func theDesktopIconsRestartUsesASignalRatherThanAPoliteQuit() throws {
    let files = try desktopIconsFile()
    let polite = try codeLinesNaming(".terminate()", in: files)
    #expect(polite.isEmpty, """
        DesktopIcons calls terminate() at \(polite.map(\.location).joined(separator: ", ")). \
        A polite quit is one launchd does not undo: measured, no Finder six seconds later. \
        Use kill(pid, SIGTERM), which is what `killall Finder` sends and what launchd restarts.
        """)
    let signalled = try codeLinesNaming("SIGTERM", in: files)
    #expect(!signalled.isEmpty, """
        DesktopIcons no longer sends SIGTERM, so nothing restarts Finder and the preference it \
        just wrote is one Finder will not read until the next time it happens to relaunch.
        """)
}

/// **Three restores, because a recording ends in three different ways.** One when it stops, one
/// when the app quits — quitting mid-recording is ordinary — and one at launch, which is the
/// only thing that ever pays for a crash or a power cut.
///
/// Losing any one of them is invisible in every ordinary test: the icons come back, because one
/// of the other two got there. It shows up only on the path that was dropped, on somebody's real
/// machine, hours later.
@Test func theDesktopIsRestoredWhenARecordingStopsAndWhenTheAppLaunchesAndQuits() throws {
    let all = try appSourceFiles()
    let calls = try codeLinesNaming("DesktopIcons.restore()", in: all)
    let places = Set(calls.map { $0.location.split(separator: ":").first.map(String.init) ?? "" })
    #expect(places.contains("Soredemo/Editor/ContentView.swift"), """
        Nothing restores the desktop when a recording stops. Calls found: \(places.sorted()).
        """)
    #expect(places.contains("Soredemo/App/UnsavedWorkGuard.swift"), """
        Nothing restores the desktop at launch or on quit — the launch call is the only thing \
        that ever recovers from a crash mid-recording. Calls found: \(places.sorted()).
        """)
    let delegate = all.filter {
        pathRelativeToRepositoryRoot($0) == "Soredemo/App/UnsavedWorkGuard.swift"
    }
    try #require(delegate.count == 1)
    let launch = try codeLinesNaming("applicationDidFinishLaunching", in: delegate)
    let quit = try codeLinesNaming("applicationWillTerminate", in: delegate)
    #expect(!launch.isEmpty && !quit.isEmpty, """
        The delegate has \(launch.count) launch hooks and \(quit.count) terminate hooks. Both are \
        needed: launch pays for a crash, terminate pays for a quit taken mid-recording.
        """)
    // **`applicationWillTerminate`, not `applicationShouldTerminate`.** The latter can answer
    // `.terminateCancel`, and restoring for a quit that is then cancelled un-hides the desktop
    // in the middle of the recording the person just decided to keep.
    //
    // **The line numbers are only meaningful against the file they came from.** A first draft
    // took every restore call across the app and indexed the delegate's lines with them, so a
    // call in ContentView.swift was resolved against whatever happened to be at that line
    // number here — which reported a violation that did not exist.
    let delegateLines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: delegate[0], encoding: .utf8))
    let shouldTerminateRestores = try codeLinesNaming("DesktopIcons.restore()", in: delegate)
        .contains { call in
            guard let line = Int(call.location.split(separator: ":").last ?? "") else { return false }
            // The nearest enclosing func declaration above the call.
            return delegateLines.prefix(line).reversed()
                .first { $0.contains("func application") }?
                .contains("applicationShouldTerminate") ?? false
        }
    #expect(!shouldTerminateRestores, """
        The desktop is restored from applicationShouldTerminate, which can answer \
        .terminateCancel — that un-hides the icons in the middle of a recording somebody just \
        chose to keep making. Restore from applicationWillTerminate.
        """)
}

/// **Hiding twice would overwrite the real prior value with this app's own.** `hide()` refuses
/// when a restore is already owed, and without that refusal the second call records "the
/// desktop was hidden" as the state to return to — which is a Mac whose icons never come back.
@Test func hidingTheDesktopTwiceCannotOverwriteWhatItPromisedToRestore() throws {
    let files = try desktopIconsFile()
    let text = try String(contentsOf: files[0], encoding: .utf8)
    let lines = SwiftSourceLexer.codeViewLines(of: text)
    let hideStart = try #require(lines.firstIndex { $0.contains("static func hide()") },
                                 "DesktopIcons.hide() is gone, and these scans are about it")
    let guarded = lines.dropFirst(hideStart).prefix(4).contains {
        $0.contains("restoreIsOwed") && ($0.contains("guard") || $0.contains("return"))
    }
    #expect(guarded, """
        DesktopIcons.hide() no longer refuses when a restore is already owed. The second call \
        records the hidden state as the state to restore to, and the icons never come back.
        """)
}

// MARK: - Exporting part of the video

/// **The export reads `editForExport`, and the preview reads `edit`.** Getting that backwards is
/// the whole feature failing silently in one direction or the other: an export that reads `edit`
/// writes the entire video with no complaint, and a preview that reads `editForExport` hides the
/// rest of the recording the moment somebody marks a section — which is exactly when they need
/// to compare it against what surrounds it.
///
/// Neither mistake produces an error, a warning, or a wrong-looking frame. This is the only
/// mechanical check of the distinction.
@Test func theExportReadsTheRestrictedTimelineAndThePreviewDoesNot() throws {
    let stage = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Editor/StageWindow.swift" }
    try #require(stage.count == 1, "StageWindow.swift is not where this scan names it")

    let exportUses = try codeLinesNaming("timeline.editForExport", in: stage)
    #expect(!exportUses.isEmpty, """
        Nothing in StageWindow reads `timeline.editForExport`, so an export with a section \
        marked writes the whole video and says nothing about it.
        """)

    // The three places that must see the restricted timeline: the job's edit, and both size
    // estimates. A figure for the whole video beside a button that writes ten seconds of it is
    // worse than no figure.
    #expect(exportUses.count >= 3, """
        Only \(exportUses.count) of the three places that must measure what will actually be \
        written do: \(exportUses.map(\.location).joined(separator: ", ")).
        """)

    // And the preview still builds from the unrestricted edit.
    let previewComposes = try codeLinesNaming("by: timeline.edit,", in: stage)
    #expect(!previewComposes.isEmpty, """
        The preview no longer composes from `timeline.edit`. If it now uses the restricted \
        timeline, marking a section hides the rest of the recording — see this check's header \
        for why that is the wrong direction.
        """)
}

/// The in and out keys are unmodified `I` and `O`, which is what every editor that has these
/// spells them and what a person coming from one will press without looking.
@Test func theInAndOutPointsAreOnTheKeysEveryEditorUses() throws {
    let editor = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Editor/TimelineEditor.swift" }
    try #require(editor.count == 1)
    // **A RAW text scan, not `codeLinesNaming`.** The needle is string-literal CONTENT — the
    // key letter itself — and the code view blanks that by design. A first version of this check
    // used the code view and could not see either key, which is the same trap that produced two
    // vacuous checks earlier in this project.
    let lines = try String(contentsOf: editor[0], encoding: .utf8)
        .components(separatedBy: .newlines)

    for (key, action) in [("i", "markIn"), ("o", "markOut")] {
        let actionLine = try #require(lines.firstIndex { $0.contains("model.\(action)()") },
                                      "nothing calls model.\(action)()")
        // The shortcut is attached to the same button, so it is within a line or two.
        let nearby = lines[actionLine..<Swift.min(actionLine + 3, lines.count)]
        #expect(nearby.contains { $0.contains("keyboardShortcut(\"\(key)\", modifiers: [])") }, """
            \(action) is not on unmodified \(key.uppercased()). That is the key a person coming \
            from any other editor will press, and a modifier on it means they press it and \
            nothing happens.
            """)
    }
}

// MARK: - Phones are a source, never a camera

/// **`CameraRecorder.available()` must filter phones out, and no runtime test can see that on a
/// machine with nothing plugged in.**
///
/// The discovery session there asks for `.external`, and the moment `MobileScreen.allowDevices()`
/// throws the CoreMediaIO switch a connected iPhone becomes an `.external` video device. Without
/// the filter it appears in the camera picker and can be chosen as a face in the corner — while
/// also appearing in the phone list, so choosing it twice would be two clients on one device.
///
/// `theCameraListAndThePhoneListAreDisjoint` is the runtime check of this and it is vacuous
/// without hardware: both lists are empty on a laptop with no phone. Removing the filter was
/// mutation-tested and left every runtime check green. This is the one that goes red.
@Test func theCameraListFiltersOutPhones() throws {
    let recorder = packageRoot.appending(path: "Sources/Capture/CameraRecorder.swift")
    let text = try String(contentsOf: recorder, encoding: .utf8)
    let lines = SwiftSourceLexer.codeViewLines(of: text)

    let available = try #require(lines.firstIndex { $0.contains("static func available()") },
                                 "CameraRecorder.available() is gone, and this scan is about it")
    // The filter is applied inside that function — within a few lines of its declaration.
    let body = lines[available..<Swift.min(available + 14, lines.count)]
    #expect(body.contains { $0.contains("MobileScreen.camerasAmong") }, """
        CameraRecorder.available() no longer filters phones out. Its discovery session asks for \
        .external, so a connected iPhone appears in the camera picker as soon as anything throws \
        the CoreMediaIO switch — and it is simultaneously in MobileScreen.available(), so it can \
        be chosen as both the recording source and the face in the corner.
        """)
}

/// **A device's own name is drawn verbatim, never looked up in the string table.**
///
/// `TargetCard.title` is a `LocalizedStringKey`, which is the whole point of that type and was
/// itself a translation bug once — a `String` passed through it is drawn without being looked
/// up. A connected phone's name has the opposite requirement: it came from the machine, and
/// translating it would either miss or, on the day somebody adds a key matching a device name,
/// silently rename the device.
@Test func aConnectedDevicesNameIsNotPutThroughTheStringTable() throws {
    let menu = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Recording/MenuBarRecorder.swift" }
    try #require(menu.count == 1)
    let lines = try String(contentsOf: menu[0], encoding: .utf8)
        .components(separatedBy: .newlines)

    let cards = lines.enumerated().filter { $0.element.contains("TargetCard(icon: device.symbolName") }
    try #require(!cards.isEmpty, "there is no phone card, and this scan is about it")
    for (index, _) in cards {
        let call = lines[index..<Swift.min(index + 3, lines.count)].joined(separator: " ")
        #expect(call.contains("verbatimTitle: device.displayName"), """
            The phone card at line \(index + 1) passes its name through `title`, which is a \
            LocalizedStringKey. A device's name must go through `verbatimTitle`.
            """)
        #expect(!call.contains("title: device.displayName"), """
            The phone card at line \(index + 1) passes the device name as a localizable title.
            """)
    }
}

/// **The arrival notification is filtered, and no runtime test can see that without hardware.**
///
/// `MobileScreen.startWatching()` observes `AVCaptureDevice.wasConnectedNotification`, which
/// fires for EVERY capture device — a webcam, a capture card, a Continuity camera. Without the
/// `isMobileScreen` filter, plugging in a USB microphone would put it in the phone list and
/// offer to record its screen.
///
/// The runtime check of this needs a webcam and a phone attached at once. This does not.
@Test func theDeviceArrivalNotificationIsFilteredToPhones() throws {
    let file = packageRoot.appending(path: "Sources/Capture/MobileScreen.swift")
    let lines = SwiftSourceLexer.codeViewLines(of: try String(contentsOf: file, encoding: .utf8))

    let observer = try #require(
        lines.firstIndex { $0.contains("wasConnectedNotification") },
        "MobileScreen no longer observes device arrival, and this scan is about that observer")
    // The filter is in the closure that follows, within a handful of lines.
    let body = lines[observer..<Swift.min(observer + 8, lines.count)]
    #expect(body.contains { $0.contains("isMobileScreen(device)") }, """
        The arrival observer no longer filters with isMobileScreen. That notification fires for \
        every capture device, so a webcam or a USB microphone would be listed as a phone and \
        offered as a recording source.
        """)
}

/// **A phone announces itself once, so the app has to be listening before it does.**
///
/// Measured on macOS 26 with an iPad over USB: the device arrives through
/// `AVCaptureDeviceWasConnected` a few seconds after the CoreMediaIO switch is thrown, and
/// `DiscoverySession(deviceTypes: [.external])` does not list it — before, during or twenty-five
/// seconds after. There is no way to catch up on an announcement that was missed.
///
/// So `startWatching()` belongs at launch. Moving it to the menu — the obvious place, next to
/// the other device refreshes — means a person plugs their iPad in, opens the menu, and sees
/// nothing until they unplug it and plug it back in.
@Test func thePhoneWatcherStartsAtLaunchRatherThanWhenTheMenuOpens() throws {
    let delegate = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/App/UnsavedWorkGuard.swift" }
    try #require(delegate.count == 1)
    let lines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: delegate[0], encoding: .utf8))

    let launch = try #require(lines.firstIndex { $0.contains("applicationDidFinishLaunching") },
                              "the launch hook is gone")
    let watching = try #require(lines.firstIndex { $0.contains("MobileScreen.startWatching()") },
                                """
                                Nothing starts watching for phones at launch. The arrival \
                                notification fires once and cannot be replayed, so a device \
                                plugged in before the menu is opened is invisible until it is \
                                unplugged and plugged back in.
                                """)
    #expect(watching > launch && watching < launch + 20, """
        MobileScreen.startWatching() is at line \(watching + 1), outside \
        applicationDidFinishLaunching, which starts at line \(launch + 1).
        """)
}

/// **Observed clicks beat motion, and the fallback only fires when there is nothing observed.**
///
/// A Mac recording knows what was clicked and on which control; motion knows only that something
/// changed. Running both would put a second set of zooms on top of ones derived from what was
/// actually pressed, and nothing about the result would look wrong — there would simply be too
/// many zooms, in roughly the right places, with no way to tell which came from where.
@Test func motionDerivedZoomsAreOnlyUsedWhenNothingWasObserved() throws {
    let stage = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Editor/StageWindow.swift" }
    try #require(stage.count == 1)
    let lines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: stage[0], encoding: .utf8))

    let chooses = try #require(lines.firstIndex { $0.contains("observed.isEmpty ? motionClicks") },
                               """
                               Nothing chooses between observed clicks and motion-derived ones. \
                               If both are used a Mac recording gets a second set of zooms on \
                               top of the ones derived from what was actually pressed.
                               """)
    #expect(chooses > 0)

    // And the analysis itself refuses to run when a plan exists.
    let guardLine = try #require(
        lines.firstIndex { $0.contains("review.plan.entries.isEmpty") },
        "deriveZoomsFromMotion no longer checks for an existing plan before running")
    let analysis = try #require(lines.firstIndex { $0.contains("func deriveZoomsFromMotion") })
    #expect(guardLine > analysis && guardLine < analysis + 12, """
        The plan check is at line \(guardLine + 1), outside deriveZoomsFromMotion, which starts \
        at line \(analysis + 1) — so the pass runs on Mac recordings too and spends half their \
        length decoding for an answer that is thrown away.
        """)
}

/// **Opening anything replaces what is open, so every way in asks first.**
///
/// `EditorWindowPresence` refuses a second editor window on purpose — two would be two sets of
/// models over one set of process-global compositor statics — which makes every "open" a
/// "replace". A replace that discarded somebody's edits without a word would be the worst
/// possible reading of a drag they may have meant for the Finder.
///
/// This check exists because the guard was already there and almost nothing used it:
/// `UnsavedWorkGuard.mayDiscard` had exactly one caller, quitting, so opening a project over
/// unsaved edits threw them away in silence.
@Test func everyWayOfOpeningARecordingAsksBeforeReplacingTheOpenOne() throws {
    let content = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Editor/ContentView.swift" }
    try #require(content.count == 1)
    let lines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: content[0], encoding: .utf8))

    for entry in ["func openProject()", "func openVideo(at url: URL)"] {
        let at = try #require(lines.firstIndex { $0.contains(entry) },
                              "\(entry) is gone, and this scan is about it")
        let opening = lines[at..<Swift.min(at + 4, lines.count)]
        #expect(opening.contains { $0.contains("mayReplaceWhatIsOpen()") }, """
            \(entry) does not ask before replacing the open recording. A recording cannot be \
            made again, and this app holds one editor — so opening is replacing.
            """)
    }

    // And the guard actually consults `UnsavedWorkGuard` rather than answering `true`.
    let guardAt = try #require(lines.firstIndex { $0.contains("func mayReplaceWhatIsOpen") })
    let body = lines[guardAt..<Swift.min(guardAt + 6, lines.count)]
    #expect(body.contains { $0.contains("UnsavedWorkGuard.shared.mayDiscard") }, """
        mayReplaceWhatIsOpen no longer asks UnsavedWorkGuard, so it answers yes to everything.
        """)
}

// MARK: - The menu-bar panel's own two rules

/// **macOS's video effects are only named when a camera is being recorded.**
///
/// Reactions, Portrait and Studio Light apply to a camera. Shown beside "No camera" they name a
/// thing that is not happening — and somebody reads "Reactions" there as "this recording will
/// have Reactions in it", which is worse than saying nothing at all. Seen in a screenshot with
/// the camera off.
@Test func cameraEffectsAreOnlyNamedWhenACameraIsBeingRecorded() throws {
    let menu = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Recording/MenuBarRecorder.swift" }
    try #require(menu.count == 1)
    let lines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: menu[0], encoding: .utf8))

    let shown = try #require(lines.firstIndex { $0.contains("activeCameraEffects.isEmpty") },
                             "the camera-effects row is gone, and this scan is about it")
    #expect(lines[shown].contains("camera != .off"), """
        The effects row at line \(shown + 1) is not gated on a camera being selected, so it \
        names macOS's video effects beside "No camera".
        """)
}

/// **Two footer items per row, because a third truncates all of them.**
///
/// The panel is 292 points wide. Three links in one row rendered as "Op…", "O…", "Set…" — not
/// shorter labels but unreadable ones, and the row is the only place Open Project, Open Video
/// and Settings can be reached when no window is open. Reported from a screenshot.
///
/// Counted rather than measured: nothing here can lay out text, but a row's item count is the
/// thing that went wrong and it is right there in the source.
@Test func theMenuBarFooterPutsAtMostTwoLinksInARow() throws {
    let menu = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Recording/MenuBarRecorder.swift" }
    try #require(menu.count == 1)
    let lines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: menu[0], encoding: .utf8))

    let start = try #require(lines.firstIndex { $0.contains("private var footer: some View") },
                             "the footer is gone")
    // The footer ends at the `.font` modifier that closes it.
    let end = try #require(lines[start...].firstIndex { $0.contains(".font(.system(size: 12))") })

    // **Segmented between one `HStack` and the next, not by brace matching.** A first version
    // closed the row on the first line that was only `}` — which is the closing brace of a
    // PanelLink's own trailing closure, not the row's. It counted one link per row however many
    // there were, and a mutation putting three in a row left it green.
    var rowCounts: [Int] = []
    var current: Int?
    for index in start...end {
        let line = lines[index]
        if line.contains("HStack(spacing:") {
            if let count = current { rowCounts.append(count) }
            current = 0
        }
        if line.contains("PanelLink(") || line.contains("SettingsPanelLink(") {
            current = (current ?? 0) + 1
        }
    }
    if let count = current { rowCounts.append(count) }
    let worst = rowCounts.max() ?? 0

    #expect(worst > 0, "no footer links were found at all, so this scan decided nothing")
    #expect(worst <= 2, """
        A footer row holds \(worst) links. The panel is 292 points wide and a third makes every \
        title in the row truncate — "Op…", "O…", "Set…" — which is the state a screenshot caught.
        """)
}

/// **Every `title:` the app passes as a localizable key has an entry in both string tables.**
///
/// SwiftUI looks a `LocalizedStringKey` up by its exact text and draws the key itself when the
/// lookup misses. There is no warning, no crash, and no missing-glyph box — just an English word
/// sitting in a translated panel, which is what a screenshot caught: "Open Project ⌘O",
/// "Open Video ⇧⌘O" and "Settings ⌘," in English beside "結束".
///
/// The table was not incomplete. It held `"Open Project…"` and `"Settings…"` WITH an ellipsis,
/// from an earlier version of those labels, and the code passes them without. Two nearly
/// identical strings, one of which works.
///
/// **Scoped to `title:`, deliberately.** Most other literals in this app are long sentences
/// assembled with `+`, which SwiftUI cannot look up at all — they arrive as a computed `String`
/// rather than a key. Checking those would be checking a rule the code does not follow. A
/// `title:` is a word somebody reads on a control, and it is the set that broke.
@Test func everyTitleLiteralIsInBothStringTables() throws {
    let resources = repositoryRoot.appending(path: "Soredemo/Resources")
    func keys(of language: String) throws -> Set<String> {
        let url = resources.appending(path: "\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var found: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { continue }
            // Up to the closing quote of the key, which is the one before ` = `.
            guard let range = trimmed.range(of: "\" = \"") else { continue }
            found.insert(String(trimmed[trimmed.index(after: trimmed.startIndex)..<range.lowerBound]))
        }
        return found
    }
    let english = try keys(of: "en")
    let chinese = try keys(of: "zh-Hant")
    try #require(english.count > 100, "the English table read as \(english.count) keys — parsed wrong")
    #expect(english == chinese, """
        The two tables have drifted apart. Only in English: \
        \(english.subtracting(chinese).sorted().prefix(6)). Only in Chinese: \
        \(chinese.subtracting(english).sorted().prefix(6)).
        """)

    // **A RAW scan.** The needle is string-literal CONTENT, which the code view blanks.
    var missing: [String] = []
    var scanned = 0
    for file in try appSourceFiles() {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            guard line.contains("title: \""), !line.contains("verbatim") else { continue }
            guard let start = line.range(of: "title: \"") else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let key = String(rest[..<end])
            // Interpolated titles are not keys, and an empty one is the placeholder beside a
            // `verbatimTitle`.
            guard !key.isEmpty, !key.contains("\\(") else { continue }
            scanned += 1
            if !english.contains(key) {
                missing.append("\(pathRelativeToRepositoryRoot(file)):\(index + 1) \"\(key)\"")
            }
        }
    }
    #expect(scanned > 5, "only \(scanned) title literals were found — this scan decided nothing")
    #expect(missing.isEmpty, """
        These titles have no entry in the string tables, so they draw in English whatever \
        language the app is in:
        \(missing.joined(separator: "\n"))
        """)
}

/// **The editor publishes motion clicks to the compositor, not only to the timeline.**
///
/// These were two derivations of the same thing from two different places: the timeline drew
/// blocks the editor had computed, and `StageCompositor` built its camera from the observation
/// log alone. A phone recording has no log, so the lane showed zooms and the picture never moved
/// — with nothing wrong at either end, each being correct about its own inputs.
///
/// The compositor half is covered by `theCameraZoomsFromMotionClicksWhenThereIsNoObservationLog`.
/// This is the other half: that the app actually hands them over, on the analysis AND on every
/// later load, because `load()` runs more than once and the analysis declines to run again.
@Test func theEditorPublishesMotionClicksToTheCompositor() throws {
    let stage = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Editor/StageWindow.swift" }
    try #require(stage.count == 1)
    let lines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: stage[0], encoding: .utf8))

    let publishes = lines.indices.filter { lines[$0].contains("StageCompositor.motionClicks =") }
    #expect(publishes.count >= 2, """
        `StageCompositor.motionClicks` is set \(publishes.count) time(s). It needs setting when \
        the analysis finishes AND on every load: load() runs more than once, the composition \
        reads the statics as it builds, and the analysis will not run again once it has clicks.
        """)
    let anchors = lines.indices.filter { lines[$0].contains("StageCompositor.motionAnchor =") }
    #expect(anchors.count == publishes.count, """
        The clicks and their anchor are published a different number of times \
        (\(publishes.count) vs \(anchors.count)). An instant without the anchor that gives it \
        meaning is a number.
        """)
}

/// **A container that paints a background constrains both axes.**
///
/// The preview's loading branch had `.frame(maxHeight: .infinity)` and no `maxWidth`, so it took
/// the width of a `ProgressView` — a few points — and `Theme.Surface.preview` painted exactly
/// that: a tall black sliver down the middle of the editor whenever a recording was loading. The
/// player branch hid it, because an `NSViewRepresentable` expands on its own, so it only ever
/// showed during the wait.
///
/// Nothing here can lay out a view. What it can see is the shape of the mistake: a `.background`
/// on a container told to fill one axis and not the other.
@Test func aPaintedPreviewContainerFillsBothAxesRatherThanOne() throws {
    let stage = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/Editor/StageWindow.swift" }
    try #require(stage.count == 1)
    let lines = SwiftSourceLexer.codeViewLines(
        of: try String(contentsOf: stage[0], encoding: .utf8))

    let painted = try #require(
        lines.firstIndex { $0.contains("Theme.Surface.preview") },
        "the preview surface is gone, and this scan is about the container that paints it")
    // The frame that sizes it is the line or two above the background.
    let sizing = lines[Swift.max(painted - 3, 0)..<painted]
    let frames = sizing.filter { $0.contains(".frame(") }
    try #require(!frames.isEmpty, "no frame above the painted background — the shape has changed")
    #expect(frames.contains { $0.contains("maxWidth: .infinity") && $0.contains("maxHeight: .infinity") },
            """
            The preview's painted container is sized on one axis only: \
            \(frames.map { $0.trimmingCharacters(in: .whitespaces) }). It then takes the width \
            of whatever is inside it, and paints that — which for a ProgressView is a black \
            sliver down the middle of the editor.
            """)
}
