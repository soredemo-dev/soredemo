import Foundation
import Testing
@testable import Render

// `Spring.step`: one exact step of a damped harmonic oscillator,
//     x″ = −ω²·(x − target) − 2ζω·x′,
// with the target held constant across the step. Every expectation below is a property of that
// equation, checked against the function rather than against a copy of its arithmetic.

private let cases: [(zeta: Double, label: String)] = [
    (0.05, "lightly underdamped"), (0.9, "the pointer's default"), (1.0, "critically damped"),
    (1.5, "overdamped"), (2.0, "the most overdamped a setting allows"),
]

/// Satisfies the equation: the acceleration a central difference of the returned velocity gives is
/// the one the equation demands at that position and velocity.
@Test(arguments: cases.map(\.zeta))
func theStepSatisfiesTheEquationOfMotion(zeta: Double) {
    let omega = 12.0, target = 0.3, h = 1e-5
    for t in [0.01, 0.05, 0.2] {
        let (x, v) = Spring.step(position: 1, velocity: -2, target: target, omega: omega, zeta: zeta, dt: t)
        let (_, vAfter) = Spring.step(position: 1, velocity: -2, target: target, omega: omega, zeta: zeta, dt: t + h)
        let (_, vBefore) = Spring.step(position: 1, velocity: -2, target: target, omega: omega, zeta: zeta, dt: t - h)
        let measured = (vAfter - vBefore) / (2 * h)
        let demanded = -omega * omega * (x - target) - 2 * zeta * omega * v
        #expect(abs(measured - demanded) < 1e-3 * max(1, abs(demanded)), "ζ \(zeta), t \(t): \(measured) against \(demanded)")
    }
}

/// The velocity returned is the derivative of the position returned.
@Test(arguments: cases.map(\.zeta))
func theVelocityIsTheDerivativeOfThePosition(zeta: Double) {
    let h = 1e-6
    for t in [0.02, 0.1, 0.4] {
        let (_, v) = Spring.step(position: -0.5, velocity: 3, target: 0.1, omega: 9, zeta: zeta, dt: t)
        let (xAfter, _) = Spring.step(position: -0.5, velocity: 3, target: 0.1, omega: 9, zeta: zeta, dt: t + h)
        let (xBefore, _) = Spring.step(position: -0.5, velocity: 3, target: 0.1, omega: 9, zeta: zeta, dt: t - h)
        #expect(abs((xAfter - xBefore) / (2 * h) - v) < 1e-5 * max(1, abs(v)), "ζ \(zeta), t \(t)")
    }
}

/// **Exact, so the step size does not matter**: two steps of 7 ms land where one of 14 ms does —
/// the property that lets the path be baked at a fixed step and read at any other.
@Test(arguments: cases.map(\.zeta))
func twoStepsLandWhereOneStepOfTheirSumDoes(zeta: Double) {
    let (x1, v1) = Spring.step(position: 0.8, velocity: 1.5, target: 0.2, omega: 20, zeta: zeta, dt: 0.007)
    let (x2, v2) = Spring.step(position: x1, velocity: v1, target: 0.2, omega: 20, zeta: zeta, dt: 0.007)
    let (x, v) = Spring.step(position: 0.8, velocity: 1.5, target: 0.2, omega: 20, zeta: zeta, dt: 0.014)
    #expect(abs(x2 - x) < 1e-12 && abs(v2 - v) < 1e-9, "ζ \(zeta)")
}

@Test(arguments: cases.map(\.zeta))
func aStepOfNoTimeChangesNothing(zeta: Double) {
    let (x, v) = Spring.step(position: 0.4, velocity: -1.2, target: 0.9, omega: 15, zeta: zeta, dt: 0)
    #expect(abs(x - 0.4) < 1e-15 && abs(v + 1.2) < 1e-15)
}

/// At rest on the target it stays there, and moving the whole problem moves the answer by as much.
@Test(arguments: cases.map(\.zeta))
func restAtTheTargetStaysAndTheSolutionMovesWithTheTarget(zeta: Double) {
    let (x, v) = Spring.step(position: 0.5, velocity: 0, target: 0.5, omega: 10, zeta: zeta, dt: 0.3)
    #expect(abs(x - 0.5) < 1e-15 && abs(v) < 1e-15)
    let (a, va) = Spring.step(position: 0.1, velocity: 2, target: 0.6, omega: 10, zeta: zeta, dt: 0.05)
    let (b, vb) = Spring.step(position: 0.1 + 3, velocity: 2, target: 0.6 + 3, omega: 10, zeta: zeta, dt: 0.05)
    #expect(abs((b - 3) - a) < 1e-12 && abs(vb - va) < 1e-12)
}

/// Damped, so the oscillator's energy never grows over a step.
@Test(arguments: cases.map(\.zeta))
func energyNeverGrows(zeta: Double) {
    let omega = 14.0
    func energy(_ x: Double, _ v: Double) -> Double { 0.5 * v * v + 0.5 * omega * omega * x * x }
    var (x, v) = (1.0, 4.0)
    for _ in 0..<200 {
        let next = Spring.step(position: x, velocity: v, target: 0, omega: omega, zeta: zeta, dt: 0.004)
        #expect(energy(next.0, next.1) <= energy(x, v) * (1 + 1e-12), "ζ \(zeta)")
        (x, v) = next
    }
}

/// From rest, a critically damped or overdamped spring approaches the target without crossing it;
/// an underdamped one overshoots.
@Test(arguments: cases.map(\.zeta))
func overshootIsExactlyTheUnderdampedCase(zeta: Double) {
    var crossed = false
    var (x, v) = (1.0, 0.0)
    for _ in 0..<2000 {
        (x, v) = Spring.step(position: x, velocity: v, target: 0, omega: 10, zeta: zeta, dt: 0.002)
        if x < -1e-12 { crossed = true }
    }
    #expect(crossed == (zeta < 1), "ζ \(zeta)")
}

/// **No seam at ζ = 1.** Just under, at and just over critical damping give the same motion to
/// within what that difference in ζ moves it — a formula switch with a jump would show here.
@Test func thereIsNoSeamAtCriticalDamping() {
    for t in [0.01, 0.1, 0.5] {
        let below = Spring.step(position: 1, velocity: -1, target: 0, omega: 8, zeta: 1 - 1e-7, dt: t)
        let at = Spring.step(position: 1, velocity: -1, target: 0, omega: 8, zeta: 1, dt: t)
        let above = Spring.step(position: 1, velocity: -1, target: 0, omega: 8, zeta: 1 + 1e-7, dt: t)
        #expect(abs(below.0 - at.0) < 1e-5 && abs(above.0 - at.0) < 1e-5, "t \(t)")
        #expect(abs(below.1 - at.1) < 1e-4 && abs(above.1 - at.1) < 1e-4, "t \(t)")
    }
}

/// Overdamped means overdamped: at ζ = 2 a released spring has fallen less far by t = 0.2 s than a
/// critically damped one does — the motion is slower, not the critical case relabelled.
@Test func anOverdampedSpringIsSlowerThanACriticalOne() {
    let critical = Spring.step(position: 1, velocity: 0, target: 0, omega: 10, zeta: 1, dt: 0.2).0
    let overdamped = Spring.step(position: 1, velocity: 0, target: 0, omega: 10, zeta: 2, dt: 0.2).0
    #expect(overdamped > critical + 0.05, "critical \(critical), overdamped \(overdamped)")
}
