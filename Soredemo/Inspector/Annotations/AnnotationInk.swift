import Foundation
import Render

/// The colours an annotation can be.
///
/// **A named few, not a colour well**, and the restraint is the same one `TextOverlayStyle`'s
/// header argues for: every control is something a person has to understand before they can put
/// a mark on the screen. These five are picked to stay legible over a screen recording — a
/// screenshot is mostly white and mostly grey — and to be tellable apart from each other by
/// someone who is colourblind, which a free colour well cannot promise.
///
/// **In the app, not in `Render`.** `AnnotationStyle` takes the three components and does not
/// need to know that a person chose from a list; a palette in the render tier would be a public
/// option with nothing exercising it, which is the shape `CameraOverlayStyle.borderOpacity` had.
enum AnnotationInk: String, CaseIterable, Hashable {
    case red, amber, green, blue, ink

    var displayName: String {
        switch self {
        case .red: "Red"
        case .amber: "Amber"
        case .green: "Green"
        case .blue: "Blue"
        case .ink: "Ink"
        }
    }

    var red: Double {
        switch self {
        case .red: 0.93
        case .amber: 0.98
        case .green: 0.16
        case .blue: 0.16
        case .ink: 0.08
        }
    }

    var green: Double {
        switch self {
        case .red: 0.16
        case .amber: 0.72
        case .green: 0.72
        case .blue: 0.45
        case .ink: 0.08
        }
    }

    var blue: Double {
        switch self {
        case .red: 0.16
        case .amber: 0.10
        case .green: 0.32
        case .blue: 0.93
        case .ink: 0.10
        }
    }

    /// Which entry a stored style is closest to.
    ///
    /// **Nearest rather than exact, and a `Picker` is why.** A style decoded from a project
    /// saved by a build with a different palette — or hand-edited — would match nothing, and a
    /// `Picker` with a selection outside its options shows a blank row and quietly rewrites the
    /// value on the next interaction. Answering with the closest entry keeps the control honest
    /// about what it is going to do.
    static func nearest(to style: AnnotationStyle) -> AnnotationInk {
        allCases.min { a, b in a.distance(to: style) < b.distance(to: style) } ?? .red
    }

    private func distance(to style: AnnotationStyle) -> Double {
        pow(red - style.red, 2) + pow(green - style.green, 2) + pow(blue - style.blue, 2)
    }
}
