import Geometry

/// A deliberately trivial producer: it counts the `Evidence` it is given and
/// emits that count as a `Derived<Int>`, citing exactly the evidence it
/// counted (design doc D-P4).
///
/// **Why this exists.** The producer-value rule (`AGENTS.md`) has to be
/// exercised against a real producer, not asserted in the abstract against a
/// hand-built `Derived` — see `Tests/GraphTests/ProducerValueTests.swift`.
/// `ReferenceProducer` is that producer, kept as small as possible so the
/// tests are about the rule and not about what the producer computes. Every
/// later producer (Phase 3's framing producer, Phase 4's beat producer) has
/// the same shape: derive a value from `Evidence`, hand the result to
/// `Derived.applyingProduced(_:)`, never assign to a `Derived` directly.
public enum ReferenceProducer {
    /// This producer's identity, as it appears in every `Derivation` it
    /// writes.
    public static let id = ProducerID("reference-producer")

    /// Bumped when the counting rule itself changes, so a re-derivation under
    /// a new version is a distinct claim (see `Derivation.producerVersion`).
    public static let version = 1

    /// Counts `evidence` and returns a `Derived<Int>` citing exactly the
    /// evidence counted.
    ///
    /// Always `.accepted`: this producer has no gate to fail — it is
    /// incapable of rejecting, which is part of what makes it deliberately
    /// trivial. `evidence` is non-empty by construction (`Evidence`, Task
    /// 12), so the count is always at least 1 and the result always cites at
    /// least one ref.
    public static func produce(from evidence: Evidence) -> Derived<Int> {
        Derived(value: evidence.count, origin: .generated(Derivation(
            producer: id,
            producerVersion: version,
            evidence: evidence,
            outcome: .accepted
        )))
    }
}
