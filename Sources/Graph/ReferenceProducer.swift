import Geometry

/// A deliberately trivial producer: counts the `Evidence` it is given and emits the
/// count as a `Derived<Int>` citing exactly that evidence. It exists so the
/// producer-value rule is exercised against a real producer, and it is the shape
/// every later producer follows: derive from `Evidence`, hand the result to
/// `Derived.applyingProduced(_:)`, never assign to a `Derived` directly.
public enum ReferenceProducer {
    /// This producer's identity, as it appears in every `Derivation` it writes.
    public static let id = ProducerID("reference-producer")

    /// Bumped when the counting rule changes, so a re-derivation under a new version
    /// is a distinct claim.
    public static let version = 1

    /// Counts `evidence` and returns a `Derived<Int>` citing exactly it. Always
    /// `.accepted`: this producer has no gate. `Evidence` is non-empty by
    /// construction, so the count is at least 1.
    public static func produce(from evidence: Evidence) -> Derived<Int> {
        Derived(value: evidence.count, origin: .generated(Derivation(
            producer: id,
            producerVersion: version,
            evidence: evidence,
            outcome: .accepted
        )))
    }
}
