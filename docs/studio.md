# Soredemo Studio

`soredemo studio` opens a local browser application for the human side of the verified-demo
workflow:

1. discover or bootstrap Demo Plans;
2. optionally collect a bounded, read-only semantic snapshot;
3. optionally ask an external Agent provider for a structured proposal;
4. review and approve the exact validated plan hash;
5. save the plan atomically;
6. execute the same production runner used by `soredemo render`;
7. observe sampled production capture pixels and ordered operational events;
8. inspect evidence, the final MP4, and the portable proof.

The shipped UI is static HTML, CSS, and small vanilla JavaScript. The server uses Node's HTTP
implementation and Server-Sent Events, so alpha.1 adds no production or development
dependency and no runtime CDN, font, image, telemetry, or cloud service. SSE was selected
because runs emit a one-way ordered event stream; reconnect uses sequence IDs, and state
changes remain ordinary authenticated HTTP requests.

The preview is sampled from the production CDP frames at at most 2 fps. It is explicitly
non-authoritative, is not persisted by default, and never feeds the compositor or encoder.
Slow clients may lose preview events; durable semantic events are bounded and replayable.

Studio does not start the user's application. There is no timeline editor, manual recording,
pause, takeover, narration, webcam, mobile, or Agent-controlled browser in alpha.1.

When no Agent provider is available, an existing plan can still be selected, or a user can
paste/edit Demo Plan JSON and choose **Validate edited JSON**. Manual and Agent-authored plans
use the same validator, exact-hash approval, atomic save, coordinator, runner, compositor,
encoder, and proof engine. Sending another request in the same Agent conversation revises the
prior proposal; any edit invalidates its prior approval.
