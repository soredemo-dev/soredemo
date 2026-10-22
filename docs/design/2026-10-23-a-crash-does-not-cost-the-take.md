# A crash does not cost the take

2026-10-23. Audit R1, the one finding ranked high: **a crash during a take loses the take.**
Two causes, and both have to go.

1. **The segment being written is unreadable.** The master is a QuickTime movie written by
   `AVAssetWriter` with no movie fragments, so its index (`moov`) is written by `finishWriting`;
   a process that dies before that leaves a file with frames and no index.
2. **What did survive is deleted.** `TemporaryFileMediaSink.sweepLeftoverDirectories()` runs at
   launch and removes every `soredemo-preview-*` scratch package — finished segments of a paused
   take, and whole recordings never saved, included.

## What the SDK says

`AVAssetWriter.h`, `movieFragmentInterval`: *"When movie fragments are used, a partially written
asset whose writing is unexpectedly interrupted can be successfully opened and played up to
multiples of the specified time interval."* And: *"for best writing performance to external
storage devices, set the movieFragmentInterval to 10 seconds or greater."* The scratch file is on
the internal disk (`FileManager.temporaryDirectory`).

## Decisions

**Fragments every 5 seconds on the master.** A crash costs at most the last five seconds instead
of the whole segment. Five rather than the SDK's ten because the scratch is internal and the
cost of the interval is the tail a crash loses. *To measure before it ships:* that a fragmented
master reads identically everywhere the project reads one — the composition, `AVAssetReader`,
the exporters, `RetimedDurationTests`, the probe — and that writing it costs no frames under the
probe's frame-accounting sections. If either fails, the interval is the knob, not the decision.

**The in-flight segment is written inside its own scratch package**, not as a loose
`soredemo-capture-<uuid>.mov` in the temporary directory, so a survivor can be matched to the
take it belongs to. A finished segment is still moved into `media/` as today.

**Recover instead of sweeping.** At launch, a scratch package with any readable movie in it is
not deleted; the person is asked once — *A recording did not finish. Open what was recorded?* —
with *Open* and *Delete*. Nothing is deleted without that answer. A package with no readable
movie is swept as today. The partial segment opens as an imported video (no segment table was
written; the observation log is read as far as its last complete line, which `JSONLReader`
already does), so the zooms and cursor of a recovered take come from the log it left.

**Tested the way the failure happens**: a child process starts a real writer, appends frames
for longer than one fragment interval, and is killed with `SIGKILL` — no `finishWriting`, no
cleanup. The parent then opens the file and counts what plays. Red without fragments (nothing
plays), green with them (at least one interval plays). The sweep's replacement gets a unit test
on a scratch directory: a package with a movie survives launch, one without is removed.

## Order

1. Measure the fragmented master against everything that reads one.
2. The kill test, then fragments.
3. In-flight segment inside its package.
4. Recovery prompt instead of the sweep.
