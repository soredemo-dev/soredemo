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
private let theOnlyPasteboardUse = "Soredemo/UI/ExportQueue.swift"

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
        (", fileExtension:", "Soredemo/UI/ProjectDocument.swift", 0,
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
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/UI/SettingsWindow.swift" }
    try #require(settingsFiles.count == 1, """
        Soredemo/UI/SettingsWindow.swift is not where it was. This scan names it, so a rename \
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
    #expect(deferred.count == 1 && files == ["Soredemo/UI/StageWindow.swift"], """
        \(deferred.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        A control that commits on release leaves a paused preview showing the old picture while \
        its own number moves. If this one genuinely needs to — because it re-derives something \
        rather than redrawing — say so beside the zoom Amount slider and name it here.
        """)
}

/// **A one-shot courtesy records that it happened, not that it was attempted.**
///
/// `sizeGenerouslyOnFirstOpen` gives the editor most of the screen the first time it is ever
/// opened. It marked the courtesy spent and THEN registered a notification observer to do the
/// sizing later — so anything in between (no screen yet, the notification never arriving, a
/// quit) burnt the flag with nothing to show for it, and "once ever" meant never. Measured on a
/// real install on 2026-08-26: the flag read `1` while the editor still opened too small for
/// its own timeline to have any length.
///
/// The shape of the bug is general — write the receipt after the delivery — so what is checked
/// is the order of the two statements rather than the fix's own words.
@Test func theEditorsFirstOpenSizeIsRecordedAfterItIsApplied() throws {
    let files = try appSourceFiles()
        .filter { pathRelativeToRepositoryRoot($0) == "Soredemo/UI/WindowConfigurator.swift" }
    try #require(files.count == 1, "WindowConfigurator.swift is not where this scan names it")
    let text = try String(contentsOf: files[0], encoding: .utf8)
    let lines = SwiftSourceLexer.codeViewLines(of: text)

    let writesFlag = lines.firstIndex { $0.contains("UserDefaults.standard.set(true, forKey: key)") }
    let setsFrame = lines.firstIndex { $0.contains("window.setFrame(") }
    let flagLine = try #require(writesFlag, "nothing writes the first-open flag any more")
    let frameLine = try #require(setsFrame, "nothing sets the editor's first-open frame any more")
    #expect(flagLine > frameLine, """
        the first-open flag is written at line \(flagLine + 1), before the frame is set at line \
        \(frameLine + 1). A receipt written before the delivery is a courtesy that can be spent \
        without being given — which is what happened, and why the key had to be renamed to give \
        it back.
        """)
}
