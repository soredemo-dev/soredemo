import AVFoundation
import Foundation
import Observation
import Capture
import Compositing
import Overlays
import Project
import Timeline

/// **The preview: the asset a person is watching, how it was built, and what went wrong
/// building it.** The cut recording, the camera and the music laid beside it, the cleaned
/// microphone substituted in, the composition, and the player.
///
/// Moved out of `StageWindow` — step 2 of `docs/design/2026-10-23-splitting-the-stage-window.md`.
/// It was twelve `@State`s and five functions that only made sense together and could only be
/// reached by opening a window. **Which change triggers a rebuild stays with the window**: that
/// is a fact about the view's inputs, and its `.task(id:)`s call `load` here.
@Observable
final class EditorPreview {
    /// The recording's files: the screen, the camera beside it if there is one, and how much
    /// later than the screen the camera began. Passed in on each call rather than held, because
    /// the window can be handed a different recording without being rebuilt.
    struct Files {
        let mediaURL: URL
        let cameraURL: URL?
        let cameraStartOffsetNanos: Int64
    }

    private(set) var player: AVPlayer?
    /// The asset the current item was built from. Held because `AVAudioMix` addresses that
    /// asset's tracks, and after a cut the item's asset is a composition rather than the file.
    private(set) var playingAsset: AVAsset?
    private(set) var failure: String?
    /// What the last attempt to clean the microphone did, or why it could not. Shown, never
    /// swallowed — a person who turned this on and heard no difference is owed the reason.
    private(set) var noiseReductionNote: String?
    /// The cleaned microphone, once it exists. Rebuilt when the settings change; cleared when
    /// the feature is turned off.
    private var cleanedMicrophone: URL?
    /// Each audio track's integrated loudness, by index — see `Loudness`. Measured lazily, the
    /// first time levelling is asked for, because it decodes the whole audio track and most
    /// recordings are never levelled. Cleared when a different recording is loaded.
    private(set) var measuredLoudness: [Int: Loudness.Reading] = [:]
    /// The composition's music track, and the envelope it follows. Both are rebuilt with the
    /// composition rather than per frame: the track is a track and the envelope is a volume
    /// automation, and `AVAudioMix` takes them together.
    private(set) var musicTrackID: CMPersistentTrackID?
    /// Why a chosen piece did not become the bed, or `nil`. Reported rather than swallowed: a
    /// person who chose music and got silence is owed the reason.
    private(set) var musicFailure: String?
    /// The video track's thumbnails. Owned with the player so a cache is not discarded on every edit.
    let filmstrip = Filmstrip()

    // MARK: - building the preview

    func load(_ files: Files, into editor: EditorViewModel, pendingEdit: EditState?,
              scrubAudio: Bool) async {
        do {
            // Before the composition: `configuredComposition` reads
            // `StageCompositor.framingOverrides`, which `FramingReviewModel.load` publishes.
            editor.review.load(observationLogAt: ObservationWriter.expectedLogURL(forMediaURL: files.mediaURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            // The crop before the composition: `StagePlanner` fits the card to the CROPPED
            // aspect, so a composition built while the static still said "whole" would size the
            // card for a recording that is no longer what is being drawn. It is also what
            // `outputCoverage` below is computed from, which is the other reason it goes first.
            StageCompositor.crop = editor.crop
            let recording = AVURLAsset(url: files.mediaURL)
            // What `Match Recording` matches. Read once from the file, because it is a property
            // of the capture and no edit changes it.
            //
            // **Read before the zoom lane is built, and the order is load-bearing.** The lane's
            // depths now come from `outputCoverage`, which is computed from this size; reading
            // it afterwards meant the FIRST open of every project derived its zooms against the
            // 1920x1080 placeholder these properties start at, so a 3024x1964 recording exported
            // 9:16 showed one set of depths until something happened to rebuild.
            if let track = try await recording.loadTracks(withMediaType: .video).first {
                let natural = try await track.load(.naturalSize)
                editor.recordingShortSide = Int(min(natural.width, natural.height).rounded())
                editor.recordingSize = (width: Int(natural.width.rounded()),
                                 height: Int(natural.height.rounded()))
                // **The shape is NOT set from here, and the reason is a hazard rather than a
                // preference.** `.task(id: variant)` runs this function, so assigning `variant`
                // inside it cancels the very run doing the assigning — and `restore(_:)`, which
                // applies a saved shape, happens further down. A first draft did exactly that
                // and would have dropped a saved Portrait on the first open of a project,
                // silently, depending on where the cancellation landed. The recording's own
                // shape is offered in the picker instead; making it the default belongs
                // wherever a NEW recording is first handed to this window, not here.
                // `nominalFrameRate` is a Float and a capture reports 59.999996; rounding is what
                // makes "match the recording" mean 60 rather than a rate no container has.
                let nominal = try await track.load(.nominalFrameRate)
                if nominal > 0 { editor.recordingFrameRate = Int(nominal.rounded()) }
            }
            // The lane draws the same blocks the camera integrates, derived from the same
            // plan and now at the same coverage — a second derivation would be a second
            // answer, and a second coverage would be a second answer that agreed in landscape
            // and diverged in portrait, which is worse.
            StageCompositor.outputCoverage = editor.outputCoverage
            // The anchor first: the lane converts every block's absolute instant through it,
            // and blocks set before it would be drawn off the edge for one frame.
            editor.timeline.setZoomAnchor(editor.review.anchor)
            editor.refreshDerivedZooms()
            if editor.timeline.duration == nil {
                editor.timeline.load(duration: try await recording.load(.duration).seconds)
                // **After `load`, which resets the models.** Restoring first would be wiped by
                // the reset, silently, and a person would see their saved edit vanish on open.
                if let pendingEdit {
                    editor.restore(pendingEdit)
                    editor.savedPackage = ProjectStore.packageURL(forMediaAt: files.mediaURL)
                }
                // After `load`, which resets the model: reading the envelope is slow enough
                // that a person sees the strip before it arrives, and it must not be wiped by
                // the reset it raced.
                await editor.timeline.loadWaveform(from: recording)
            }
            // **The preview plays the EDITED asset, not the recording with an end time set.**
            // `EditedAsset` is what the export cuts with too, so the two cannot show different
            // videos — an edit a person can make but not see is a setting, not an edit.
            // **The cleaned microphone is substituted into the cut, so preview and export
            // cannot disagree.** Export is handed the asset the preview is playing — see
            // `runExport`'s header — so wiring it here wires both, and there is no second place
            // for the two to drift apart.
            let cut = try await EditedAsset.make(
                from: recording, by: editor.timeline.edit,
                substitutingAudio: await microphoneSubstitution(for: recording, files: files, editor: editor))
            // The camera laid alongside the cut recording, so one composition sees both. Returns
            // the cut asset untouched when there is no camera, so the common path costs nothing.
            let combined = try await CameraComposition.combine(
                screen: cut, cameraURL: files.cameraURL,
                cameraStartOffset: CMTime(value: files.cameraStartOffsetNanos, timescale: 1_000_000_000),
                musicURL: musicFileURL(files, editor: editor))
            StageCompositor.cameraTrackID = combined.cameraTrackID
            musicTrackID = combined.musicTrackID
            StageCompositor.cameraStyle = combined.cameraTrackID == nil ? nil : editor.cameraStyle
            let asset = combined.asset
            let composition = try await StageWindow.configuredComposition(
                for: asset, logForMediaURL: files.mediaURL, resolution: editor.resolution,
                recordingShortSide: editor.recordingShortSide, variant: editor.variant)
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            // The mix is applied at load too, not only on change: reopening a saved project
            // with the microphone muted must sound muted before anyone touches a control.
            await AudioMixBuilder.apply(editor.audioMix, to: item, of: asset)
            playingAsset = asset
            // **The filmstrip reads the UNCUT recording**, not the edited composition: the strip
            // is laid out in source time, and a composition's own timeline has already had the
            // cuts taken out of it — so a frame asked for at 30 s would come back from a
            // different moment after every edit.
            filmstrip.load(url: files.mediaURL)
            // Cheap: nothing is read until the first scrub, and a recording with no audio leaves
            // it silent rather than failing.
            editor.timeline.scrubAudio.isEnabled = scrubAudio
            editor.timeline.scrubAudio.open(files.mediaURL)
            player = AVPlayer(playerItem: item)
        } catch {
            failure = "\(error)"
        }
    }

    /// The cleaned microphone track, made if it is asked for and does not exist yet.
    ///
    /// **Returns the map `EditedAsset.make` takes, keyed by track index**, because a Soredemo
    /// recording has system audio and a microphone as separate tracks and only one of them is a
    /// room. `NoiseReducedAudio.microphoneTrackIndex` is where that index is decided, from the
    /// same named order the mix and the waveform read.
    ///
    /// **Cached on disk, keyed by the settings.** The pass is a full decode and re-encode of the
    /// audio; doing it again on every preview rebuild would make the strength slider unusable.
    /// A settings change makes a different filename rather than deleting the old one, so
    /// switching back is instant.
    ///
    /// Every refusal is reported into `noiseReductionNote` rather than swallowed. A person who
    /// turned this on and heard no difference is owed the reason, and "there is no measurable
    /// silence in this recording" is a thing they can act on.
    private func microphoneSubstitution(for recording: AVAsset, files: Files,
                                        editor: EditorViewModel) async -> [Int: AVAsset] {
        guard let settings = editor.noiseReduction,
              let index = NoiseReducedAudio.microphoneTrackIndex
        else { return [:] }

        // Inside the recording's own package, beside `media/` and `observations/`. A cleaned
        // track is derived from the recording and belongs with it: copying the project copies
        // it, and deleting the project takes it too.
        let destination = NoiseReducedAudio.destination(
            for: files.mediaURL, settings: settings,
            in: ProjectStore.packageURL(forMediaAt: files.mediaURL))
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            cleanedMicrophone = destination
            return [index: AVURLAsset(url: destination)]
        }
        do {
            let outcome = try await NoiseReducedAudio.write(from: recording, to: destination,
                                                            trackIndex: index, settings: settings)
            switch outcome {
            case .reduced(let url):
                cleanedMicrophone = url
                noiseReductionNote = nil
                return [index: AVURLAsset(url: url)]
            case .refused(let refusal):
                // **Left ON in the interface.** Turning the switch back off here would look like
                // the app disagreeing with the person; the note says what happened and the
                // switch still says what they asked for.
                cleanedMicrophone = nil
                noiseReductionNote = String(localized: "Noise removal did nothing: \(String(describing: refusal)).")
                return [:]
            }
        } catch {
            cleanedMicrophone = nil
            noiseReductionNote = String(localized: "Noise removal could not run: \(String(describing: error)).")
            return [:]
        }
    }

    // MARK: - music

    /// The bed's file inside the project package, or `nil` when there is none to play.
    private func musicFileURL(_ files: Files, editor: EditorViewModel) -> URL? {
        guard editor.music.isAudible, let filename = editor.music.filename else { return nil }
        return ProjectStore.packageURL(forMediaAt: files.mediaURL)
            .appending(path: MusicBed.directory, directoryHint: .isDirectory)
            .appending(path: filename)
    }

    /// **The envelope the bed follows, from the silences the timeline already found.** One
    /// decision about where the voice is: `SilenceFinder` makes it for the Silence lane and for
    /// auto-cutting, and `MusicDucking.speech(betweenSilences:over:)` turns the same answer
    /// inside out. A second detector here would be a second answer a person could catch
    /// disagreeing with the lane in front of them.
    ///
    /// Ducking off leaves the bed flat at its own level, which is what somebody laying music
    /// under a demo with no narration wants; no file leaves it empty, and `AudioMixBuilder`
    /// reads an empty envelope as silence rather than as unity.
    func musicRamps(editor: EditorViewModel) -> [MusicDucking.Ramp] {
        guard editor.music.isAudible, let duration = editor.timeline.duration else { return [] }
        guard editor.music.ducks else {
            return MusicDucking.ramps(speech: [], over: duration, settings: editor.music.ducking)
        }
        return MusicDucking.ramps(
            speech: MusicDucking.speech(betweenSilences: editor.timeline.silences, over: duration),
            over: duration, settings: editor.music.ducking)
    }

    /// **Copied into the package, not referenced.** `StageStylePicker.useImageBackground`'s
    /// argument exactly: a bed pointing at a file on the Desktop works until that file moves,
    /// and music that silently becomes silence is worse than music never offered.
    func adoptMusic(_ source: URL, files: Files, editor: EditorViewModel) {
        let name = source.lastPathComponent
        guard MusicBed.isSafeFilename(name) else {
            musicFailure = String(localized: "\(name) is not a name this can use.")
            return
        }
        do {
            try ProjectStore.copyIntoPackage(source, directory: MusicBed.directory,
                                             mediaURL: files.mediaURL)
        } catch {
            musicFailure = String(localized: "Could not copy \(name) into the project: \(String(describing: error))")
            return
        }
        musicFailure = nil
        editor.music = editor.music.changing(filename: .some(name), isEnabled: true)
    }

    /// The bed taken away, and with it any reason a piece could not be used — a reason about a
    /// piece no longer chosen is a reason about nothing.
    func removeMusic(editor: EditorViewModel) {
        editor.music = MusicBed.none
        musicFailure = nil
    }

    // MARK: - the mix

    /// Applies the mix to what is playing, WITHOUT reloading anything — see the window's
    /// `.task(id: editor.audioMix)` for why that matters. Measures each track's loudness the
    /// first time levelling is asked for and not before: a full audio decode for a feature most
    /// projects never turn on would be a second of work on every open. See
    /// `Loudness.measure(contentsOf:)`.
    func applyMix(_ files: Files, editor: EditorViewModel) async {
        guard let item = player?.currentItem, let asset = playingAsset else { return }
        if editor.audioMix.targetLoudness != nil, measuredLoudness.isEmpty {
            measuredLoudness = await Loudness.measure(contentsOf: files.mediaURL)
        }
        await AudioMixBuilder.apply(editor.audioMix, to: item, of: asset, measured: measuredLoudness,
                                    musicTrackID: musicTrackID, musicRamps: musicRamps(editor: editor))
    }

    /// "Reset audio": the measurements go with the settings, so a level asked for again is
    /// measured again.
    func forgetLoudness() { measuredLoudness = [:] }

    /// Whether a cleaned microphone was substituted into the last build — so turning the feature
    /// off rebuilds to take it out again.
    var hasCleanedMicrophone: Bool { cleanedMicrophone != nil }
}
