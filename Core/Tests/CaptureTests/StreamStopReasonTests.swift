import Foundation
import ScreenCaptureKit
import Testing
@testable import Capture
@testable import Project

/// The codes are the SDK's, read from `SCError.h` and confirmed at runtime
/// against `SCStreamError.Code` before these tests were written; a test that
/// spelled them as literals would only be checking itself.
private func streamError(_ code: SCStreamError.Code) -> NSError {
    NSError(domain: SCStreamErrorDomain, code: code.rawValue)
}

@Test func theUserStoppingCaptureIsNeverRestarted() {
    let reason = StreamStopReason(streamError(.userStopped))
    #expect(reason == .theUserStoppedIt)
    #expect(reason.isWorthRestarting == false)
}

@Test func theSystemTakingTheDisplayAwayIsRestarted() {
    let reason = StreamStopReason(streamError(.systemStoppedStream))
    #expect(reason == .theSystemTookTheDisplayAway)
    #expect(reason.isWorthRestarting)
}

@Test func aDeadDaemonConnectionIsRestarted() {
    for code in [SCStreamError.Code.failedApplicationConnectionInvalid,
                 .failedApplicationConnectionInterrupted] {
        let reason = StreamStopReason(streamError(code))
        #expect(reason == .theConnectionToTheCaptureDaemonDied(code: code.rawValue))
        #expect(reason.isWorthRestarting, "code \(code.rawValue) should be restartable")
    }
}

/// The list is the point: every code the SDK names has a verdict, and the ones
/// that describe this recording's setup all refuse. A code added by a future SDK
/// lands in `.itWillFailTheSameWayAgain`, which refuses — the safe direction.
@Test func everySetupErrorRefusesToRestart() {
    let setupErrors: [SCStreamError.Code] = [
        .userDeclined, .failedToStart, .missingEntitlements,
        .failedNoMatchingApplicationContext, .attemptToStartStreamState,
        .attemptToStopStreamState, .attemptToUpdateFilterState,
        .attemptToConfigState, .internalError, .invalidParameter,
        .noWindowList, .noDisplayList, .noCaptureSource, .removingStream,
        .failedToStartAudioCapture, .failedToStopAudioCapture,
        .failedToStartMicrophoneCapture,
    ]
    for code in setupErrors {
        let reason = StreamStopReason(streamError(code))
        #expect(reason == .itWillFailTheSameWayAgain(code: code.rawValue))
        #expect(reason.isWorthRestarting == false, "code \(code.rawValue) must not restart")
    }
}

/// `-3821` in somebody else's domain is not the display going away. The domain
/// is checked first for exactly this reason.
@Test func aMatchingCodeInAnotherDomainIsNotAScreenCaptureKitStop() {
    let reason = StreamStopReason(NSError(domain: NSPOSIXErrorDomain, code: -3821))
    #expect(reason == .unrecognised(domain: NSPOSIXErrorDomain, code: -3821))
    #expect(reason.isWorthRestarting == false)
}

/// A `CancellationError` — no domain of its own — must not be read as a
/// ScreenCaptureKit verdict just because bridging gave it one.
@Test func aSwiftErrorWithNoDomainIsUnrecognised() {
    guard case .unrecognised = StreamStopReason(CancellationError()) else {
        Issue.record("a Swift error bridged into some other domain must be unrecognised")
        return
    }
    #expect(StreamStopReason(CancellationError()).isWorthRestarting == false)
}

/// Every verdict says its code out loud. A support log that named only this
/// project's reading of an error would leave a reader unable to check it.
@Test func everyDescriptionCarriesTheRawCode() {
    let cases: [(StreamStopReason, String)] = [
        (StreamStopReason(streamError(.userStopped)), "-3817"),
        (StreamStopReason(streamError(.systemStoppedStream)), "-3821"),
        (StreamStopReason(streamError(.failedApplicationConnectionInvalid)), "-3804"),
        (StreamStopReason(streamError(.internalError)), "-3811"),
        (StreamStopReason(NSError(domain: "com.example", code: 7)), "7"),
    ]
    for (reason, code) in cases {
        #expect(reason.description.contains(code),
                "\(reason.description) should name \(code)")
    }
}

/// The budget is a decision, and a decision worth one line of test is worth
/// stating: five attempts two seconds apart spans ten seconds of absence.
@Test func theRestartBudgetSpansTenSecondsOfAbsence() {
    #expect(StreamStopReason.restartAttempts == 5)
    #expect(StreamStopReason.restartDelay == .seconds(2))
    let span = StreamStopReason.restartDelay * StreamStopReason.restartAttempts
    #expect(span == .seconds(10))
}

/// `.interrupted` and `.failed` are different recordings, and the difference has
/// to survive the round trip to disk — a table that read one back as the other
/// would claim a continued recording ended, or an ended one continued.
@Test func anInterruptedBoundarySurvivesTheRoundTrip() throws {
    let boundaries: [SegmentBoundary] = [
        .interrupted(reason: "the system stopped the stream"),
        .failed(reason: "the system stopped the stream"),
    ]
    let coded = try JSONDecoder().decode([SegmentBoundary].self,
                                         from: try JSONEncoder().encode(boundaries))
    #expect(coded == boundaries)
    #expect(coded[0] != coded[1], "same reason, different boundary — they must not compare equal")
}

/// The adjudication of `SegmentBoundary.interrupted` as "keep" rests on this:
/// `StreamStopReason.description` is a closed vocabulary, so no error's own
/// description — the thing that carries home paths and usernames into a log —
/// can travel through it. Asserted against an error whose description is nothing
/// but a path, so a regression that starts interpolating the error shows up here
/// and not in a committed fixture.
@Test func theInterruptedBoundaryCarriesNoUserData() {
    let leak = "/Users/somebody/Movies/A Private Recording.soredemo"
    let leaky = NSError(domain: SCStreamErrorDomain,
                        code: SCStreamError.Code.systemStoppedStream.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: leak,
                                   NSFilePathErrorKey: leak])
    let everyCase: [StreamStopReason] = [
        StreamStopReason(leaky),
        StreamStopReason(streamError(.userStopped)),
        StreamStopReason(streamError(.failedApplicationConnectionInvalid)),
        StreamStopReason(streamError(.internalError)),
        StreamStopReason(NSError(domain: leak, code: 1)),   // even a domain built from a path
    ]
    for reason in everyCase {
        #expect(reason.description.contains("/Users/") == false,
                "\(reason.description) leaked a path")
        #expect(reason.description.contains("A Private Recording") == false,
                "\(reason.description) leaked a filename")
    }
}

/// The identifier rule has to cost nothing on the errors actually expected. A
/// rule that withheld every domain would satisfy
/// `theInterruptedBoundaryCarriesNoUserData` and be useless, so both halves are
/// pinned: real domains survive verbatim, and the refusal says how much it kept
/// back rather than going quiet.
@Test func ordinaryErrorDomainsSurviveTheIdentifierRule() {
    // ScreenCaptureKit's own domain is deliberately absent: an error in it never
    // reaches `.unrecognised`, so including it would test the wrong branch.
    for domain in [NSPOSIXErrorDomain, NSCocoaErrorDomain, AVFoundationErrorDomain,
                   "com.apple.CoreMedia"] {
        let description = StreamStopReason(NSError(domain: domain, code: 1)).description
        #expect(description.contains(domain), "\(description) should name \(domain)")
    }

    let withheld = StreamStopReason(NSError(domain: "/Users/somebody/x", code: 1)).description
    #expect(withheld.contains("withheld"))
    #expect(withheld.contains("17"), "the refusal should say how long the withheld domain was")
}
