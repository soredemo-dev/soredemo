import Foundation
import Testing

// MARK: - the first production caller of five things at once
//
// This target cannot compile or run `Soredemo/` — it depends only on `CheckerLexer`, so every
// check here is a text scan pinning SHAPE, not behaviour. Reuses `appSourceFiles()`,
// `codeLinesNaming(_:in:)` and `repositoryRoot` from `AppSourceAllowListTests.swift`.

// MARK: - Step 1: the microphone entitlement

/// `project.pbxproj`'s raw text — the one scan in this file that reads outside `Soredemo/`.
func projectPbxprojText() throws -> String {
    let url = repositoryRoot.appending(path: "Soredemo.xcodeproj/project.pbxproj")
    return try String(contentsOf: url, encoding: .utf8)
}

/// Measured: with the entitlement and usage description absent, `tccd` refused
/// kTCCServiceMicrophone and the whole recording failed to start. Both settings must be present
/// in BOTH configurations, or the fix depends on which scheme happens to be active.
@Test func theMicrophoneEntitlementAndUsageDescriptionAreDeclaredForBothConfigurations() throws {
    let text = try projectPbxprojText()
    let entitlementCount = text.components(separatedBy: "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES;").count - 1
    let usageDescriptionCount = text.components(separatedBy: "INFOPLIST_KEY_NSMicrophoneUsageDescription").count - 1

    #expect(entitlementCount == 2, """
        expected ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES; in both the Debug and Release \
        configurations of the Soredemo target, found \(entitlementCount). Verify with \
        `codesign -d --entitlements -` on the built app that com.apple.security.device.audio-input \
        is present.
        """)
    #expect(usageDescriptionCount == 2, """
        expected INFOPLIST_KEY_NSMicrophoneUsageDescription in both build configurations, found \
        \(usageDescriptionCount).
        """)
}

// MARK: - Step 2: the degradation model — retired here, superseded by a real test
//
// **`microphoneDegradationMatchesTheMeasuredConsequence()` was deleted in Phase 3A-3, and
// its claim is stronger now, not weaker.** It grepped
// `Soredemo/Capture/CapturePermissions.swift` for the literal text
// `case .microphone:      return` — anchored on that switch's exact column alignment, so a
// reformat broke it — and asserted the matched line contained `.blocksRecording`.
//
// That file is now `Sources/Capture/CapturePermissions.swift`, which `swift test` links.
// `Tests/CaptureTests/CapturePermissionsTests.swift` CALLS
// `CapturePermissions.degradation(for: .microphone)` and asserts the returned value is
// `.blocksRecording` and is not `.noMicrophoneTrack` — the measurement Task 5.5 Step 2
// made (with the entitlement missing, tccd refused kTCCServiceMicrophone and the recording
// did not start AT ALL, rather than starting minus a track). A text scan proves a line was
// typed; the test proves the function answers.
//
// Keeping both would keep a column-alignment-anchored grep alive for no added claim. This
// note is the record that the coverage moved rather than went away — the one thing a
// deleted test must leave behind.

// MARK: - Steps 3 and 4: the two permissions this app had never asked for

/// `CGRequestScreenCaptureAccess` must occur exactly once, inside
/// `CapturePermissions.requestScreenRecordingAccess()` — a second site is a second policy about
/// when this app asks. Zero means a first-run user is told they declined without being asked.
@Test func theScreenRecordingRequestIsCalledExactlyOnceAndWiredBeforeThePicker() throws {
    // BOTH trees since Phase 3A-3: the request itself moved into
    // `Sources/Capture/CapturePermissions.swift` while its caller stayed in the app.
    // `firstPartySourceFiles()` already spans `Sources/` and `Soredemo/` — appending
    // `headlessSourceFiles()` to it counted every Headless file twice, and the symptom
    // was this scan reporting two calls to a function called once.
    let files = try firstPartySourceFiles()
    let rawCalls = try codeLinesNaming("CGRequestScreenCaptureAccess()", in: files)
    #expect(rawCalls.count == 1, """
        expected exactly one call to CGRequestScreenCaptureAccess(), found \(rawCalls.count): \
        \(rawCalls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Zero means nothing in this app ever asks for Screen Recording, so a first-run user is told \
        "the user declined" by an API that never asked them. More than one means two policies about \
        when to ask.
        """)
    guard let rawCall = rawCalls.first else { return }
    #expect(rawCall.location.hasPrefix("Sources/Capture/CapturePermissions.swift:"), """
        CGRequestScreenCaptureAccess() is called at \(rawCall.location), not from \
        CapturePermissions.requestScreenRecordingAccess() — the one place this app's policy for \
        asking should live.
        """)

    let wrapperCalls = try codeLinesNaming("CapturePermissions.requestScreenRecordingAccess()", in: files)
    #expect(wrapperCalls.count == 1, """
        expected exactly one call to CapturePermissions.requestScreenRecordingAccess() outside its \
        own declaration, found \(wrapperCalls.count): \
        \(wrapperCalls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        """)
    guard let wrapperCall = wrapperCalls.first else { return }
    #expect(wrapperCall.location.hasPrefix("Soredemo/UI/ContentView.swift:"), """
        the request is called at \(wrapperCall.location), not from ContentView's \
        RecordingCoordinator.beginOpenRecording(), where the brief asks for it — "before the \
        picker opens".
        """)
}

/// The same shape one permission over. Deliberately does NOT assert that
/// `AXIsProcessTrustedWithOptions` is called from `CaptureSession.swift`: it goes through
/// `CapturePermissions.requestAccessibilityAccess()`, which `CaptureSession` calls.
@Test func theAccessibilityRequestIsCalledExactlyOnceAndWiredIntoCaptureSession() throws {
    // Both trees, same reason as the screen-recording scan above.
    let files = try firstPartySourceFiles()
    let rawCalls = try codeLinesNaming("AXIsProcessTrustedWithOptions(", in: files)
    #expect(rawCalls.count == 1, """
        expected exactly one call to AXIsProcessTrustedWithOptions(, found \(rawCalls.count): \
        \(rawCalls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Zero means this app never asks for Accessibility with the prompt option. More than one \
        means two policies about when to ask.
        """)
    guard let rawCall = rawCalls.first else { return }
    #expect(rawCall.location.hasPrefix("Sources/Capture/CapturePermissions.swift:"), """
        AXIsProcessTrustedWithOptions( is called at \(rawCall.location), not from \
        CapturePermissions.requestAccessibilityAccess().
        """)

    let wrapperCalls = try codeLinesNaming("CapturePermissions.requestAccessibilityAccess()", in: files)
    #expect(wrapperCalls.count == 1, """
        expected exactly one call to CapturePermissions.requestAccessibilityAccess() outside its \
        own declaration, found \(wrapperCalls.count): \
        \(wrapperCalls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        """)
    guard let wrapperCall = wrapperCalls.first else { return }
    #expect(wrapperCall.location.hasPrefix("Sources/Capture/CaptureSession.swift:"), """
        the request is called at \(wrapperCall.location), not from CaptureSession — the brief asks \
        for it "before the AX walk's first use", and CaptureSession is what starts that walk.
        """)
}

// MARK: - Step 5: the five first production callers

/// `InputObserver`, `AXObserver` and `ObservationWriter` each had zero (or read-only) executed
/// production call sites. Each must now have one OUTSIDE its own declaring file, which is why
/// those files are excluded — a call from within the type's own file does not count.
@Test func theFirstProductionCallersAreWiredIntoCaptureSession() throws {
    let files = try firstPartySourceFiles()

    let inputObserverConstructions = try codeLinesNaming(// `viewport:`, not `arrangement:`, since the window-capture repair (2026-08-20) —
        // the observer normalises against WHAT IS RECORDED. The needle follows the
        // constructor rather than the constructor being kept still for the needle.
        "InputObserver(viewport:", in: files)
        .filter { !$0.location.hasPrefix("Soredemo/Capture/InputObserver.swift:") }
    #expect(!inputObserverConstructions.isEmpty, """
        InputObserver(arrangement: is never constructed outside InputObserver.swift — the brief's \
        own table measured zero executed production call sites for this type, and this scan finding \
        none means that is still true.
        """)

    let axObserverConstructions = try codeLinesNaming("AXObserver(arrangement:", in: files)
        .filter { !$0.location.hasPrefix("Soredemo/Capture/AXObserver.swift:") }
    #expect(!axObserverConstructions.isEmpty, """
        AXObserver(arrangement: is never constructed outside AXObserver.swift.
        """)

    let observationWriterOpens = try codeLinesNaming("ObservationWriter.open(segment:", in: files)
        .filter { !$0.location.hasPrefix("Soredemo/Capture/ObservationWriter.swift:") }
    #expect(!observationWriterOpens.isEmpty, """
        ObservationWriter.open(segment: is never called outside ObservationWriter.swift — the \
        brief measured this type's only production call site as expectedLogURL, read-only.
        """)

    let tapStartCalls = try codeLinesNaming(".start(onObservation:", in: files)
        .filter { !$0.location.hasPrefix("Soredemo/Capture/InputObserver.swift:") }
    #expect(!tapStartCalls.isEmpty, """
        InputObserver.start(onObservation: is never called outside InputObserver.swift — the tap \
        this whole task exists to create is never armed.
        """)

    let axEnqueueCalls = try codeLinesNaming(".enqueue(event", in: files)
        .filter { !$0.location.hasPrefix("Soredemo/Capture/AXObserver.swift:") }
    #expect(!axEnqueueCalls.isEmpty, """
        AXObserver.enqueue(_:onRecord:) is never called outside AXObserver.swift — a button-down \
        observation is produced but never handed to the AX walk.
        """)

    // All five in the SAME file, or "CaptureSession is where this attaches" is unproven.
    for (name, sites) in [(// `viewport:`, not `arrangement:`, since the window-capture repair (2026-08-20) —
        // the observer normalises against WHAT IS RECORDED. The needle follows the
        // constructor rather than the constructor being kept still for the needle.
        "InputObserver(viewport:", inputObserverConstructions),
                           ("AXObserver(arrangement:", axObserverConstructions),
                           ("ObservationWriter.open(segment:", observationWriterOpens),
                           (".start(onObservation:", tapStartCalls),
                           (".enqueue(event", axEnqueueCalls)] {
        #expect(sites.allSatisfy { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }, """
            \(name) has a production call site outside CaptureSession.swift: \
            \(sites.map(\.location).joined(separator: ", ")). The brief attaches this task to \
            CaptureSession specifically, not to RecordingCoordinator/ContentView — see the brief's \
            "Attach to CaptureSession, not to RecordingCoordinator" paragraph.
            """)
    }
}

// MARK: - Step 5: the log's naming convention, and the media layout it depends on

/// `ObservationWriter.expectedLogURL(forMediaURL:)` resolves only for `<package>/media/master-NN.mov`.
/// `TemporaryFileMediaSink` once wrote flatly, so no recording made through this window could
/// have its observation log found, however correctly one was written.
@Test func theTemporaryMediaSinkWritesUnderMediaMatchingObservationWritersConvention() throws {
    // A RAW text scan, not `codeLinesNaming` — the needle names string-literal content, which
    // the code view blanks by design. Checked by hand: this substring occurs exactly twice,
    // both in TemporaryFileMediaSink's real code, never in prose.
    let url = appSourceDirectory.appending(path: "UI/ContentView.swift")
    let text = try String(contentsOf: url, encoding: .utf8)
    let sites = text.components(separatedBy: .newlines).filter { $0.contains(#".appending(path: "media""#) }
    #expect(!sites.isEmpty, """
        TemporaryFileMediaSink no longer writes under a media/ subdirectory — \
        ObservationWriter.expectedLogURL(forMediaURL:) requires <package>/media/master-NN.mov, and \
        without this a recording made through ContentView can never have its observation log found, \
        however correctly CaptureSession writes one.
        """)
}

/// `MediaSink.packageURL` is what lets `CaptureSession` find where to open an `ObservationWriter`;
/// nothing in the protocol required one before, and `TemporaryFileMediaSink` had no reason to.
@Test func theMediaSinkProtocolRequiresAPackageURL() throws {
    let sites = try codeLinesNaming("var packageURL: URL? { get }", in: try firstPartySourceFiles())
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    #expect(!sites.isEmpty, """
        MediaSink no longer declares a packageURL requirement — CaptureSession has no protocol-level \
        way to find where to write an observation log for a segment.
        """)
}

// MARK: - the segment-close drop window is counted, not silent

/// `finalizeCurrentSegment` nils `observationWriter` immediately, then blocks on
/// `waitForQueuedClicks()` with the tap live, so observations in that window used to vanish
/// uncounted. Pins that the guard branch increments a counter, and that it sits INSIDE it.
@Test func theSegmentCloseDropWindowIsCountedNotSilent() throws {
    let files = try firstPartySourceFiles()

    let fieldDeclarations = try codeLinesNaming("var observationsDroppedAfterSegmentClose = 0", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    #expect(fieldDeclarations.count == 1, """
        expected exactly one declaration of Diagnostics.observationsDroppedAfterSegmentClose in \
        CaptureSession.swift, found \(fieldDeclarations.count).
        """)

    let increments = try codeLinesNaming("_diagnostics.observationsDroppedAfterSegmentClose += 1", in: files)
    #expect(increments.count == 1, """
        expected exactly one increment of observationsDroppedAfterSegmentClose, found \
        \(increments.count): \(increments.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Zero means an observation dropped because the segment's writer already went nil is silent \
        again — the exact regression this test exists to catch. More than one means a second, \
        untracked place this can happen.
        """)
    guard let increment = increments.first else { return }
    #expect(increment.location.hasPrefix("Sources/Capture/CaptureSession.swift:"), """
        the increment is at \(increment.location), not in CaptureSession.swift.
        """)

    let guardLines = try codeLinesNaming("guard let writer else {", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(guardLines.count == 1, """
        expected exactly one 'guard let writer else {' in CaptureSession.swift (appendObservation's \
        own guard), found \(guardLines.count) — this scan's ordering check needs a unique landmark.
        """)
    let appendCalls = try codeLinesNaming("try writer.append(record)", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(appendCalls.count == 1, """
        expected exactly one 'try writer.append(record)' in CaptureSession.swift, found \
        \(appendCalls.count).
        """)

    let incrementLine = lineNumber(of: increment.location)
    let guardLine = lineNumber(of: guardLines[0].location)
    let appendLine = lineNumber(of: appendCalls[0].location)
    #expect(guardLine < incrementLine && incrementLine < appendLine, """
        observationsDroppedAfterSegmentClose is incremented at line \(incrementLine), which is not \
        between 'guard let writer else {' (line \(guardLine)) and 'try writer.append(record)' (line \
        \(appendLine)) — i.e. not inside the guard's failure branch, where a nil writer is what this \
        counter is supposed to be counting.
        """)
}

// MARK: - the drop counter's account, pinned mechanically

/// `StageCompositor.Diagnostics.framesDropped`'s doc comment names exactly two causes, and
/// nothing enforced that mechanically. Pins two `recordDroppedFrame()` call sites, each
/// immediately before an ERROR `finish(with:)` — the success path spells `withComposedPixelBuffer:`.
@Test func theDroppedFrameCounterHasExactlyTwoCallSitesEachImmediatelyBeforeAnErrorFinish() throws {
    // `headlessSourceFiles()`, not `appSourceFiles()` — `StageCompositor.swift` lives under
    // `Sources/Headless/` now, so a `Soredemo/`-tree scan would find zero matches instead of one.
    let files = try headlessSourceFiles()
        .filter { $0.lastPathComponent == "StageCompositor.swift" }
    try #require(files.count == 1, """
        expected exactly one StageCompositor.swift under Sources/Headless/, found \(files.count) — \
        this scan's file-scoped filter needs a unique target.
        """)

    let callSites = try codeLinesNaming("Self.recordDroppedFrame()", in: files)
    #expect(callSites.count == 2, """
        expected exactly two call sites of StageCompositor.recordDroppedFrame(), found \
        \(callSites.count):
        \(callSites.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        StageCompositor.Diagnostics's own doc comment names exactly two causes and no others. A \
        different count means a cause was added or removed in the code without the doc comment (and \
        the D6a row, and § 16 of the probe) being told — the exact drift Task 5.5's own counter \
        needed three fix rounds to close.
        """)

    let errorFinishes = try codeLinesNaming("request.finish(with:", in: files)
    #expect(errorFinishes.count == 2, """
        expected exactly two ERROR finish() calls in StageCompositor.swift (the needle \
        "request.finish(with:" does not match the success path's "request.finish(withComposedPixelBuffer:"), \
        found \(errorFinishes.count):
        \(errorFinishes.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        """)

    let callLines = callSites.map { lineNumber(of: $0.location) }.sorted()
    let finishLines = errorFinishes.map { lineNumber(of: $0.location) }.sorted()
    #expect(zip(callLines, finishLines).allSatisfy { $0 + 1 == $1 }, """
        expected each recordDroppedFrame() call to sit on the line immediately before an ERROR \
        finish() call. Call sites at \(callLines), error finishes at \(finishLines). A counter that \
        increments somewhere other than immediately before the branch that actually drops the frame \
        could increment on a path that still produces a composed buffer, overstating real drops.
        """)
}

// MARK: - a third source of writer == nil, told apart from the second

/// Two different facts once shared one counter: an observation dropped because a segment was
/// closing (a real loss), and one arriving while no segment was open (not uniformly a loss).
/// Pins that `finalizingCurrentSegment` is read in the SAME `lock.withLock` as the writer.
@Test func theOutsideSegmentCounterIsToldApartFromTheCloseWindowByAFlagReadWithTheWriter() throws {
    let files = try firstPartySourceFiles()

    let fieldDeclarations = try codeLinesNaming("var observationsOutsideAnOpenSegment = 0", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    #expect(fieldDeclarations.count == 1, """
        expected exactly one declaration of Diagnostics.observationsOutsideAnOpenSegment in \
        CaptureSession.swift, found \(fieldDeclarations.count).
        """)

    let pairedReads = try codeLinesNaming(
        // The `unsafe` marks arrived with Phase 3A-3's move into a strict target; the claim —
        // ONE `withLock`, both values read together — is unchanged, and the needle follows
        // the text rather than the text being kept still for the needle.
        "let (writer, finalizing) = lock.withLock { unsafe (observationWriter, finalizingCurrentSegment) }",
        in: files)
    #expect(pairedReads.count == 1, """
        expected exactly one paired read of (observationWriter, finalizingCurrentSegment) in ONE \
        lock.withLock, found \(pairedReads.count): \
        \(pairedReads.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Reading them in two separate lock.withLock calls reopens the exact race fix round 3 closed: \
        finalizeCurrentSegment can change both, together, in the gap between two separate reads.
        """)
    guard let pairedRead = pairedReads.first else { return }
    #expect(pairedRead.location.hasPrefix("Sources/Capture/CaptureSession.swift:"), """
        the paired read is at \(pairedRead.location), not in CaptureSession.swift.
        """)

    let outsideIncrements = try codeLinesNaming("_diagnostics.observationsOutsideAnOpenSegment += 1", in: files)
    #expect(outsideIncrements.count == 1, """
        expected exactly one increment of observationsOutsideAnOpenSegment, found \
        \(outsideIncrements.count): \
        \(outsideIncrements.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        """)
    let closeIncrements = try codeLinesNaming("_diagnostics.observationsDroppedAfterSegmentClose += 1", in: files)
    try #require(closeIncrements.count == 1, "expected exactly one increment of the close counter too")

    // Both increments must sit inside appendObservation's writer==nil guard, on OPPOSITE sides
    // of an `if whileFinalizing`/`else` — proven by ordering against three landmarks.
    let guardLines = try codeLinesNaming("guard let writer else {", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(guardLines.count == 1, "expected exactly one appendObservation guard, found \(guardLines.count)")
    let elseLines = try codeLinesNaming("} else {", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(elseLines.count >= 1, "expected at least one 'else' in CaptureSession.swift")
    let appendCalls = try codeLinesNaming("try writer.append(record)", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(appendCalls.count == 1, "expected exactly one 'try writer.append(record)'")

    let guardLine = lineNumber(of: guardLines[0].location)
    let appendLine = lineNumber(of: appendCalls[0].location)
    let closeLine = lineNumber(of: closeIncrements[0].location)
    let outsideLine = lineNumber(of: outsideIncrements[0].location)
    // The 'else' that separates the two branches is the one between the guard and the append call.
    let branchElseLine = elseLines.map { lineNumber(of: $0.location) }.first { $0 > guardLine && $0 < appendLine }
    try #require(branchElseLine != nil, """
        could not find the if/else separating the two 'no writer' counters between \
        'guard let writer else {' (line \(guardLine)) and 'try writer.append(record)' (line \(appendLine))
        """)

    #expect(guardLine < closeLine && closeLine < branchElseLine!, """
        observationsDroppedAfterSegmentClose is incremented at line \(closeLine), which is not in the \
        'if whileFinalizing' branch (between line \(guardLine) and the else at line \(branchElseLine!)).
        """)
    #expect(branchElseLine! < outsideLine && outsideLine < appendLine, """
        observationsOutsideAnOpenSegment is incremented at line \(outsideLine), which is not in the \
        'else' branch (between the else at line \(branchElseLine!) and line \(appendLine)).
        """)
}

// MARK: - the ordering that makes "outside any hostRange" a proof, not a guess

/// The startup window cannot hide a fixable loss. That USED to be guaranteed by opening the
/// writer before `scStream.startCapture()`, and this test pinned that order.
///
/// **The writer now opens at the first complete video frame instead**, because only that frame
/// can supply the log's anchor: everything downstream converts a composition time to a host
/// instant through it, composition time zero IS the first frame, and taking the anchor at
/// segment setup shifted every pointer position and camera aim by the capture's start latency —
/// small for a display, seconds for a window that must first be composited.
///
/// So the claim moves rather than weakens: observations arriving before the log opens are HELD,
/// not dropped, and the loss stays zero. `bufferObservationUntilFirstFrame` is what makes that
/// true, and its absence is what this now checks. `hostRange.start` is still fixed before
/// `startCapture()`, unchanged.
///
/// Blind spot, unchanged: a LINE-ORDER check, so deferring `startCapture()` into a `Task`
/// evades it.
@Test func nothingIsLostBetweenCaptureStartingAndTheLogOpening() throws {
    let files = try firstPartySourceFiles()

    let buffering = try codeLinesNaming("bufferObservationUntilFirstFrame", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    #expect(buffering.count >= 2, """
        appendObservation must consult bufferObservationUntilFirstFrame, and that function must \
        exist — found \(buffering.count) mention(s). Without it, every observation between \
        startCapture() and the first frame is dropped and counted as \
        observationsOutsideAnOpenSegment, whose "not a loss" argument would then be false.
        """)

    let writerAssignments = try codeLinesNaming("unsafe observationWriter = writer", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(writerAssignments.count == 1, """
        expected exactly one 'unsafe observationWriter = writer' in CaptureSession.swift, found \
        \(writerAssignments.count).
        """)
    let ledgerOpens = try codeLinesNaming("ledger.openSegment(at: openInstant", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(ledgerOpens.count == 1, """
        expected exactly one 'ledger.openSegment(at: openInstant' in CaptureSession.swift, found \
        \(ledgerOpens.count).
        """)
    let captureStarts = try codeLinesNaming("try await scStream.startCapture()", in: files)
        .filter { $0.location.hasPrefix("Sources/Capture/CaptureSession.swift:") }
    try #require(captureStarts.count == 1, """
        expected exactly one 'try await scStream.startCapture()' in CaptureSession.swift, found \
        \(captureStarts.count).
        """)

    let ledgerLine = lineNumber(of: ledgerOpens[0].location)
    let captureLine = lineNumber(of: captureStarts[0].location)
    _ = writerAssignments
    #expect(ledgerLine < captureLine, """
        ledger.openSegment(at: openInstant… (line \(ledgerLine)), which fixes hostRange.start, is not \
        before scStream.startCapture() (line \(captureLine)) — the "instant outside every hostRange" \
        proof needs hostRange.start fixed before any sample could exist to compare against it.
        """)
}
