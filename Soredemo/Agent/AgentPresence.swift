import Surface
import SwiftUI

/// Over the preview while the panel's agent works: a pill that says who is editing and what it is
/// doing now, and a band of light across the picture each time a cut lands — so the person sees the
/// agent in the video they are watching, not only in a panel beside it.
///
/// Drawn over the dark preview, so it uses the dark theme's ink there in both themes. Still when
/// motion is reduced.
struct AgentPresence: View {
    let model: AgentPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = -0.4

    var body: some View {
        ZStack(alignment: .top) {
            if model.isRunning {
                pill
                    .padding(.top, Space.regular)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !reduceMotion {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .white.opacity(0.10), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: UnitPoint(x: sweep, y: 0), endPoint: UnitPoint(x: sweep + 0.4, y: 1))
                    .allowsHitTesting(false)
                    .opacity(sweep > -0.4 && sweep < 1.2 ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy, value: model.isRunning)
        .onChange(of: model.editsLanded) {
            guard !reduceMotion else { return }
            sweep = -0.4
            withAnimation(.easeInOut(duration: 0.7)) { sweep = 1.4 }
        }
        .allowsHitTesting(false)
    }

    private var pill: some View {
        HStack(spacing: Space.snug) {
            PulseDot()
            Text("\(model.providerName) is editing").font(Type.detail.weight(.semibold))
            Text(verbatim: "·").font(Type.detail).foregroundStyle(.secondary)
            Shimmer { Text(phrase).font(Type.detail) }
        }
        .padding(.horizontal, Space.regular).padding(.vertical, Space.tight + 2)
        // Opaque: a content surface (D7), the dark theme's raised paper over the dark preview.
        .background(Theme.Surface.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }

    private var phrase: LocalizedStringKey { AgentPhrase.activity(model.activity, agent: model.providerName) }
}
