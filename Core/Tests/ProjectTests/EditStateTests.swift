import Foundation
import Testing
import Geometry
import Timeline
@testable import Project

private func ns(_ value: Int64) -> Nanoseconds { Nanoseconds(value) }

/// **Only authored values are saved, and that is the file format's whole argument.** A project
/// storing derived ones — the framing plan, the zoom blocks, the pointer track — would keep an
/// old answer when the derivation improved. What a person cannot get back by re-deriving is
/// what has to be on disk.
@Suite struct EditStateTests {
    @Test func anUntouchedProjectChangesNothing() {
        #expect(!EditState.untouched.changesAnything)
    }

    @Test func anyAuthoredValueMakesItDirty() throws {
        #expect(EditState(timeline: .whole(duration: ns(1_000))).changesAnything)
        #expect(EditState(audioMix: AudioMix().setting(.microphone, muted: true)).changesAnything)
        #expect(EditState(zoomAdjustmentData: Data("x".utf8)).changesAnything)
        #expect(EditState(framingOverrideData: Data("x".utf8)).changesAnything)
        #expect(EditState(styleData: Data("x".utf8)).changesAnything)
        #expect(EditState(outputShapeName: "Portrait").changesAnything)
        #expect(EditState(captionTrackData: Data("x".utf8)).changesAnything)
        #expect(EditState(captionStyleData: Data("x".utf8)).changesAnything)
        #expect(EditState(burnsInCaptions: true).changesAnything)
        #expect(EditState(textTrackData: Data("x".utf8)).changesAnything)
        #expect(EditState(redactionTrackData: Data("x".utf8)).changesAnything)
        #expect(EditState(annotationTrackData: Data("x".utf8)).changesAnything)
    }

    /// **Burn-in being OFF is not a change.** It is the default, so a project that only ever had
    /// captions turned off has nothing to save — and a dirty indicator that lit up for it would
    /// ask a person to save a file identical to the one on disk.
    @Test func captionsTurnedOffAreNotAnEdit() {
        #expect(!EditState(burnsInCaptions: false).changesAnything)
    }

    /// A transcript is the one derived value this format stores, so it has to survive the trip
    /// — including a person's corrections to it, which is the reason it is stored at all.
    @Test func aCaptionTrackAndItsLookRoundTrip() throws {
        let state = EditState(captionTrackData: Data("cues".utf8),
                              captionStyleData: Data("look".utf8),
                              burnsInCaptions: true)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(EditState.self, from: data)
        #expect(back == state)
        #expect(back.burnsInCaptions == true)
    }

    /// A project written before captions existed opens with them absent, not with an error —
    /// which is the absence-tolerance the type's header promises.
    @Test func aProjectWrittenBeforeCaptionsExistedStillOpens() throws {
        let older = Data(#"{"audioMix":{"gains":{},"muted":[]},"outputShapeName":"Landscape"}"#.utf8)
        let state = try JSONDecoder().decode(EditState.self, from: older)
        #expect(state.captionTrackData == nil)
        #expect(state.burnsInCaptions == nil)
        #expect(state.outputShapeName == "Landscape")
    }

    /// A cut survives a save and reopen, which is the point of the whole exercise.
    @Test func anEditedTimelineRoundTrips() throws {
        let state = EditState(timeline: .whole(duration: ns(10_000))
            .removing(sourceRange: 2_000..<5_000))
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(EditState.self, from: data)
        #expect(back == state)
        #expect(back.timeline?.clips.count == 2)
        // The clip identities survive too, so a selection or an override keyed on one still
        // means what it meant.
        #expect(back.timeline?.clips.map(\.id) == state.timeline?.clips.map(\.id))
    }

    /// **Every field is absence-tolerant**, which is what lets the format grow without a
    /// migration per field. A document written before a field existed opens unedited.
    @Test func aProjectMissingEveryOptionalFieldOpensUnedited() throws {
        let state = try JSONDecoder().decode(EditState.self, from: Data("{\"audioMix\":{}}".utf8))
        #expect(state == .untouched)
    }

    /// The seam exists so no caller writes an encoder by hand and gets different bytes.
    @Test func theEncodingSeamRoundTripsAnyCodableValue() throws {
        struct Sample: Codable, Equatable { let a: Int; let b: String }
        let value = Sample(a: 7, b: "x")
        let data = try EditState.encoding(value)
        #expect(try EditState.decoding(data, as: Sample.self) == value)
    }

    /// `nil` in, `nil` out — an absent field is "unedited", never an error.
    @Test func decodingNothingIsNotAnError() throws {
        struct Sample: Codable, Equatable { let a: Int }
        #expect(try EditState.decoding(nil, as: Sample.self) == nil)
    }

    /// **A field that fails to decode IS an error.** A project whose zoom adjustments are
    /// corrupt must say so rather than opening with them silently gone — a person would redo
    /// the work and save over the file that still had it.
    @Test func decodingCorruptBytesThrowsRatherThanReturningNothing() {
        struct Sample: Codable { let a: Int }
        #expect(throws: (any Error).self) {
            try EditState.decoding(Data("not json".utf8), as: Sample.self)
        }
    }
}

/// The snapshot is what a project file actually is; the edit rides on it.
@Suite struct ProjectSnapshotEditTests {
    private func snapshot(edit: EditState) -> ProjectSnapshot {
        ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                        geometries: GeometryRegistry(), mediaFilenames: ["master-00.mov"],
                        edit: edit)
    }

    @Test func aSnapshotCarriesTheEditThroughACodingRoundTrip() throws {
        let state = EditState(timeline: .whole(duration: ns(5_000)),
                              audioMix: AudioMix().setting(.systemAudio, gain: 0.5),
                              outputShapeName: "Portrait")
        let data = try ProjectSnapshot.makeEncoder().encode(snapshot(edit: state))
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(back.edit == state)
    }

    /// **A document written before the field existed opens unedited**, which is why the schema
    /// version does not move for it — and why `EditState` holds only authored values, since an
    /// older build that drops the key on its next save loses corrections rather than footage.
    @Test func aSnapshotWithNoEditKeyOpensUnedited() throws {
        // Built from a REAL snapshot with the key removed, rather than from hand-written JSON:
        // the first draft guessed at `GeometryRegistry`'s shape and failed against the real
        // format, which is exactly the kind of test that would go on passing after the format
        // moved.
        let encoded = try ProjectSnapshot.makeEncoder().encode(snapshot(edit: .untouched))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "edit")
        #expect(object["mediaFilenames"] != nil, "the fixture lost more than the edit key")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: legacy)
        #expect(back.edit == .untouched)
        #expect(back.mediaFilenames == ["master-00.mov"])
    }

    /// Encoding is deterministic, which every diff of a project file depends on.
    @Test func twoEncodesOfOneSnapshotAreTheSameBytes() throws {
        let state = EditState(timeline: .whole(duration: ns(5_000)),
                              audioMix: AudioMix().setting(.microphone, muted: true))
        let first = try ProjectSnapshot.makeEncoder().encode(snapshot(edit: state))
        let second = try ProjectSnapshot.makeEncoder().encode(snapshot(edit: state))
        #expect(first == second)
    }
}

/// Hiding the badges is a decision worth saving; showing them — the default — is not.
@Test func hidingKeystrokesIsAChangeAndShowingThemIsNot() {
    #expect(!EditState(hidesKeystrokes: nil).changesAnything)
    #expect(!EditState(hidesKeystrokes: false).changesAnything)
    #expect(EditState(hidesKeystrokes: true).changesAnything)
}

/// The noise-removal setting, as the document sees it.
///
/// The document does not know what noise removal IS — the settings arrive already encoded,
/// which is how every authored sub-object crosses this boundary. What it must get right is that
/// absent means off, that a project written before the feature existed still opens, and that
/// asking for it counts as having changed something.
@Suite struct EditStateNoiseReductionTests {
    @Test func absentMeansOffAndCountsAsNoChange() {
        let untouched = EditState()
        #expect(untouched.noiseReductionData == nil)
        #expect(untouched.changesAnything == false)
    }

    /// **Present at all is a change**, which is not true of every field here — `burnsInCaptions`
    /// is a `Bool?` where `false` is not a change. There is no "off" value to write: turning the
    /// feature off removes the field.
    @Test func askingForNoiseRemovalIsAChangeWorthSaving() {
        var state = EditState()
        state.noiseReductionData = Data("{}".utf8)
        #expect(state.changesAnything, """
            a project with noise removal asked for reports nothing to save, so closing it would \
            not offer to save and the setting would be lost without a word
            """)
        state.noiseReductionData = nil
        #expect(state.changesAnything == false, "turning it off left the project looking dirty")
    }

    /// A project file written before this field existed decodes, with the feature off — the
    /// property every optional in this type is here to provide.
    @Test func aProjectWrittenBeforeThisFieldExistedStillOpens() throws {
        // **Built by encoding a state and deleting the key, not hand-written.** `audioMix` is
        // required by this type's `Codable`, and a hand-written fixture missing it fails for that
        // reason instead — which is a test of the fixture rather than of the field.
        var recent = EditState()
        recent.burnsInCaptions = true
        let encoded = try JSONEncoder().encode(recent)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded)
                                    as? [String: Any])
        object.removeValue(forKey: "noiseReductionData")
        let old = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(EditState.self, from: old)
        #expect(decoded.noiseReductionData == nil)
        #expect(decoded.burnsInCaptions == true, "the fixture decoded as empty, so this is vacuous")
    }

    @Test func theSettingSurvivesARoundTripThroughTheDocument() throws {
        var state = EditState()
        state.noiseReductionData = Data(#"{"strength":2.5,"floor":0.1}"#.utf8)
        let round = try JSONDecoder().decode(
            EditState.self, from: JSONEncoder().encode(state))
        #expect(round.noiseReductionData == state.noiseReductionData)
    }
}
