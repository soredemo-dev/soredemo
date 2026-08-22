import Foundation
import Timeline

/// A person's change to one derived zoom: where it starts, how long it lasts, or that it
/// should not happen at all.
///
/// **This is what makes a zoom an object on a timeline rather than a decision in a panel.**
/// Every comparable recorder puts zooms on their own lane and lets a person drag them —
/// Screen Studio shows each click as a keyframe with an adjustable duration, ScreenKite gives
/// zooms a lane of their own beside speed and annotations. A review panel that only offers
/// "don't zoom" can reject a zoom but cannot fix one that is a quarter of a second late.
///
/// **Keyed on the block's origin — the click — and that is the whole reason it works.** A
/// block is derived: re-running the plan builds new values, so an adjustment keyed on the
/// block itself would be lost the moment anything upstream changed. The click is an
/// observation and does not move.
///
/// **Deltas, not absolute times.** An adjustment says "a quarter of a second earlier", so it
/// survives `preRoll` being retuned or the gate changing its mind about which clicks merge —
/// the person's correction stays a correction rather than becoming a fixed position that
/// silently stops meaning what they meant. This is architecture rule 7's producer-value rule
/// applied to a value that is a relationship rather than a number.
public struct ZoomAdjustment: Hashable, Sendable, Codable {
    /// The instant of the click whose zoom this adjusts.
    public let origin: HostInstant
    /// Moves the whole block. Negative is earlier.
    public let startDelta: Nanoseconds
    /// Changes the end alone. Negative is shorter.
    public let endDelta: Nanoseconds
    /// The zoom does not happen. Kept alongside the deltas rather than replacing them so
    /// unsuppressing restores the timing a person had set, for the same reason `AudioMix`
    /// keeps a muted source's level.
    public let suppressed: Bool

    public init(origin: HostInstant, startDelta: Nanoseconds = Nanoseconds(0),
                endDelta: Nanoseconds = Nanoseconds(0), suppressed: Bool = false) {
        self.origin = origin
        self.startDelta = startDelta
        self.endDelta = endDelta
        self.suppressed = suppressed
    }

    public func matches(_ block: ZoomBlock) -> Bool {
        block.origin.epoch == origin.epoch
            && block.origin.hostTime.rawValue == origin.hostTime.rawValue
    }

    public var changesAnything: Bool {
        suppressed || startDelta.rawValue != 0 || endDelta.rawValue != 0
    }

    public func movedBy(_ delta: Int64) -> ZoomAdjustment {
        // Moving a block moves both ends, so the END delta is unchanged: it is measured from
        // the block's own end, which has already moved with the start.
        ZoomAdjustment(origin: origin,
                       startDelta: Nanoseconds(startDelta.rawValue + delta),
                       endDelta: endDelta, suppressed: suppressed)
    }

    public func resizedBy(_ delta: Int64) -> ZoomAdjustment {
        ZoomAdjustment(origin: origin, startDelta: startDelta,
                       endDelta: Nanoseconds(endDelta.rawValue + delta), suppressed: suppressed)
    }

    public func settingSuppressed(_ value: Bool) -> ZoomAdjustment {
        ZoomAdjustment(origin: origin, startDelta: startDelta, endDelta: endDelta,
                       suppressed: value)
    }
}

extension Array where Element == ZoomAdjustment {
    /// The derived blocks with these adjustments applied — what the camera integrates and what
    /// the lane draws.
    ///
    /// **A block whose adjustment would make it empty is dropped rather than clamped.** A
    /// person dragging an end past the start has said something, and the honest reading of it
    /// is "no zoom here"; a one-nanosecond block would be a zoom nobody can see and nobody
    /// asked for.
    public func applied(to blocks: [ZoomBlock]) -> [ZoomBlock] {
        blocks.compactMap { block in
            guard let adjustment = first(where: { $0.matches(block) }) else { return block }
            guard !adjustment.suppressed else { return nil }
            let start = block.start.hostTime.rawValue + adjustment.startDelta.rawValue
            // **A block dragged off the front STOPS, it does not shrink.** Clamping the start
            // alone lets the end keep travelling, so a block dragged well before zero collapses
            // and disappears — which is not what dragging a zoom to the beginning means. The
            // whole block is shifted back by however much the clamp took.
            let clampedStart = Swift.max(0, start)
            let clampShift = clampedStart - start
            let end = block.end.hostTime.rawValue + adjustment.startDelta.rawValue
                + adjustment.endDelta.rawValue + clampShift
            // A resize that inverts the block is a different gesture, and dropping it is the
            // honest reading of "no zoom here" — see the header.
            guard end > clampedStart else { return nil }
            return ZoomBlock(
                origin: block.origin,
                start: HostInstant(epoch: block.start.epoch, hostTime: Nanoseconds(clampedStart)),
                end: HostInstant(epoch: block.end.epoch, hostTime: Nanoseconds(end)),
                target: block.target, zoom: block.zoom)
        }
    }

    /// The adjustment for `origin`, or a fresh one — so a caller editing a block does not have
    /// to know whether it has been touched before.
    public func adjustment(for origin: HostInstant) -> ZoomAdjustment {
        first { $0.origin.epoch == origin.epoch
            && $0.origin.hostTime.rawValue == origin.hostTime.rawValue }
            ?? ZoomAdjustment(origin: origin)
    }

    /// `adjustment` replacing any earlier one for the same origin, and dropped entirely when it
    /// no longer changes anything — an adjustment that says "leave it alone" is not a record
    /// worth keeping, and keeping it would make `changesAnything` on the whole set lie.
    public func replacing(_ adjustment: ZoomAdjustment) -> [ZoomAdjustment] {
        var updated = filter {
            !($0.origin.epoch == adjustment.origin.epoch
              && $0.origin.hostTime.rawValue == adjustment.origin.hostTime.rawValue)
        }
        if adjustment.changesAnything { updated.append(adjustment) }
        return updated
    }
}
