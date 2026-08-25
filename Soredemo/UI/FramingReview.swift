import Compositing
import Foundation
import Framing
import Geometry
import Observation
import Project
import SwiftUI
import Timeline

/// **`review-ui`: every generated value shows its origin, review state, and reason.**
///
/// The camera's zoom is derived — a gate looks at the accessibility chain under each click
/// and either frames the control or refuses with a named reason. Until this surface existed
/// the refusals were computed and discarded at the seam that consumed them, so a recording
/// that zoomed nowhere gave a person nothing to act on. This is where the reasons come out,
/// and where a person disagrees with them.
///
/// **Overrides are first-class, which is a rule and not a preference.** An authored decision
/// always wins over a derived one and is never silently replaced — enforced by
/// `FramingPlan.resolved(with:)` consulting overrides before the gate, so re-deriving a plan
/// cannot overwrite one. This model only carries them; it does not get to decide precedence.
@Observable
final class FramingReviewModel {
    /// Every decision the gate made, accepted and refused alike.
    private(set) var plan = FramingPlan(entries: [])
    /// What a reviewer decided instead. Project state, never read from the observation log:
    /// a judgement is not an observation.
    private(set) var overrides: [FramingOverride] = []
    /// For rendering instants as times into the recording. `nil` when the log had no header,
    /// which is different from "the recording starts at zero".
    private(set) var anchor: EpochAnchor?
    private(set) var failure: String?

    /// The revision a pointer fallback's rectangle belongs to, taken from the first entry
    /// that recorded one. `nil` disables the fallback, which is also what a plan with no
    /// clicks at all means.
    private(set) var fallbackRevision: GeometryRevision?

    /// **The pointer's recorded path, held only so a zoom added by hand can be placed on
    /// it.** Nothing here draws it — `PointerTrack` inside the compositor is the one that
    /// does — and it is deliberately not used to second-guess any decision the gate made.
    private(set) var pointerSamples: [PointerSample] = []

    /// **What the camera will actually do**, fallback included. Not `plan.resolved(with:)`:
    /// a review surface showing "no zoom" beside a video that zooms would be worse than no
    /// surface at all.
    var resolved: [ResolvedFraming] {
        guard let fallbackRevision else { return plan.resolved(with: overrides) }
        return plan.resolvedWithPointerFallback(overrides: overrides, revision: fallbackRevision)
    }

    /// Loads the decisions for one recording. A log that cannot be read is reported, not
    /// shown as an empty plan: "no clicks were observed" and "the file could not be opened"
    /// are different facts and a reviewer told the first about the second is misinformed.
    func load(observationLogAt url: URL?) {
        guard let url else {
            plan = FramingPlan(entries: [])
            anchor = nil
            failure = nil
            return
        }
        do {
            plan = try FramingPlanReader.plan(fromObservationLogAt: url)
            anchor = try FramingPlanReader.anchor(fromObservationLogAt: url)
            fallbackRevision = plan.fallbackRevision
            pointerSamples = try FramingPlanReader.pointerSamples(fromObservationLogAt: url)
            failure = nil
        } catch {
            plan = FramingPlan(entries: [])
            anchor = nil
            fallbackRevision = nil
            pointerSamples = []
            failure = "\(error)"
        }
        publish()
    }

    /// Frame this click at the given rectangle whatever the gate concluded — including a
    /// rectangle no accessibility element ever reported.
    func author(_ action: FramingOverride.Action, at instant: HostInstant) {
        overrides.removeAll { $0.matches(instant) }
        overrides.append(FramingOverride(epoch: instant.epoch, instant: instant.hostTime,
                                          action: action))
        publish()
    }

    /// Applies decisions from a saved project. Replaces rather than merges: the file is the
    /// record of what a person decided, and merging would leave decisions from a recording
    /// they are no longer looking at.
    func restoreOverrides(_ saved: [FramingOverride]) {
        overrides = saved
        publish()
    }

    /// **Adds a zoom at a time into the recording where no click asked for one.**
    ///
    /// This is the whole of "manual zoom", and almost all of it already existed: an override
    /// at an instant the gate never saw is honoured by `FramingPlan.resolved(with:)`'s orphan
    /// pass, becomes a `FramedClick`, and becomes a `ZoomBlock` like any other. What was
    /// missing was a way to make one — every override until now hung on a click.
    ///
    /// **Centred on the pointer**, because during a demo that is where the action is, and it
    /// is the same argument `pointerFallbackExtent` rests on. The sample at or before the
    /// instant, so the answer is a position the recording actually observed rather than one
    /// interpolated between two; the first sample after it when the playhead sits before any
    /// pointer was seen; and the middle of the frame when the log has no pointer at all,
    /// which is a recording made without the input tap.
    ///
    /// Returns the instant it authored, so the caller can scroll to it — or `nil` when there
    /// is no anchor, which means the log had no header and no offset can be turned into an
    /// absolute instant. A `nil` here is "this recording cannot carry one", not a failure to
    /// report as an error.
    @discardableResult
    func authorZoom(atOffset offset: Nanoseconds) -> HostInstant? {
        guard let anchor else { return nil }
        // `EpochAnchor.instant(atOffset:)` and not an addition here: its own header calls
        // it THE composition-offset-to-host-instant conversion, and `1a98402` was a caller
        // doing exactly this arithmetic by hand and dropping a term.
        let instant = anchor.instant(atOffset: offset)
        let sample = pointerSamples.last { $0.instant.hostTime.rawValue <= instant.hostTime.rawValue }
            ?? pointerSamples.first
        // The revision is the sample's own: a rectangle means nothing without the coordinate
        // system it was measured in, and taking the fallback's would be asserting the two
        // agree. Zero only when there is no observation at all to take one from.
        let revision = sample?.revision ?? fallbackRevision ?? GeometryRevision(id: 0)
        let centre = sample?.position ?? NormalizedPoint(x: 0.5, y: 0.5)
        author(.frame(FramingPlan.manualFrame(centredOn: centre, revision: revision)), at: instant)
        return instant
    }

    /// Whether `authorZoom(atOffset:)` would do anything — the anchor is the only thing it
    /// needs, so a control can be disabled for the honest reason rather than doing nothing.
    var canAuthorZoom: Bool { anchor != nil }

    /// Withdraws a reviewer's decision, returning the click to whatever the gate says. Not
    /// the same as suppressing it: this restores the derived answer rather than authoring a
    /// new one, and the row's origin goes back to `.derived`.
    func withdrawOverride(at instant: HostInstant) {
        overrides.removeAll { $0.matches(instant) }
        publish()
    }

    /// Hands the overrides to the compositor. A static because AVFoundation owns every
    /// compositor instance; set before the composition is built, like the other seams there.
    private func publish() {
        StageCompositor.framingOverrides = overrides
    }

    /// How far into the recording an instant falls, formatted, or `nil` when there is no
    /// anchor or the instant belongs to another boot session.
    func timeLabel(for instant: HostInstant) -> String? {
        guard let anchor,
              let offset = FramingPlanReader.offset(of: instant, from: anchor),
              offset.rawValue >= 0
        else { return nil }
        let seconds = Double(offset.rawValue) / 1_000_000_000
        return String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - The surface

/// The inspector column. Standard SwiftUI components only — they get Liquid Glass from the
/// system and respond to its slider, which a hand-rolled surface does not.
struct FramingReviewInspector: View {
    let model: FramingReviewModel
    /// Called after any authored decision. The host rebuilds the composition so the preview
    /// actually moves — an override that only changed this list would be a form, not a review.
    let onChange: () -> Void
    /// Where the reviewer wants a zoom they are authoring to be centred. The click's own
    /// position is the honest default: it is the one point the recording knows the user was
    /// pointing at when the gate refused.
    let authoredExtent = 0.25

    /// Only used when this inspector is hosted on its own; the window builds
    /// `FramingReviewSections` directly and supplies the playhead it is showing.
    var body: some View {
        List { FramingReviewSections(model: model, onChange: onChange, playhead: Nanoseconds(0)) }
            .listStyle(.sidebar)
    }

    @ViewBuilder var summary: some View {
        LabeledContent("Zooms", value: "\(model.resolved.count { $0.target != nil })")
        LabeledContent("Clicks seen", value: "\(model.plan.entries.count)")
        let overridden = model.resolved.count { $0.wasOverridden }
        if overridden > 0 {
            LabeledContent("Your decisions", value: "\(overridden)")
        }
        // The refusal breakdown IS the diagnosis. A recording that zooms nowhere has every
        // one of its reasons in this table.
        ForEach(model.plan.rejectionCounts.sorted { $0.value > $1.value }, id: \.key) { reason, count in
            LabeledContent(Self.label(for: reason), value: "\(count)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func row(for entry: ResolvedFraming) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack {
                Text(model.timeLabel(for: entry.instant) ?? "—")
                    .monospacedDigit()
                Spacer()
                stateBadge(for: entry)
            }
            // The origin, in words: a reviewer looking at someone else's project must be
            // able to tell an override from an agreement without opening a file.
            Text(Self.originDescription(for: entry))
                .font(Type.detail)
                .foregroundStyle(.secondary)
            controls(for: entry)
        }
        .padding(.vertical, Space.hairline)
    }

    @ViewBuilder private func stateBadge(for entry: ResolvedFraming) -> some View {
        if entry.wasOverridden {
            Label(entry.target == nil ? "You: no zoom" : "You: zoom",
                  systemImage: "person.fill.checkmark")
                .font(Type.detail)
        } else if case .pointerFallback = entry.origin {
            Label("Zoom to pointer", systemImage: "cursorarrow.rays").font(Type.detail)
        } else if entry.target != nil {
            Label("Zoom", systemImage: "plus.magnifyingglass").font(Type.detail)
        } else {
            Label("No zoom", systemImage: "minus.magnifyingglass")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func controls(for entry: ResolvedFraming) -> some View {
        HStack(spacing: Space.snug) {
            if entry.target == nil {
                Button("Zoom here") {
                    model.author(.frame(authoredFrame(for: entry)), at: entry.instant)
                    onChange()
                }
            } else {
                Button("Don't zoom") {
                    model.author(.suppress, at: entry.instant)
                    onChange()
                }
            }
            if entry.wasOverridden {
                // **Two different acts behind one call.** Withdrawing an override on a click
                // hands the moment back to the gate; withdrawing one the gate never saw
                // deletes the zoom outright, because there is nothing underneath it. Same
                // call, and it must not claim to be the same act — "use the automatic
                // decision" on a zoom nobody automated is a sentence that cannot be true.
                Button(Self.isManual(entry) ? "Remove this zoom" : "Use the automatic decision") {
                    model.withdrawOverride(at: entry.instant)
                    onChange()
                }
            }
        }
        .buttonStyle(.link)
        .font(Type.detail)
    }

    /// Whether this row is a zoom somebody added where the recorder saw no click — an
    /// override with nothing underneath it. A function rather than an inline `if case`
    /// because a `ViewBuilder` cannot hold a statement.
    static func isManual(_ entry: ResolvedFraming) -> Bool {
        if case .authored(let over) = entry.origin { return over == nil }
        return false
    }

    /// A rectangle centred on the gate's own target if it had one, and on the middle of the
    /// frame otherwise. **Deliberately not derivable from the gate**: this is the reviewer's
    /// rectangle, and the point of the producer-value rule is that a value like it survives
    /// re-derivation. The click position is not on `ResolvedFraming`, so the centre falls
    /// back rather than being invented from the target that was refused.
    private func authoredFrame(for entry: ResolvedFraming) -> NormalizedFrame {
        let existing = entry.target?.frame
        let centreX = existing.map { $0.origin.x + $0.size.width / 2 } ?? 0.5
        let centreY = existing.map { $0.origin.y + $0.size.height / 2 } ?? 0.5
        let half = authoredExtent / 2
        return NormalizedFrame(
            origin: NormalizedPoint(x: min(max(centreX - half, 0), 1 - authoredExtent),
                                    y: min(max(centreY - half, 0), 1 - authoredExtent)),
            size: NormalizedSize(width: authoredExtent, height: authoredExtent),
            revision: existing?.revision ?? GeometryRevision(id: 0))
    }

    /// One sentence per row saying where the value came from and, when a gate refused, which
    /// one. The rejection is shown even on an overridden row — a reviewer who forced a zoom
    /// past `tooLarge` should still see that `tooLarge` is what they overrode.
    static func originDescription(for entry: ResolvedFraming) -> String {
        switch entry.origin {
        case .derived:
            if let role = entry.target?.role {
                return "Framed automatically from the \(role) under the click."
            }
            if entry.target != nil { return "Framed automatically." }
            return "Refused automatically."
        case .pointerFallback(let reason):
            // Both halves, deliberately: the camera DID zoom, and the reason accessibility
            // could not name a target is still the useful thing to read.
            return "Zoomed to the pointer, because: \(label(for: reason))"
        case .authored(let overridden):
            guard let overridden else { return "Your decision. The recorder saw no click here." }
            if let reason = overridden.rejection {
                return "Your decision, over: \(label(for: reason))"
            }
            return "Your decision, over the automatic zoom."
        }
    }

    /// Plain-language names for the gates. The raw case names are the persisted contract and
    /// travel with the derivation; these are for the person reading the row.
    static func label(for rejection: FramingRejection) -> String {
        switch rejection {
        case .hitTestReturnedNothing:   return "Nothing was under the click"
        case .noFrameRecorded:          return "The control reported no position"
        case .staleObservation:         return "The window may have moved during the check"
        case .notComparable:            return "The control and the click were in different coordinate systems"
        case .doesNotContainTheClick:   return "The control found was not where the click was"
        case .degenerateRectangle:      return "The control had no size"
        case .partlyOffscreen:          return "The control was partly outside the recording"
        case .tooLarge:                 return "The control filled too much of the screen to be worth zooming to"
        case .bestCandidateOnTheTruncationBoundary:
            return "The search was cut short before it found the right control"
        }
    }
}


/// The review sections without a `List` of their own, so the inspector can put the style
/// picker above them in ONE list. A second `List` nested in the first would draw its own
/// scroll view and its own background — visibly wrong, and it would swallow the outer
/// list's sidebar styling.
struct FramingReviewSections: View {
    let model: FramingReviewModel
    let onChange: () -> Void
    /// Where a zoom added by hand goes. The playhead rather than a time typed into a field:
    /// the person is looking at the frame they want zoomed, and asking them to name its
    /// timestamp would be asking them to read it off the very thing they are pointing at.
    let playhead: Nanoseconds

    var body: some View {
        let inspector = FramingReviewInspector(model: model, onChange: onChange)
        Section("Summary") { inspector.summary }
        Section("Add a zoom") {
            Button {
                model.authorZoom(atOffset: playhead)
                onChange()
            } label: {
                Label("Zoom at the playhead", systemImage: "plus.magnifyingglass")
            }
            .disabled(!model.canAuthorZoom)
            Text(model.canAuthorZoom
                 ? "Centred on the pointer, then adjustable on the timeline like any other zoom."
                 : "This recording has no observation header, so a time in it cannot be named.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        if let failure = model.failure {
            Section("Could not read the decisions") {
                Label(failure, systemImage: "exclamationmark.triangle").font(Type.label)
            }
        }
        Section("Clicks") {
            if model.resolved.isEmpty {
                Text("No clicks were observed with accessibility available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.resolved.enumerated()), id: \.offset) { _, entry in
                    inspector.row(for: entry)
                }
            }
        }
    }
}
