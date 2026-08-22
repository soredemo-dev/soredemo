import Foundation
import Testing
@testable import Capture

// The first `swift test` tests of the permissions layer. Until Phase 3A-3 it was in the
// app target, where nothing automatic could run it — and its whole job is to be honest
// about what a machine CANNOT tell you, which is exactly the kind of claim that decays
// unread.
//
// What is NOT asserted: any actual grant. `status(of:)` reads this machine's real TCC
// state, which differs per machine and per provisioning, so a test asserting a value
// would be asserting the developer's System Settings. What IS asserted is the part that
// is a property of the code: which states each API can distinguish, what absence costs,
// and that the two tables agree with the enum they range over.

// MARK: - distinguishableStates: the fidelity each API actually has

/// The four permissions do not have the same resolution, and the product must not pretend
/// they do. Screen Recording and Accessibility are Bool-only APIs — "granted" or
/// "something else" — so a UI offering to distinguish "denied" from "not yet asked" for
/// them would be inventing a distinction the OS never made.
@Test func aBoolOnlyAPIDistinguishesExactlyTwoStates() {
    for permission in [CapturePermission.screenRecording, .accessibility] {
        #expect(CapturePermissions.distinguishableStates(for: permission)
                == [.granted, .notGrantedIndeterminate],
                "\(permission.rawValue) claims a fidelity its API does not have")
    }
}

/// The microphone's `AVAuthorizationStatus` names all four; input monitoring's
/// `IOHIDAccessType` names three, with no MDM/user split. These are different numbers on
/// purpose, and a table that quietly gave them the same set would erase the difference.
@Test func theRicherAPIsDistinguishTheirOwnStates() {
    #expect(CapturePermissions.distinguishableStates(for: .microphone)
            == [.notDetermined, .granted, .denied, .restricted])
    #expect(CapturePermissions.distinguishableStates(for: .inputMonitoring)
            == [.notDetermined, .granted, .denied])
}

/// `.notGrantedIndeterminate` belongs to the Bool-only APIs and to nothing else — it is
/// the name for "the OS will not say which", and a richer API reporting it would be
/// throwing away information it was given.
@Test func onlyTheBoolOnlyAPIsReportAnIndeterminateState() {
    let reporting = CapturePermission.allCases.filter {
        CapturePermissions.distinguishableStates(for: $0).contains(.notGrantedIndeterminate)
    }
    #expect(Set(reporting) == [.screenRecording, .accessibility])
}

/// Every permission distinguishes `.granted`, and every state set is non-empty. A
/// permission whose table forgot `.granted` would make a granted machine unreportable.
@Test func everyPermissionCanAtLeastReportBeingGranted() {
    for permission in CapturePermission.allCases {
        let states = CapturePermissions.distinguishableStates(for: permission)
        #expect(!states.isEmpty, "\(permission.rawValue) distinguishes nothing")
        #expect(states.contains(.granted), "\(permission.rawValue) cannot report a grant")
    }
}

// MARK: - degradation: what absence costs

/// A denied microphone fails the whole `SCStream`, not just the microphone track — so it
/// maps to `.blocksRecording` and NOT to `.noMicrophoneTrack`, which is the plausible
/// wrong answer and the one the file's own comment exists to refuse.
@Test func aDeniedMicrophoneBlocksTheWholeRecording() {
    #expect(CapturePermissions.degradation(for: .microphone) == .blocksRecording)
    #expect(CapturePermissions.degradation(for: .microphone) != .noMicrophoneTrack)
}

/// The other three, each a distinct cost. Input monitoring and accessibility degrade the
/// OBSERVATION rather than the recording: without them a demo still records, and what is
/// lost is the evidence the derivation runs on.
@Test func eachRemainingPermissionHasItsOwnDegradation() {
    #expect(CapturePermissions.degradation(for: .screenRecording) == .blocksRecording)
    #expect(CapturePermissions.degradation(for: .inputMonitoring) == .observationBlind)
    #expect(CapturePermissions.degradation(for: .accessibility) == .noElementIdentity)
}

/// Both tables are total over the enum. A fifth permission added without a row in either
/// switch is a compile error today; this asserts the tables stay total if either switch
/// ever gains a `default`, which is how that protection would be lost silently.
@Test func bothTablesCoverEveryPermission() {
    #expect(CapturePermission.allCases.count == 4)
    for permission in CapturePermission.allCases {
        _ = CapturePermissions.degradation(for: permission)
        #expect(!CapturePermissions.distinguishableStates(for: permission).isEmpty)
    }
}

// MARK: - the subject block, and why its build strings are parameters

/// `subjectBlockLines(build:commit:)` takes its provenance rather than reading
/// `BuildProvenance`, which is generated into the APP target by
/// `scripts/build-app-for-verification.sh`. The strings pass through verbatim: a
/// diagnostic that silently substituted a placeholder for a stale binary's real commit
/// would defeat the point of baking provenance in at all.
@Test func theSubjectBlockPrintsTheProvenanceItWasHanded() {
    let lines = CapturePermissions.subjectBlockLines(build: "BUILD-SENTINEL",
                                                     commit: "COMMIT-SENTINEL")
    let joined = lines.joined(separator: "\n")
    #expect(joined.contains("BUILD-SENTINEL"))
    #expect(joined.contains("COMMIT-SENTINEL"))
}

/// The block names the process it read from. `bundle identifier` is the tell that a
/// reading came from a process with no bundle identity — whose TCC grants are not
/// Soredemo's — and under `swift test` that is exactly the situation, so this test
/// observes the diagnostic doing its job rather than asserting a grant.
@Test func theSubjectBlockNamesTheProcessTheReadingCameFrom() {
    let joined = CapturePermissions.subjectBlockLines(build: "b", commit: "c")
        .joined(separator: "\n")
    for field in ["macOS", "bundle identifier", "executable path", "inside a .app", "pid"] {
        #expect(joined.contains(field), "the subject block no longer names '\(field)'")
    }
}

// MARK: - observations: shape, not values

/// One observation per permission, each carrying the degradation the table gives — the
/// join is asserted rather than assumed, since a report that paired a permission with
/// another's cost would read as authoritative and be wrong.
@Test func thereIsOneObservationPerPermissionAndItsDegradationMatchesTheTable() {
    let observations = CapturePermissions.observations()
    #expect(Set(observations.map(\.permission)) == Set(CapturePermission.allCases))
    for observation in observations {
        #expect(observation.degradation
                == CapturePermissions.degradation(for: observation.permission))
        #expect(CapturePermissions.distinguishableStates(for: observation.permission)
                .contains(observation.status),
                """
                \(observation.permission.rawValue) reported \(observation.status.rawValue), \
                which its own API cannot distinguish
                """)
    }
}

// MARK: - the raw values, which are a wire format

/// `PermissionStatus` and `Degradation` raw values reach `dumpText()`'s output and — for
/// `Degradation` — `ObservationBlindness`-shaped reasoning downstream. `Degradation`'s own
/// header calls a raw-value change "wire-breaking", so the strings are pinned here rather
/// than left to whoever next renames a case.
@Test func thePermissionStatusRawValuesArePinned() {
    let statuses: [PermissionStatus] = [.notDetermined, .granted, .denied, .restricted,
                                        .notGrantedIndeterminate]
    #expect(statuses.map(\.rawValue)
            == ["notDetermined", "granted", "denied", "restricted", "notGrantedIndeterminate"])
}

@Test func theDegradationRawValuesArePinned() {
    let degradations: [Degradation] = [.blocksRecording, .noMicrophoneTrack, .observationBlind,
                                       .noElementIdentity]
    #expect(degradations.map(\.rawValue)
            == ["blocksRecording", "noMicrophoneTrack", "observationBlind", "noElementIdentity"])
}

@Test func theCapturePermissionRawValuesArePinned() {
    #expect(CapturePermission.allCases.map(\.rawValue)
            == ["screenRecording", "microphone", "inputMonitoring", "accessibility"])
}

/// A `PermissionObservation` carries the three fields verbatim — it is a row of a
/// diagnostic, and a row that reordered its own fields would be read as authoritative.
@Test func aPermissionObservationCarriesItsThreeFields() {
    let observation = PermissionObservation(permission: .inputMonitoring,
                                            status: .denied,
                                            degradation: .observationBlind)
    #expect(observation.permission == .inputMonitoring)
    #expect(observation.status == .denied)
    #expect(observation.degradation == .observationBlind)
}
