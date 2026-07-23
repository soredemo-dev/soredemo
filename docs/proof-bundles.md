# Proof bundles

```bash
soredemo render demos/create-project.yaml \
  --out output/create-project.mp4 \
  --proof output/create-project.proof

soredemo proof verify output/create-project.proof
```

Studio enables proof output by default. A proof is serialized from evidence already collected
by the production run; it performs no browser action, capture, render, or encode.

The atomic directory contains `manifest.json`, `actions.json`, `capture.json`, `cursor.json`,
`media.json`, and `SHA256SUMS`. `verified-live` denotes execution/capture/target/cursor/scale/
timing/pixel gates. `encoded-verified` additionally denotes encoded-index and media
validation; completed alpha.1 output receives the latter.

Proofs contain plan/config/output hashes, redacted action summaries, painted-scale and
timestamp integrity, cursor-action counts, target-pixel evidence summary, encoder
backpressure, and validated media properties. They exclude typed values, passwords, cookies,
storage, environment variables, full frame sequences, executable paths, and absolute paths.
