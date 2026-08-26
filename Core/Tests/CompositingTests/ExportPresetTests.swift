import Foundation
import Testing
@testable import Compositing

/// **A destination, as the four settings it implies** — and the tests that keep the list from
/// becoming three names for one file.
@Suite struct ExportPresetTests {
    /// **The claim that justifies offering a list at all.** Three entries that produce nearly
    /// the same export ask a person to choose between things that do not differ. Compared on
    /// the settings rather than on the names, because the names are the part that cannot drift.
    @Test func theThreePresetsAreActuallyDifferent() {
        let shapes = ExportPreset.all.map {
            [$0.resolution.rawValue, $0.codec.rawValue, $0.frameRate.rawValue,
             $0.codec.takesBitRate ? "\($0.quality.bitsPerPixel)" : "n/a"].joined(separator: "/")
        }
        #expect(Set(shapes).count == ExportPreset.all.count,
                "two presets produce the same export: \(shapes)")
        // …and no two share a name either, which is what a picker is keyed on.
        #expect(Set(ExportPreset.all.map(\.name)).count == ExportPreset.all.count)
    }

    /// Every preset round-trips: choosing one and reading the four controls back must name the
    /// same preset, or the picker would show "Custom" the instant somebody picked something.
    @Test func everyPresetRecognisesItsOwnSettings() {
        for preset in ExportPreset.all {
            #expect(ExportPreset.matching(resolution: preset.resolution, codec: preset.codec,
                                          frameRate: preset.frameRate, quality: preset.quality)
                    == preset, "\(preset.name) did not recognise itself")
        }
    }

    /// A hand-tuned combination is not a preset, and saying so is the point: a picker that
    /// claimed "Web" over settings nobody would call Web would be lying about what will be
    /// written.
    @Test func aCombinationNobodyOffersIsNotAPreset() {
        #expect(ExportPreset.matching(resolution: .p2160, codec: .hevc,
                                      frameRate: .fps120, quality: .best) == nil)
    }

    /// **Quality is compared only where it can matter.** ProRes encodes to its own profile and
    /// ignores the bit rate — `takesBitRate` is false — so two ProRes settings differing only in
    /// quality produce the same file, and reporting them as different would show "Custom"
    /// beside an export identical to the one the preset makes.
    @Test func aProResExportIsStillTheEditingPresetWhateverTheQualitySays() {
        #expect(!ExportCodec.proRes.takesBitRate, "this test is about a codec that ignores it")
        for quality in ExportQuality.choices {
            #expect(ExportPreset.matching(resolution: .matchRecording, codec: .proRes,
                                          frameRate: .matchRecording, quality: quality)
                    == ExportPreset.editing, "quality \(quality.bitsPerPixel) broke the match")
        }
    }

    /// A codec that DOES take a bit rate must not get the same forgiveness: two H.264 exports at
    /// different bit rates are two different files, and calling the small one "Web" would
    /// misdescribe what is about to be written.
    @Test func aCodecThatUsesTheBitRateIsNotForgivenIt() {
        #expect(ExportCodec.h264.takesBitRate)
        #expect(ExportPreset.matching(resolution: .p1080, codec: .h264,
                                      frameRate: .matchRecording, quality: .small) == nil)
    }

    /// **The web preset keeps the recording's frame rate on purpose.** Cursor smoothing and the
    /// camera springs are motion; halving a 60 fps capture throws away what this app spent its
    /// effort on. Pinned as a decision so a later tidy-up cannot make all three say 30.
    @Test func onlyTheAttachmentPresetLowersTheFrameRate() {
        #expect(ExportPreset.web.frameRate == .matchRecording)
        #expect(ExportPreset.editing.frameRate == .matchRecording)
        #expect(ExportPreset.message.frameRate == .fps30,
                "the small preset stopped lowering the rate, which is where its bytes came from")
    }

    /// Every preset says what it buys. An entry whose detail is empty is one a person has to
    /// choose blind.
    @Test func everyPresetExplainsItself() {
        for preset in ExportPreset.all {
            #expect(!preset.name.isEmpty && !preset.detail.isEmpty, "\(preset.name) says nothing")
        }
    }
}
