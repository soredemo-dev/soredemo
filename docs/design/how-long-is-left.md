# How long is left

*Code: `Core/Sources/Compositing/ExportETA.swift`.*

Reported as a defect by somebody using the app: *"it doesn't have a progress bar
so the user doesn't know the actual time the video is going to process"*. There
*is* a bar — a fraction, 60 points wide, in the toolbar — and the complaint is
right anyway, because a fraction and a time are different questions. A bar at 40%
tells you where you are. It does not tell you whether to wait or to go and do
something else, and that is the only decision anybody makes while an export runs.

## Estimated from elapsed time, not from a frame rate

The obvious spelling counts frames per second and divides the frames left by it.
It is worse: frames cost different amounts — a zoomed frame with a camera,
captions and a blurred wallpaper is several times the work of a still one — so a
rate measured over the first second describes the first second. The *fraction*
already integrates all of that, and elapsed ÷ fraction is the total the whole
export is heading for.

## Nothing is claimed until there is something to claim

The first estimate is the one that decides whether anybody believes the rest. An
export half a second in has a fraction near zero and a division near infinity;
showing "about 4 hours" and then "about 30 seconds" two seconds later teaches
somebody that the number is noise, and they will not read it again.

So nothing is shown until the export has been running for `settleSeconds` **and**
is past `settleFraction`. Both, not either: a fast export passes the fraction in a
moment with a rate measured over almost nothing, and a slow one sits below the
fraction for a while with plenty of elapsed time and no idea where it is going.

Once shown, the estimate is never cleared. An export that reaches 100% or reports
a moment of nonsense should not blank a number somebody is reading; it stops
updating, and the caller stops showing it when the job finishes.

## Smoothed, and rounded coarsely on purpose

The raw estimate wobbles frame to frame, so it is smoothed exponentially at 0.25
— a number reaches a change in about four updates, fast enough to follow an
export that genuinely slows down, slow enough that the reading does not jump while
somebody is looking at it.

Then it is rounded hard: "about 2 minutes", never "1 minute 47 seconds".
**Precision the number does not have is worse than no number.** A countdown that
says 47 seconds and takes 80 is a broken promise, where "about a minute" was never
one.

Under ten seconds it says so without counting, because a countdown wrong by two
seconds at the end is the most annoying place to be wrong. Seconds go in tens.
Anything above an hour is whole hours, because an estimate that long has stopped
being a plan and become a warning.

**55, not 60, and a test found the difference.** Rounding to the nearest ten
inside a boundary of 60 makes 55 seconds read as "60 seconds" — which is a minute
said the long way, and reads as a machine counting rather than as an estimate.

## A value, not a sentence

The first version returned English — `"about 3 minutes left"` — built by
interpolation, which cannot be a key in a string table: there is one key per
number. Returning the shape instead lets the interface hold six keys, one per
case, and interpolate the number on its own side where `LocalizedStringKey` turns
`\(n)` into `%lld` and the tables can carry it.
