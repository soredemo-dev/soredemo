import Compositing
import Foundation
import Observation

/// What the codecs on THIS Mac actually do, asked once a run.
///
/// The answer is a property of the machine, not of the app: this runs on M1
/// through M5 and on Intel, and Apple's media engines gain formats every
/// generation. `docs/design/what-a-codec-keeps.md` records why it is asked
/// rather than tabled, and why the obvious cache was removed.
@MainActor
@Observable
final class CodecVerdicts {
    static let shared = CodecVerdicts()

    /// Empty until asked. Inside, `nil` means the probe could not run — not the
    /// same fact as "no", and never shown as one.
    private(set) var keepsColourEdges: [ExportCodec: Bool?] = [:]
    private var asked = false

    private init() {}

    /// Asks, once per run of the app.
    func askOnce() {
        guard !asked else { return }
        asked = true
        // Detached: this encodes and decodes four short videos, measured at about
        // seven tenths of a second for all four. On the main actor that is a
        // visible stall in a window somebody has just opened.
        Task.detached(priority: .utility) {
            var answers: [ExportCodec: Bool?] = [:]
            for codec in ExportCodec.allCases {
                answers[codec] = await CodecSupport.keepsColourEdges(codec)
            }
            let settled = answers
            await MainActor.run { CodecVerdicts.shared.keepsColourEdges = settled }
        }
    }

    /// What to say under the codec picker, or `nil` when there is nothing true to
    /// say — which covers both the unfinished probe and the failed one.
    func note(for codec: ExportCodec) -> String? {
        guard let verdict = keepsColourEdges[codec], let keeps = verdict else { return nil }
        return keeps ? "Keeps coloured text edges on this Mac."
                     : "Coloured text edges will soften on this Mac."
    }
}
