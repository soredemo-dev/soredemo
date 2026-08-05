/// FNV-1a, 64-bit. Deterministic across processes, unlike Swift's per-process-seeded
/// `Hasher`. Identity only: not collision resistant against an adversary, so it must
/// never be used on the evidence path, which needs `ContentDigest`.
func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325       // FNV offset basis, 64-bit
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3       // FNV prime, 64-bit
    }
    return hash
}
