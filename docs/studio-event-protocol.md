# Studio event protocol

Every event contains schema version 1, UUID event and run IDs, a strictly increasing per-run
sequence, producer monotonic timestamp, event type, privacy classification, and bounded
payload. Sequence is authoritative for UI order; wall-clock time is not a media clock.

The journal retains at most 2,048 durable events. Reconnect requests events after a sequence
and then uses the current snapshot. Terminal snapshots remain immutable. Families cover run
lifecycle, action resolution/execution, capture/preview/metrics, cursor/target evidence,
composition, encoding, proof, and artifacts. Typed text never appears.

`capture.preview` is ephemeral application-pixel data. It is sampled at no more than 2 fps,
delivered only after the CDP frame acknowledgement, and omitted from durable replay. Each SSE
client has a 128-event queue. Preview events are dropped first; a client that cannot consume
semantic events is disconnected rather than blocking production.
