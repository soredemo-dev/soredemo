import Foundation
import Geometry
import Project
import Timeline

/// One deliberate press on an element, from the moment it happened to the moment of the next.
///
/// **Derived from the observation log's clicks**, so it has an origin and re-deriving cannot
/// disagree with the zooms about which clicks there were. `origin` is the click's instant — the
/// same key a `ZoomBlock` carries — so a step and the zoom that came from one click find each
/// other. See `docs/design/2026-10-25-a-recording-knows-its-steps.md`.
public struct RecordedStep: Hashable, Sendable {
    /// The click's instant, and the step's identity.
    public let origin: HostInstant
    /// Where the step ends: the next step's click, or the recording's end.
    public let end: HostInstant
    /// 1-based, in order.
    public let number: Int
    /// The label the interface itself shows on what was pressed — "Export".
    public let label: String
    /// The AX role of the element the label came from.
    public let role: String?
    /// The application's name, from the chain's `AXApplication` root, when the walk reached it.
    public let application: String?
    /// Where the pressed element is, for a guide's crop.
    public let frame: NormalizedFrame?

    /// Public for the app's tests, which build steps without writing a log. Production steps come
    /// from `RecordedSteps.steps(from:recordingEnd:)` and nowhere else.
    public init(origin: HostInstant, end: HostInstant, number: Int, label: String, role: String?,
                application: String?, frame: NormalizedFrame?) {
        self.origin = origin
        self.end = end
        self.number = number
        self.label = label
        self.role = role
        self.application = application
        self.frame = frame
    }
}

public enum RecordedSteps {
    /// Two presses on one element closer than this are one step — a double-click is one thing
    /// a person did. **Uncalibrated**, like the module's other constants; macOS's default
    /// double-click interval is longer, and a deliberate second press is rarely this quick.
    public static let samePressInterval = Nanoseconds(500_000_000)

    /// Roles a step's label may not come from, and at which the search for one stops: a
    /// window's and a page's titles are the content open in them
    /// (`docs/design/2026-10-25-a-window-title-is-content.md`), and an application's name is
    /// the step's `application`, not what was pressed.
    static let rolesThatAreNotLabels: Set<String> = ["AXWindow", "AXWebArea", "AXApplication"]

    /// The steps in `chains`, in time order.
    ///
    /// **A press that names nothing is not a step**: no element (the walk found nothing, or the
    /// click was on this app's own window), or no title on the element or on any ancestor up to
    /// its window. "Click here" over an unexplained point is the blank step guide tools are
    /// criticised for, and a step this app cannot name is one it should not claim.
    public static func steps(from chains: [AXChainRecord], recordingEnd: HostInstant) -> [RecordedStep] {
        struct Press {
            let instant: HostInstant
            let label: String
            let role: String?
            let application: String?
            let frame: NormalizedFrame?
        }
        var presses: [Press] = []
        for chain in chains.sorted(by: { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }) {
            guard let hit = chain.hit, let named = label(of: hit, ancestors: chain.ancestors) else { continue }
            let press = Press(instant: chain.instant, label: named.label, role: named.role,
                              application: chain.ancestors.last { $0.role == "AXApplication" }?.title,
                              frame: hit.frame)
            if let previous = presses.last, previous.label == press.label, previous.role == press.role,
               previous.frame == press.frame, previous.instant.epoch == press.instant.epoch,
               press.instant.hostTime.rawValue - previous.instant.hostTime.rawValue
                   < samePressInterval.rawValue {
                continue
            }
            presses.append(press)
        }
        return presses.enumerated().map { index, press in
            let next = index + 1 < presses.count ? presses[index + 1].instant : recordingEnd
            return RecordedStep(origin: press.instant, end: next, number: index + 1,
                                label: press.label, role: press.role,
                                application: press.application, frame: press.frame)
        }
    }

    /// The hit's own title, or the nearest ancestor's below the window — the text inside a
    /// button is an untitled `AXStaticText`, and its button has the label.
    public static func label(of hit: AXElementRecord,
                      ancestors: [AXElementRecord]) -> (label: String, role: String?)? {
        for element in [hit] + ancestors {
            if let role = element.role, rolesThatAreNotLabels.contains(role) { return nil }
            if let title = element.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return (title, element.role)
            }
        }
        return nil
    }
}
