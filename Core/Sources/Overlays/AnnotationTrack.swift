import Foundation
import Render
import Timeline

/// An arrow, line, box or ellipse drawn over the recording: what it points at, when it is on
/// screen, and how it looks.
///
/// **Anchored to the RECORDING, not to the frame**, and that is the decision the whole type is
/// built around. An arrow is pointing at something — a button, a line of code — and when the
/// camera zooms in on that thing the arrow has to go with it. Stored against the output it would
/// slide off its target the moment the camera moved, which is the same failure
/// `RedactionRegion`'s header describes and the same one `1a98402` was.
///
/// **`y` runs from the BOTTOM here, and from the TOP in `RedactionRegion`.** Two normalised
/// rectangles in one codebase with opposite `y` is a trap, so it is written down rather than
/// left to be discovered. The reason they differ is that they reach the picture by different
/// routes. A redaction is applied to the source image itself, where a rectangle picked off a
/// picture is naturally top-down. An annotation goes through
/// `RenderPlan.contentX(ofNormalised:)`/`contentY(ofNormalised:)` — the mapping the drawn cursor
/// uses — which is `NormalizedPoint`'s space: 0…1, bottom-left, Core Image's own. `Normalized.swift`
/// says the flip between a top-left pixel source and that space happens in exactly one place, so
/// storing these top-down and flipping them at the compositor would be a second flip, which is
/// precisely what `StagePlanner.placement`'s header refuses.
///
/// **Every item carries its own style**, for `TextItem`'s reason: a shared one is right for the
/// three arrows in a sequence and wrong the moment one of them needs to be the one you look at.
public struct AnnotationItem: Sendable, Equatable, Codable, Identifiable {
    /// Stable across edits, so a selection or an inspector binding survives a retime.
    ///
    /// **A counter, not a `UUID`, and `AnnotationTrack` mints it** — `TextItem`'s reasoning
    /// exactly: `Overlays` is a deterministic target and the architecture plugin keeps it away
    /// from ambient randomness, and the same sequence of edits producing the same ids is what
    /// makes a project file comparable to itself.
    public let id: Int
    public var shape: AnnotationShape
    /// Where the drag began, 0…1 over the SOURCE, bottom-left origin.
    public var startX: Double
    public var startY: Double
    /// Where it ended. For `.arrow` this is the end the head is on — the point a person was
    /// aiming at, which is why the head is not on the other one.
    public var endX: Double
    public var endY: Double
    public var style: AnnotationStyle
    public var start: Nanoseconds
    public var end: Nanoseconds
    /// How it arrives and leaves. Reuses `TextAnimation` rather than declaring a parallel
    /// vocabulary: it is already progress-based rather than time-based, so the same annotation
    /// looks the same in a 30 fps preview and a 60 fps export, and a second enum would be a
    /// second place to add a case to.
    public var animation: TextAnimation
    /// What a `.callout` says. Empty for every other shape, and kept on them rather than cleared:
    /// switching a callout to an arrow and back must not discard what somebody typed.
    public var text: String
    /// The picture an `.image` shows, by file name in the project's image directory. Empty on
    /// every other shape and kept for `text`'s reason.
    public var imageName: String

    public init(id: Int, shape: AnnotationShape,
                startX: Double, startY: Double, endX: Double, endY: Double,
                style: AnnotationStyle = .default,
                start: Nanoseconds, end: Nanoseconds,
                animation: TextAnimation = .fade,
                text: String = "", imageName: String = "") {
        self.id = id
        self.text = text
        self.imageName = imageName
        self.shape = shape
        // Clamped into the frame rather than trapped: these arrive from a drag AND from a
        // decoder, and a point stored outside 0…1 would put an arrow off the edge of every
        // export silently. `RedactionRegion` clamps for the same reason.
        self.startX = Self.clamp(startX)
        self.startY = Self.clamp(startY)
        self.endX = Self.clamp(endX)
        self.endY = Self.clamp(endY)
        self.style = style.clamped
        self.start = start
        self.end = end
        self.animation = animation
    }

    /// **Non-finite becomes 0.5, not a trap and not 0.** A `NaN` here comes from a decoder or
    /// from a division in a drag handler, and `min(max(NaN, 0), 1)` is `NaN` — the clamp does
    /// not catch it, which is the sort of thing that survives review because the expression
    /// looks like it does. Landing in the middle of the frame makes a corrupt annotation
    /// visible rather than parking it in a corner where nobody looks.
    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    /// Hand-written for rule 8: the synthesised decoder assigns the stored properties directly,
    /// so every clamp above would be skipped and a hand-edited project file could carry a `NaN`
    /// into a `CGAffineTransform`. Routed back through the initialiser instead of re-checking
    /// here, so there is one definition of what a valid item is.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(Int.self, forKey: .id),
                  shape: try container.decode(AnnotationShape.self, forKey: .shape),
                  startX: try container.decode(Double.self, forKey: .startX),
                  startY: try container.decode(Double.self, forKey: .startY),
                  endX: try container.decode(Double.self, forKey: .endX),
                  endY: try container.decode(Double.self, forKey: .endY),
                  style: try container.decode(AnnotationStyle.self, forKey: .style),
                  start: try container.decode(Nanoseconds.self, forKey: .start),
                  end: try container.decode(Nanoseconds.self, forKey: .end),
                  // Absence-tolerant: an annotation written before this field existed opens
                  // rather than failing, and `.fade` is what those were drawn with.
                  animation: try container.decodeIfPresent(TextAnimation.self, forKey: .animation)
                      ?? .fade,
                  // Absent is empty, for `animation`'s reason: every annotation saved before
                  // callouts existed has no such key, and none of them had anything to say.
                  text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                  // Absent is empty, for `text`'s reason: no annotation saved before pictures
                  // existed showed one.
                  imageName: try container.decodeIfPresent(String.self, forKey: .imageName) ?? "")
    }

    private enum CodingKeys: String, CodingKey {
        case id, shape, startX, startY, endX, endY, style, start, end, animation, text, imageName
    }

    public var duration: Nanoseconds { Nanoseconds(max(0, end.rawValue - start.rawValue)) }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < end.rawValue
    }

    /// Nothing to draw: the two points are the same, which is what a click that never became a
    /// drag produces.
    public var isEmpty: Bool { startX == endX && startY == endY }

    /// How far through its entrance or exit this item is at `time`.
    ///
    /// **The same computation `TextItem.animationState` does, and deliberately not shared with
    /// it.** Factoring the two into one function would need a protocol over `start`/`end`/
    /// `animation`, and the saving is nine lines; what it would cost is that a change to how
    /// titles animate would silently change how arrows animate. These are two features that
    /// currently agree, not one feature in two places — see `TextAnimation`'s own header for
    /// what the shared part actually is.
    ///
    /// `rise` is dropped rather than returned: an annotation is anchored to a place in the
    /// recording, and one that slid up into position would be pointing somewhere else while it
    /// arrived.
    public func animationState(at time: Nanoseconds) -> (opacity: Double, scale: Double) {
        let span = Double(duration.rawValue) / 1_000_000_000
        guard span > 0 else { return (1, 1) }
        let lead = min(span * TextAnimation.durationFraction,
                       TextAnimation.maximumSeconds, span / 2)
        guard lead > 0 else { return (1, 1) }
        let position = Double(time.rawValue - start.rawValue) / 1_000_000_000
        let state: (opacity: Double, rise: Double, scale: Double)
        if position < lead {
            state = animation.state(at: position / lead)
        } else if position > span - lead {
            state = animation.state(at: (span - position) / lead)
        } else {
            return (1, 1)
        }
        return (state.opacity, state.scale)
    }
}

/// Every annotation on one recording, in the recording's SOURCE time.
///
/// Source time for `TextTrack`'s reason: a cut moves everything after it, and a track stored in
/// output time would have to be rewritten on every trim.
///
/// **Overlapping items are allowed and are drawn together.** Three arrows converging on one
/// control is a diagram, not a mistake — the same distinction `TextTrack` draws against
/// `CaptionTrack`, where two at once IS a bug.
public struct AnnotationTrack: Sendable, Equatable, Codable {
    public var items: [AnnotationItem]
    /// The next id to mint. Carried rather than derived from `items.count`, so deleting an item
    /// cannot make the next one reuse a dead id and attach an old selection to a new arrow.
    public private(set) var nextID: Int

    public init(items: [AnnotationItem] = [], nextID: Int? = nil) {
        self.items = items.sorted { $0.start.rawValue < $1.start.rawValue }
        self.nextID = max(nextID ?? 0, (items.map(\.id).max() ?? -1) + 1)
    }

    /// Decoded absence-tolerantly: a track written before `nextID` existed recovers one from its
    /// items rather than failing to open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([AnnotationItem].self, forKey: .items)
        let stored = try container.decodeIfPresent(Int.self, forKey: .nextID)
        self.init(items: items, nextID: stored)
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Everything on screen at `time`, in the order they were added — so a later annotation
    /// draws over an earlier one, which is what "bring to front" means without a z-order field.
    public func items(at time: Nanoseconds) -> [AnnotationItem] {
        items.filter { $0.contains(time) }
    }

    /// A new item with a freshly minted id — the only way to make one, so nothing else has to
    /// know how ids are allocated.
    public func adding(shape: AnnotationShape,
                       startX: Double, startY: Double, endX: Double, endY: Double,
                       start: Nanoseconds, end: Nanoseconds,
                       style: AnnotationStyle = .default,
                       animation: TextAnimation = .fade,
                       imageName: String = "") -> AnnotationTrack {
        let item = AnnotationItem(id: nextID, shape: shape,
                                  startX: startX, startY: startY, endX: endX, endY: endY,
                                  style: style, start: start, end: end, animation: animation,
                                  imageName: imageName)
        return AnnotationTrack(items: items + [item], nextID: nextID + 1)
    }

    /// **A step's number: its place among the steps in the order they appear**, from 1 — by start
    /// time, then by id, so two at one instant are still two numbers. `nil` for anything that is
    /// not a step. Derived, never stored, so removing or moving one renumbers the rest.
    public func stepNumber(of id: Int) -> Int? {
        let steps = items.filter { $0.shape == .step }
            .sorted { ($0.start.rawValue, $0.id) < ($1.start.rawValue, $1.id) }
        return steps.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// What is drawn in an item: a step's number, anything else's own words.
    public func drawnText(for item: AnnotationItem) -> String {
        guard item.shape == .step else { return item.text }
        return stepNumber(of: item.id).map(String.init) ?? ""
    }

    public func removing(_ id: Int) -> AnnotationTrack {
        AnnotationTrack(items: items.filter { $0.id != id }, nextID: nextID)
    }

    /// One item replaced, matched on identity. A no-op for an id nobody has — rule 8: never trap
    /// on an input that came from outside.
    public func replacing(_ item: AnnotationItem) -> AnnotationTrack {
        guard items.contains(where: { $0.id == item.id }) else { return self }
        return AnnotationTrack(items: items.map { $0.id == item.id ? item : $0 }, nextID: nextID)
    }

    /// The same annotations in the EDIT's time: items inside a cut disappear, items spanning one
    /// are split at it, and everything after moves back by what the cut removed.
    ///
    /// **A split keeps the id and both halves keep the same geometry.** The arrow points at the
    /// same thing on both sides of a cut — it is one annotation shown twice, not two — so an
    /// inspector showing "this one" should show both halves selected.
    public func retimed(through timeline: EditTimeline) -> AnnotationTrack {
        AnnotationTrack(items: items.flatMap { item in
            timeline.clips.compactMap { clip -> AnnotationItem? in
                let start = max(item.start.rawValue, clip.sourceStart.rawValue)
                let end = min(item.end.rawValue, clip.sourceEnd.rawValue)
                guard end > start,
                      let outputStart = timeline.outputTime(atSource: SourceTime(nanos: start))?.nanoseconds
                else { return nil }
                return AnnotationItem(
                    id: item.id, shape: item.shape,
                    startX: item.startX, startY: item.startY,
                    endX: item.endX, endY: item.endY,
                    style: item.style, start: outputStart,
                    end: Nanoseconds(outputStart.rawValue + clip.playLength(ofSource: Nanoseconds(end - start)).rawValue),
                    animation: item.animation)
            }
        }, nextID: nextID)
    }

    private enum CodingKeys: String, CodingKey { case items, nextID }
}
