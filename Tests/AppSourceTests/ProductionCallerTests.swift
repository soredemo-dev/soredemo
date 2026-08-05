import Foundation
import Testing

// MARK: - Task 5.5: the first production caller of five things at once
//
// This target cannot compile or run `Soredemo/` — `AppSourceTests` depends only on
// `CheckerLexer` (see `Package.swift`), the same reason every scan in
// `AppSourceAllowListTests.swift` is a text scan rather than a call. So what this file pins is
// SHAPE, not behaviour: that the wiring this task adds exists, in the file it belongs in, exactly
// as many times as it should. What the wiring actually DOES under a real recording — a log with a
// non-zero pointer count and at least one AX chain, the drawn cursor moving — is measured in
// `a skill chain/sdd/2026-08-03-phase-2b-render/task-5.5-report.md`, with real values, because this
// target has no way to produce or check that itself.
//
// Reuses `appSourceFiles()`, `codeLinesNaming(_:in:)`, `violationsEverywhere(banned:in:)` and
// `repositoryRoot` from `AppSourceAllowListTests.swift` — file-scope declarations in this same
// test target, not duplicated here for the reason that file's own header gives for sharing
// `CheckerLexer` rather than re-deriving it.

// MARK: - Step 1: the microphone entitlement

/// `project.pbxproj`'s raw text. Outside `Soredemo/`, so `appSourceFiles()` does not cover it —
/// this is the one scan in this file that reads a different tree.
func projectPbxprojText() throws -> String {
    let url = repositoryRoot.appending(path: "Soredemo.xcodeproj/project.pbxproj")
    return try String(contentsOf: url, encoding: .utf8)
}

/// Measured at the Task 4 human step, quoted in the brief: with
/// `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT`/`NSMicrophoneUsageDescription` absent and
/// `CaptureSession.beginSegment` setting `configuration.captureMicrophone = true` unconditionally,
/// `tccd` said verbatim "service: kTCCServiceMicrophone requires entitlement
/// com.apple.security.device.audio-input but it is missing / Policy disallows prompt / access to
/// kTCCServiceMicrophone denied", and the whole recording failed to start.
///
/// Both build settings, in **both** configurations — a fix present only in Debug (or only in
/// Release) is a fix that changes behaviour depending on which scheme happens to be active, which
/// is indistinguishable from no fix at all the day someone builds Release.
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

// MARK: - Step 2: the degradation model matches what was measured

/// `CapturePermissions.degradation(for: .microphone)` used to return `.noMicrophoneTrack`, which
/// claims a distinct, milder consequence — system audio and video keep recording, just without a
/// microphone track — than what Step 1's measurement showed: `SCStreamConfiguration` asks for a
/// microphone as one inseparable request alongside video and system audio, and denying any part of
/// that request failed the WHOLE stream, not just the microphone's own track. This pins the
/// corrected mapping rather than the one it replaced.
@Test func microphoneDegradationMatchesTheMeasuredConsequence() throws {
    let mapping = try codeLinesNaming("case .microphone:      return", in: try appSourceFiles())
        .filter { $0.location.hasPrefix("Soredemo/Capture/CapturePermissions.swift:") }

    try #require(mapping.count == 1, """
        expected exactly one 'case .microphone:      return' arm in \
        CapturePermissions.swift's degradation(for:) switch, found \(mapping.count) — this scan's \
        anchor is the exact column alignment that switch uses, and a reformat would need a matching \
        update here.
        """)
    #expect(mapping[0].text.contains(".blocksRecording"), """
        CapturePermissions.degradation(for: .microphone) is '\(mapping[0].text)', not \
        .blocksRecording. This is Task 5.5 Step 2's measurement: with the microphone entitlement \
        missing (the state Step 1's build settings fix), tccd refused kTCCServiceMicrophone and the \
        recording did not start at all — not "started, minus a microphone track", which is what \
        .noMicrophoneTrack claimed. This file's own doc comment (line 9) requires "a stated, \
        distinct consequence that is what actually happens".
        """)
}

// MARK: - Steps 3 and 4: the two permissions this app had never asked for

/// `CGRequestScreenCaptureAccess` occurred zero times in this repository before Task 5.5 — the
/// picker and `SCStream` never prompt on their own. It must now occur, exactly once, inside
/// `CapturePermissions.requestScreenRecordingAccess()` — a second call site anywhere would be a
/// second policy about when this app asks, the same shape `AppSourceAllowListTests` already pins
/// for `IsSecureEventInputEnabled`/`CGEvent.tapIsEnabled`.
@Test func theScreenRecordingRequestIsCalledExactlyOnceAndWiredBeforeThePicker() throws {
    let files = try appSourceFiles()
    let rawCalls = try codeLinesNaming("CGRequestScreenCaptureAccess()", in: files)
    #expect(rawCalls.count == 1, """
        expected exactly one call to CGRequestScreenCaptureAccess(), found \(rawCalls.count): \
        \(rawCalls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Zero means nothing in this app ever asks for Screen Recording, so a first-run user is told \
        "the user declined" by an API that never asked them. More than one means two policies about \
        when to ask.
        """)
    guard let rawCall = rawCalls.first else { return }
    #expect(rawCall.location.hasPrefix("Soredemo/Capture/CapturePermissions.swift:"), """
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

/// The same shape one permission over. `AXIsProcessTrustedWithOptions` with the prompt option
/// occurred zero times before Task 5.5 — `CapturePermissions.status(of: .accessibility)` only ever
/// reads the non-prompting `AXIsProcessTrusted()`. Note this deliberately does NOT assert
/// `AXIsProcessTrustedWithOptions` is called from `CaptureSession.swift` directly: it is called
/// from `CapturePermissions.requestAccessibilityAccess()`, and `CaptureSession` calls that wrapper.
@Test func theAccessibilityRequestIsCalledExactlyOnceAndWiredIntoCaptureSession() throws {
    let files = try appSourceFiles()
    let rawCalls = try codeLinesNaming("AXIsProcessTrustedWithOptions(", in: files)
    #expect(rawCalls.count == 1, """
        expected exactly one call to AXIsProcessTrustedWithOptions(, found \(rawCalls.count): \
        \(rawCalls.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Zero means this app never asks for Accessibility with the prompt option. More than one \
        means two policies about when to ask.
        """)
    guard let rawCall = rawCalls.first else { return }
    #expect(rawCall.location.hasPrefix("Soredemo/Capture/CapturePermissions.swift:"), """
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
    #expect(wrapperCall.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:"), """
        the request is called at \(wrapperCall.location), not from CaptureSession — the brief asks \
        for it "before the AX walk's first use", and CaptureSession is what starts that walk.
        """)
}

// MARK: - Step 5: the five first production callers

/// `InputObserver`, `AXObserver` and `ObservationWriter` each had, per the brief's own measured
/// table, zero (or read-only, for `ObservationWriter`) executed production call sites before this
/// task. This pins that each now has at least one, OUTSIDE its own declaring file — a call from
/// within the type's own file (its initialiser, its tests-only seams) does not count, which is why
/// `InputObserver.swift`/`AXObserver.swift`/`ObservationWriter.swift` are excluded below the same
/// way `theSynchronousAXWalkIsCalledOnlyFromWithinAXObserver` excludes `AXObserver.swift` from ITS
/// own scan, in the opposite direction.
@Test func theFirstProductionCallersAreWiredIntoCaptureSession() throws {
    let files = try appSourceFiles()

    let inputObserverConstructions = try codeLinesNaming("InputObserver(arrangement:", in: files)
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

    // All five in the SAME file, or the claim "CaptureSession is where this task attaches" is
    // unproven by the four checks above individually passing in four different, unrelated places.
    for (name, sites) in [("InputObserver(arrangement:", inputObserverConstructions),
                           ("AXObserver(arrangement:", axObserverConstructions),
                           ("ObservationWriter.open(segment:", observationWriterOpens),
                           (".start(onObservation:", tapStartCalls),
                           (".enqueue(event", axEnqueueCalls)] {
        #expect(sites.allSatisfy { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }, """
            \(name) has a production call site outside CaptureSession.swift: \
            \(sites.map(\.location).joined(separator: ", ")). The brief attaches this task to \
            CaptureSession specifically, not to RecordingCoordinator/ContentView — see the brief's \
            "Attach to CaptureSession, not to RecordingCoordinator" paragraph.
            """)
    }
}

// MARK: - Step 5: the log's naming convention, and the media layout it depends on

/// `ObservationWriter.expectedLogURL(forMediaURL:)` only resolves to a real path for a media file
/// at `<package>/media/master-NN.mov`. Before Task 5.5, `ContentView`'s scratch
/// `TemporaryFileMediaSink` wrote flatly with no `media/` parent, so every recording made through
/// this window was structurally unable to have an observation log found beside it, independent of
/// whether `CaptureSession` ever wrote one. This pins the layout fix that makes the rest of this
/// task's wiring reachable from `StageWindow` at all.
@Test func theTemporaryMediaSinkWritesUnderMediaMatchingObservationWritersConvention() throws {
    // A RAW text scan, deliberately not `codeLinesNaming` — the needle names a string LITERAL's
    // content ("media"), and `SwiftSourceLexer.codeViewLines` blanks string content by design (see
    // `AppSourceAllowListTests`'s note on `ReadableAXAttribute`). That design exists to stop a ban
    // being evaded inside a string; this is a presence check, not a ban, so the risk it guards
    // against (a match hiding in a comment) is checked by hand here instead: the whole file
    // contains this exact substring exactly twice, both in `TemporaryFileMediaSink`'s real code
    // (`init` and `acceptMedia`), never in prose describing it.
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

/// `MediaSink.packageURL` is what lets `CaptureSession` find where to open an `ObservationWriter`
/// at all — without it, the only package-shaped consumer (`ProjectDocument`) happens to already
/// have a same-shaped property, but nothing in the protocol says a `MediaSink` must, and
/// `TemporaryFileMediaSink` had no reason to grow one.
@Test func theMediaSinkProtocolRequiresAPackageURL() throws {
    let sites = try codeLinesNaming("var packageURL: URL? { get }", in: try appSourceFiles())
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    #expect(!sites.isEmpty, """
        MediaSink no longer declares a packageURL requirement — CaptureSession has no protocol-level \
        way to find where to write an observation log for a segment.
        """)
}

// MARK: - Fix round 2 (code review): the segment-close drop window is counted, not silent

/// **Code review, Important finding.** `finalizeCurrentSegment` nils `observationWriter` under
/// `lock` immediately, then blocks on `axObserver.waitForQueuedClicks()` — up to hundreds of
/// milliseconds, with the event tap still fully live — before the writer is actually closed. Every
/// observation `appendObservation` sees during that window, at every segment boundary (`pause()`,
/// a display reconfiguration, `stop()`), used to hit `guard let writer else { return }` and vanish
/// with nothing counting it — exactly the silence `Diagnostics.observationAppendFailures`'s own doc
/// comment says must not happen. This pins that the `guard` branch now increments a counter, and
/// pins WHERE: between `guard let writer else {` and the branch's closing `}`, so a future edit that
/// moves the increment into the success path (where it would count nothing, since a live writer
/// never takes this branch) fails the ordering check below even though the line would still exist
/// somewhere in the file.
@Test func theSegmentCloseDropWindowIsCountedNotSilent() throws {
    let files = try appSourceFiles()

    let fieldDeclarations = try codeLinesNaming("var observationsDroppedAfterSegmentClose = 0", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
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
    #expect(increment.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:"), """
        the increment is at \(increment.location), not in CaptureSession.swift.
        """)

    let guardLines = try codeLinesNaming("guard let writer else {", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    try #require(guardLines.count == 1, """
        expected exactly one 'guard let writer else {' in CaptureSession.swift (appendObservation's \
        own guard), found \(guardLines.count) — this scan's ordering check needs a unique landmark.
        """)
    let appendCalls = try codeLinesNaming("try writer.append(record)", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
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

// MARK: - Phase 2B Task 8, fix round 1 (code review): the drop counter's account, pinned mechanically

/// **Code review, Important finding 4.** `StageCompositor.Diagnostics.framesDropped`'s doc comment
/// names exactly two causes — the leading `guard` in `startRequest` and the `catch` around
/// `renderer.render(_:source:into:)` — and today's code matches it exactly. But nothing enforced
/// that agreement mechanically, in a codebase that already does exactly this for
/// `observationsDroppedAfterSegmentClose` above, precisely because that counter's prose drifted
/// from its code once already. "The doc is right today" is not the standard this file's own
/// neighbouring tests hold everything else to.
///
/// Pins two things: **exactly two call sites** of `StageCompositor.recordDroppedFrame()` (a third
/// added later — a new failure branch — silently falsifies the doc comment, the D6a row, and § 16
/// of the probe, all at once, unless this test also moves); and that **each call site sits
/// immediately before an ERROR `finish(with:)`**, told apart from the success path
/// (`finish(withComposedPixelBuffer:)`, which the needle `"request.finish(with:"` does not match —
/// `withComposedPixelBuffer` has no `with:` substring). A counter incrementing anywhere else could
/// count a frame that still reached the composed-buffer path, which would make `framesDropped`
/// overstate real drops — a different, and equally silent, way for the number to stop meaning what
/// its doc comment says.
@Test func theDroppedFrameCounterHasExactlyTwoCallSitesEachImmediatelyBeforeAnErrorFinish() throws {
    // `headlessSourceFiles()`, not `appSourceFiles()` — `StageCompositor.swift` moved to
    // `Sources/Headless/` in Phase 3A-1 Task 4 and is no longer under `Soredemo/` at all, so the
    // old scan found zero matches instead of one. The file itself, and everything this test pins
    // about it, is unchanged by the move.
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

// MARK: - Fix round 3 (code review): a third source of writer == nil, told apart from the second

/// **Code review, Important finding.** The round-2 fix above conflated two different facts under
/// one counter: an observation dropped because a segment was actively closing (a real loss), and
/// one that arrived while NO segment was open at all — before the first one, between `pause()` and
/// `resume()`, or during a reconfiguration gap (not uniformly a loss; see
/// `Diagnostics.observationsOutsideAnOpenSegment`'s own doc comment). This pins that the two are now
/// told apart by a dedicated flag, `finalizingCurrentSegment`, read in the SAME `lock.withLock` as
/// `observationWriter` — not by two separate lock acquisitions, which would reopen a narrower version
/// of the same conflation (see `routeInputObservation`'s own doc comment for why).
@Test func theOutsideSegmentCounterIsToldApartFromTheCloseWindowByAFlagReadWithTheWriter() throws {
    let files = try appSourceFiles()

    let fieldDeclarations = try codeLinesNaming("var observationsOutsideAnOpenSegment = 0", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    #expect(fieldDeclarations.count == 1, """
        expected exactly one declaration of Diagnostics.observationsOutsideAnOpenSegment in \
        CaptureSession.swift, found \(fieldDeclarations.count).
        """)

    let pairedReads = try codeLinesNaming(
        "let (writer, finalizing) = lock.withLock { (observationWriter, finalizingCurrentSegment) }",
        in: files)
    #expect(pairedReads.count == 1, """
        expected exactly one paired read of (observationWriter, finalizingCurrentSegment) in ONE \
        lock.withLock, found \(pairedReads.count): \
        \(pairedReads.map { "\($0.location): \($0.text)" }.joined(separator: "\n"))
        Reading them in two separate lock.withLock calls reopens the exact race fix round 3 closed: \
        finalizeCurrentSegment can change both, together, in the gap between two separate reads.
        """)
    guard let pairedRead = pairedReads.first else { return }
    #expect(pairedRead.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:"), """
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

    // Both increments must sit inside appendObservation's writer==nil guard, and on OPPOSITE sides
    // of an `if whileFinalizing`/`else` — proven by ordering against three landmarks, the same
    // technique the round-2 test uses.
    let guardLines = try codeLinesNaming("guard let writer else {", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    try #require(guardLines.count == 1, "expected exactly one appendObservation guard, found \(guardLines.count)")
    let elseLines = try codeLinesNaming("} else {", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    try #require(elseLines.count >= 1, "expected at least one 'else' in CaptureSession.swift")
    let appendCalls = try codeLinesNaming("try writer.append(record)", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
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

// MARK: - Fix round 4 (code review): the ordering that makes "outside any hostRange" a proof, not a guess

/// **Code review, Important finding.** The reviewer asked whether the startup window
/// (`observationsOutsideAnOpenSegment`'s first case) could contain a genuinely-fixable loss: an
/// observation whose `instant` falls inside the about-to-open segment's `hostRange` but which found
/// `observationWriter == nil` because `SCStream` had already started producing samples before the
/// writer existed. It cannot, PROVIDED `self.observationWriter` and the segment's `hostRange.start`
/// (via `ledger.openSegment(at: openInstant, …)`) are set before `scStream.startCapture()` is ever
/// called — see `Diagnostics.observationsOutsideAnOpenSegment`'s own doc comment for the full
/// argument. This pins the ordering the argument depends on, so a future edit that moves
/// `startCapture()` earlier (or the writer/ledger assignment later) fails a test instead of quietly
/// invalidating a doc comment's proof.
///
/// **What this test is blind to, stated here rather than only in a report someone would have to go
/// find (code review, fix round 5).** This is a LINE-ORDER check — it reads which of two lines comes
/// first in the file's text, nothing about when either actually executes. It catches a
/// straightforward reordering of the three statements it names. It would **not** catch the same
/// defect reached without moving any of those lines — for instance, deferring
/// `scStream.startCapture()` into a `Task { … }` dispatched from earlier in `beginSegment`, which
/// would keep every line in its current textual position while making the capture start run
/// concurrently with, or before, the writer/ledger assignment. A per-record runtime
/// `assert(record.instant ∈ segment.hostRange)` would catch that too, at the cost of a per-case
/// switch over `some ObservationRecord` on the tap-callback hot path for every pointer sample up to
/// display rate — rejected for that cost, not for being weaker; this test is the cheap side of that
/// trade, not the complete one.
@Test func theFirstSegmentsWriterAndHostRangeAreSetBeforeCaptureStarts() throws {
    let files = try appSourceFiles()

    let writerAssignments = try codeLinesNaming("self.observationWriter = writer", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    try #require(writerAssignments.count == 1, """
        expected exactly one 'self.observationWriter = writer' in CaptureSession.swift, found \
        \(writerAssignments.count).
        """)
    let ledgerOpens = try codeLinesNaming("ledger.openSegment(at: openInstant", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    try #require(ledgerOpens.count == 1, """
        expected exactly one 'ledger.openSegment(at: openInstant' in CaptureSession.swift, found \
        \(ledgerOpens.count).
        """)
    let captureStarts = try codeLinesNaming("try await scStream.startCapture()", in: files)
        .filter { $0.location.hasPrefix("Soredemo/Capture/CaptureSession.swift:") }
    try #require(captureStarts.count == 1, """
        expected exactly one 'try await scStream.startCapture()' in CaptureSession.swift, found \
        \(captureStarts.count).
        """)

    let writerLine = lineNumber(of: writerAssignments[0].location)
    let ledgerLine = lineNumber(of: ledgerOpens[0].location)
    let captureLine = lineNumber(of: captureStarts[0].location)

    #expect(writerLine < captureLine, """
        self.observationWriter = writer (line \(writerLine)) is not before \
        scStream.startCapture() (line \(captureLine)) — if a video frame can be produced before the \
        writer exists, observationsOutsideAnOpenSegment's whole "not a loss" argument is false for \
        this case, and a real bug is hiding under a classification that says it is harmless.
        """)
    #expect(ledgerLine < captureLine, """
        ledger.openSegment(at: openInstant… (line \(ledgerLine)), which fixes hostRange.start, is not \
        before scStream.startCapture() (line \(captureLine)) — the "instant outside every hostRange" \
        proof needs hostRange.start fixed before any sample could exist to compare against it.
        """)
}
