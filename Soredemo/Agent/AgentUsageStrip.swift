import Surface
import SwiftUI

/// Under the message box: how full the conversation is, and how much of the person's account
/// windows are used — **as their agent's provider last reported them**, never estimated here.
/// Before anything is reported it says whose account the message goes out under, which is what
/// the line said before there was anything to measure.
struct AgentUsageStrip: View {
    let model: AgentPanelModel

    /// From here a reading is worth a second look: it takes the caution colour and an icon, so
    /// the state is not carried by colour alone.
    static let caution: Double = 80

    var body: some View {
        let usage = model.usage
        Group {
            if usage.windows.isEmpty, !model.readsAccountUsage {
                Button {
                    model.readsAccountUsage = true
                    Task { await model.refreshAccountUsage(panelOpen: true) }
                } label: {
                    Label("Show plan usage", systemImage: "gauge.with.dots.needle.33percent")
                }
                .buttonStyle(.plain)
                .help(Text("Reads the sign-in your \(model.providerName) keeps on this Mac and asks its provider how much of your plan is used, while this panel is open. Nothing else is read or sent."))
            } else if usage.windows.isEmpty, let note = usage.note, let said = Self.say(note, provider: model.providerName) {
                said
            } else if usage.contextUsed == nil, usage.windows.isEmpty {
                Text("Sent by your \(model.providerName), under your account.")
            } else {
                HStack(spacing: Space.regular) {
                    if let used = usage.contextUsed { context(used: used, percent: usage.contextPercent) }
                    Spacer(minLength: Space.tight)
                    ForEach(usage.windows, id: \.minutes) { window($0) }
                    if usage.isStale {
                        Image(systemName: "clock.arrow.circlepath")
                            .help(Text("These numbers are over half an hour old; they could not be read again."))
                    }
                }
            }
        }
        .font(Type.detail)
        .foregroundStyle(Theme.Ink.tertiary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
        .help(Text("Sent by your \(model.providerName), under your account.") + Text(verbatim: " ")
              + Text("How full this conversation is, and how much of your account's usage windows are used, as your agent's provider last reported them."))
        .animation(.snappy, value: usage)
    }

    /// The conversation's share of the model's window, as a ring and a number; the token count
    /// alone while the window is not yet known.
    private func context(used: Int, percent: Double?) -> some View {
        let high = (percent ?? 0) >= Self.caution
        return HStack(spacing: Space.tight) {
            if let percent {
                ContextRing(fraction: percent / 100).frame(width: 11, height: 11)
            }
            if high { Image(systemName: "exclamationmark.triangle.fill") }
            Text("Context")
            Text(verbatim: percent.map(Self.percent) ?? used.formatted(.number.notation(.compactName)))
                .monospacedDigit()
        }
        .foregroundStyle(high ? Theme.Ink.caution : Theme.Ink.tertiary)
    }

    private func window(_ window: UsageWindow) -> some View {
        let high = window.limited || window.usedPercent >= Self.caution
        return HStack(spacing: Space.tight) {
            if window.limited {
                Image(systemName: "exclamationmark.octagon.fill")
            } else if high {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            Self.name(of: window)
            Text(verbatim: Self.percent(window.usedPercent)).monospacedDigit()
        }
        .foregroundStyle(high ? Theme.Ink.caution : Theme.Ink.tertiary)
        .help(Self.detail(of: window))
    }

    static func name(of window: UsageWindow) -> Text {
        switch window.minutes {
        case 300: Text("5-hour")
        case 10080: Text("Week")
        default: Text(verbatim: "\(window.minutes / 60)h")
        }
    }

    /// When the window starts over, from the reset the provider stated; "limit reached" first
    /// when it says requests are being refused.
    static func detail(of window: UsageWindow) -> Text {
        let resets = window.resets.map { Text("Resets \($0.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") }
        guard window.limited else { return resets ?? Text(verbatim: "") }
        guard let resets else { return Text("Limit reached") }
        return Text("Limit reached") + Text(verbatim: " · ") + resets
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// How much of the window is used, as a ring that fills clockwise from the top.
private struct ContextRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.Line.divider, lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }

}

extension AgentUsageStrip {
    /// What the strip says when the plan's usage could not be read before a message — so an
    /// empty strip is never mistaken for nothing having been used.
    static func say(_ note: AccountUsageReader.Outcome, provider: String) -> Text? {
        switch note {
        case .expired: Text("\(provider)'s sign-in here has expired; usage shows after your next message.")
        case .notSignedIn: Text("Sign in to \(provider) to see your plan's usage.")
        case .failed: Text("Your plan's usage could not be read; it shows after your next message.")
        case .windows, .refused: nil
        }
    }
}
