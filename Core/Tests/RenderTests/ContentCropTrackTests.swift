import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Render

private let epoch = BootEpoch(id: UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000001")!)
private let otherEpoch = BootEpoch(id: UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000002")!)

private func at(_ nanos: Int64, _ which: BootEpoch = epoch) -> HostInstant {
    HostInstant(epoch: which, hostTime: Nanoseconds(nanos))
}

private func sample(_ nanos: Int64, width: Double, scale: Double = 1,
                    epoch which: BootEpoch = epoch) -> ContentCropSample {
    ContentCropSample(instant: at(nanos, which),
                      content: CropRect(x: 0, y: 0, width: width, height: 1),
                      contentScale: scale)
}

/// A recording from before this record existed, and every imported one. The whole picture is
/// what such a recording has always been treated as, so nothing about an existing project may
/// change — and the refusal is a named value, never `nil`, because every frame has a crop.
@Test func aLogThatNeverSaidIsTheWholeRecording() {
    #expect(ContentCropTrack.unknown.crop(at: at(1_000)) == .whole)
    #expect(ContentCropTrack.unknown.isEmpty)
    #expect(ContentCropTrack.unknown.softestScale == nil)
}

@Test func theCropInForceIsTheMostRecentOneAtOrBeforeTheFrame() {
    let track = ContentCropTrack(samples: [sample(100, width: 1),
                                           sample(500, width: 0.5),
                                           sample(900, width: 0.75)])
    #expect(track.crop(at: at(100)).width == 1)
    #expect(track.crop(at: at(499)).width == 1)
    // The edge belongs to the new crop: the record is stamped with the frame it was read from.
    #expect(track.crop(at: at(500)).width == 0.5)
    #expect(track.crop(at: at(899)).width == 0.5)
    #expect(track.crop(at: at(5_000)).width == 0.75)
}

/// A resize is a step. Easing between two window sizes would put a sliver of background on
/// every frame of the ease — the exact artefact the mechanism exists to remove.
@Test func aResizeIsAStepAndNeverAnEase() {
    let track = ContentCropTrack(samples: [sample(0, width: 1), sample(1_000, width: 0.5)])
    #expect(track.crop(at: at(999)).width == 1)
    #expect(track.crop(at: at(1_000)).width == 0.5)
}

/// The first record is written at the first complete frame of its segment, so anything earlier
/// is an instant no frame was delivered for. Snapping those to `.whole` would put one frame of
/// background at the head of every window recording.
@Test func beforeTheFirstRecordTheFirstRecordStillAnswers() {
    let track = ContentCropTrack(samples: [sample(1_000, width: 0.5)])
    #expect(track.crop(at: at(0)).width == 0.5)
}

@Test func recordsArriveSortedHoweverTheyWereRead() {
    let jumbled = ContentCropTrack(samples: [sample(900, width: 0.75),
                                             sample(100, width: 1),
                                             sample(500, width: 0.5)])
    #expect(jumbled.crop(at: at(600)).width == 0.5)
    #expect(jumbled.crop(at: at(1_000)).width == 0.75)
}

/// Two boot sessions' host times overlap, and a crop from another boot is not a fact about
/// this one — the same rule `ClickTrack.ripplePhase` follows.
///
/// A real log cannot hold two epochs: its header pins one and `ObservationLog.checkEpoch`
/// refuses a record carrying another. This is a guard on the filter itself, so that removing
/// it is a red test rather than a behaviour nothing exercises.
@Test func aCropFromAnotherBootIsNotAFactAboutThisOne() {
    let track = ContentCropTrack(samples: [sample(100, width: 0.5),
                                           sample(200, width: 0.25, epoch: otherEpoch)])
    #expect(track.crop(at: at(300)).width == 0.5)
    #expect(track.crop(at: at(300, otherEpoch)).width == 0.25)
}

/// The number that says what cropping cannot do. Below 1 the window outgrew its buffer and was
/// downsampled; those pixels were never written and no crop brings them back.
@Test func theSoftestScaleIsTheWorstResolutionTheRecordingEverHad() {
    let track = ContentCropTrack(samples: [sample(0, width: 1, scale: 1),
                                           sample(100, width: 0.88, scale: 1.7733),
                                           sample(200, width: 1, scale: 0.7272)])
    #expect(track.softestScale == 0.7272)
}
