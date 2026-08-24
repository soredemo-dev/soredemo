import Compositing
import Foundation
import Observation

/// What the codecs on THIS Mac actually do, asked once a run.
///
/// **Because the answer is a property of the machine, not of the app.** The bar test that
/// established ProRes 4444 as the only path keeping a coloured edge was run on one M1 Pro, and
/// the note it produced said "on this hardware" as though that settled it for everybody. It does
/// not: Soredemo runs on M1 through M5 and on Intel, Apple's media engines have gained formats
/// with every generation, and a table written today is wrong for somebody by next autumn. It is
/// the same mistake the frame-rate ladder made before it started asking the displays.
///
/// So the export panel asks. `CodecSupport` encodes a picture whose answer is known and reads
/// back what arrives.
///
/// **Not cached, and the cache is what taught this file something.** The first version keyed a
/// `UserDefaults` entry on the chip name and the OS build — which meant reading the chip name,
/// which is an ambient value, which the app tier may not do and the package's one audited
/// ambient file may not be widened for, because that file's whole-file permit rests on every
/// member of it reading the same clock.
///
/// Both refusals were right, and chasing them turned up that the cache was solving a problem
/// nobody had. The whole probe is under a second, it runs off the main actor, and it happens
/// once when an editor window opens. A cache would have bought that second back and paid for it
/// with an invalidation key that has to be correct forever.
@MainActor
@Observable
final class CodecVerdicts {
    static let shared = CodecVerdicts()

    /// Empty until asked. Inside, `nil` means the probe could not run — which is not the same as
    /// "no" and must not be shown as one.
    private(set) var keepsColourEdges: [ExportCodec: Bool?] = [:]
    private var asked = false

    private init() {}

    /// Asks, once per run of the app.
    func askOnce() {
        guard !asked else { return }
        asked = true
        // **Detached, because this encodes and decodes four short videos.** Measured at about
        // seven tenths of a second for all four; on the main actor that is a visible stall in a
        // window somebody has just opened.
        Task.detached(priority: .utility) {
            var answers: [ExportCodec: Bool?] = [:]
            for codec in ExportCodec.allCases {
                answers[codec] = await CodecSupport.keepsColourEdges(codec)
            }
            let settled = answers
            await MainActor.run { CodecVerdicts.shared.keepsColourEdges = settled }
        }
    }

    /// What to say under the codec picker, or `nil` when there is nothing true to say.
    ///
    /// **Silence while it is still asking, and silence when it could not.** A `nil` verdict means
    /// no encoder, no buffer or no frame back, and the difference between "we could not ask" and
    /// "the answer is no" is the difference between saying nothing and making a false promise.
    func note(for codec: ExportCodec) -> String? {
        guard let verdict = keepsColourEdges[codec], let keeps = verdict else { return nil }
        return keeps ? "Keeps coloured text edges on this Mac."
                     : "Coloured text edges will soften on this Mac."
    }
}
