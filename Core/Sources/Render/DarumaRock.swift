import Foundation

/// A poked daruma's rock: it tips away from the push and swings back upright on its round base,
/// a damped swing `A·e^(−t/τ)·sin(ωt)` — starts upright, goes the pushed way first, overshoots,
/// settles. 七転び八起き. Pure, so its shape is a test. `docs/design/2026-10-27-the-daruma-tips-flies-and-paints.md`.
public struct DarumaRock: Equatable, Sendable {
    /// +1 pushed toward the right (clockwise), −1 toward the left.
    public var direction: Double

    static let reach = 16.0, decay = 0.42, frequency = 1.7, squeeze = 0.28

    public init(direction: Double) { self.direction = direction < 0 ? -1 : 1 }

    /// Touched `x` points along a character `width` wide: it tips away from the touch.
    public init(touchedAt x: Double, width: Double) { self.init(direction: x < width / 2 ? 1 : -1) }

    /// Degrees, clockwise, `t` seconds after the push; upright before it.
    public func angle(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        return direction * Self.reach * exp(-t / Self.decay) * sin(2 * .pi * Self.frequency * t)
    }

    /// Still enough to stop drawing the rock: its swing is under 0.3°.
    public func isSettled(at t: Double) -> Bool { t > 0 && Self.reach * exp(-t / Self.decay) < 0.3 }

    /// Its eyes squeezed shut, the first moment after the push.
    public func isSqueezing(at t: Double) -> Bool { t >= 0 && t < Self.squeeze }
}
