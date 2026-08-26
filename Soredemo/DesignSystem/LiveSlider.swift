import SwiftUI

/// **Kept as a type rather than inlined as a plain `Slider`.** The `live` state is still
/// carrying its weight — a slider bound straight through to a clamped model value fights the
/// thumb, because the model rounds or clamps and the binding reads back a different number than
/// the drag put in. This holds what the drag says and reports it onward.
struct LiveSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        Slider(value: Binding(get: { live ?? value },
                              set: { live = $0; commit($0) }), in: range) { editing in
            // Released: hand the model back the authority it lends this view for the drag, so
            // the next `value` it publishes is what the slider shows.
            if !editing { live = nil }
        }
    }
}
