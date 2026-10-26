# A character, not a logo

2026-10-26. The owner sent a screen recording of Grok Bot — a face that lives in the Mac's
notch, the iPhone's island and a widget — and asked for a mascot that cute, and that smooth to
interact with: "the daruma cannot be designed like Grok Bot." This is the research and the design
direction; the choice of body is the owner's, and the prototype is for making it.

## What the reference does, read off the recording and its makers' own account

- **One character in code, every state morphing into every other.** Its head of design built the
  icon in code so each state, shape and expression could morph smoothly
  ([X](https://x.com/i/trending/2087312709960270330)).
- **Three behaviours in the notch:** tucked while it works, emerging when something needs the
  person, expanding into a small workspace when they want more — plus a corner peek and a cursor
  companion ([the design guide](https://x.ai/bot/guides/designing-grok-bot-with-grok-bot)).
- **Tuned by feel, on the real asset:** springs, distance, scale and easing adjusted live; "hold
  the look down-left longer", "bounce is too exaggerated"; transitions compared at 280 and 340 ms.
- **Read off the recording:** pill eyes that blink and look; a glow tinted by state — blue working,
  red failed, green done; a list of the current task's steps with the current one emphasised;
  coloured chips for work in parallel; an error face with closed eyes and a retry button.

## What makes such a character feel alive, from those who build them

A base layer that is never frozen — breath, a small bob; gaze mapped from the pointer and blended
rather than snapped; hover and click as short interrupts that hand back to idle without a reset;
the app saying *what happened* and the character deciding *how it reacts*
([Rive characters](https://dev.to/uianimation/want-duolingo-style-interactive-animation-in-your-app-stop-using-lottie-heres-how-with-rive-5247),
[a mascot that does something](https://dev.to/mascotengine/your-saas-mascot-should-do-more-than-just-sit-there-38oe)).

## Why the daruma as drawn today is not that

It is a logo with poses: a fixed outline, a ring and a dashed ring for eyes, a glance of three
units. Nothing in it morphs, its eyes have no expression beyond filling, and it has no idle life.
The brand meaning is worth keeping — the painted eye is the record button, and painting the
second eye is "done" — but the drawing has to become a character to carry it.

## The direction (prototype: two versions, scratchpad, shown to the owner)

1. **One parametric body.** The brand kit's egg, generated from width, height and crown roundness,
   so every state is the same curve with other numbers and springs carry it between them.
2. **Pill eyes are the personality.** Blink at random intervals; follow the pointer on a spring;
   widen when the pointer comes near (curious), narrow while recording (focused), half-close when
   paused, arc when done, droop on an error. **While recording the right eye is a glowing red
   disc** — the painted eye, kept.
3. **A glow per state:** red breathing while recording, gold paused and done, blue when it needs
   the person, red with a sink and a shake on an error.
4. **Behaviours:** tucked in the notch's wing while idle and while recording; emerges below the
   notch and springs into place for the countdown, for "needs a permission", for done and for an
   error; the notch expands into the take's last steps on hover (built: `LiveSteps`); optionally
   a cursor companion during the countdown.
5. **Bodies to choose between:** vermilion or sumi (both the brand kit's); a round "mochi" and a
   face-only glass orb were drawn too, and are further from the daruma.

Reduce Motion: the eyes move without travelling, the glow does not breathe, no hop, no shake.

## Open

The body, and whether the character replaces the menu bar's template mark (it would need a
template-ink version at 18 points) or lives only in the notch, the countdown, the permissions page
and the empty editor.

## Built (2026-10-26)

The owner chose the face window, then asked for both faces as a choice, vermilion by default and
every colour designed; for the face window to turn with the gaze; and for the eyes to stand apart.

- **One figure, in Core.** `DarumaBodyCurve` (Geometry) is the body's four curves, the one
  statement of the shape; `DarumaFigure` (Render) is the geometry one face draws — the face window
  on the body's sphere, the eyes on the face's — pure, and tested in Core where it runs without the
  app: the face stays on the body and the eyes in the face at ten gazes, wide-eyed; looking aside
  moves and narrows the whole face (red with the face held still); the eyes stand at least an
  eye-width apart and a smile's arcs do not meet (red at the first spacing, 0.28, which the owner
  saw touching); up is shorter than down, because the crown narrows and the face left the body at
  up-and-aside until it was.
- **The app draws it** (`DarumaView`): flat colour with one highlight, the face window or eyes on the
  body, the record eye red with a washi ring where there is no white window behind it; the template
  as one even-odd path. **`LivingDaruma`** blinks on a hashed schedule (the app reads no randomness),
  breathes, and looks at the pointer in the notch, the countdown, the permissions page and the
  empty editor; its clock is `Minting`'s — a first version read `timeIntervalSinceReferenceDate`
  and the ambient-value scan stopped it.
- **The menu bar's mark is drawn** from the same figure (`DarumaMark`), template while nothing
  records, the record eye red while it does, a red ring counting down — tested in its pixels (red
  with the record eye taken out). The baked images and `make-daruma-marks.swift` are gone.
- **Settings → Character** chooses the colour — vermilion, ink, paper, gold, or the appearance's
  ink — and the face. Each colour is designed for both faces: on the body, sumi eyes on vermilion,
  gold and paper, paper eyes on ink.
- **The brand kit** in `assets/` and the app's icon are drawn by `scripts/make-character-assets.sh`
  from the figure, through a Core generator that runs only when asked.

## The app icon, after Grok Bot's (2026-10-26)

The owner asked for the icon to follow Grok Bot's, and for the eyes-on-the-body face to be an icon a
person can choose. A first pass read the reference from its small avatars — a flat character
filling a tile — and the owner corrected it with the real icon: **the body too big for the tile,
coming in from the lower left and cut by its edge, turned toward the upper right where its tilted
pill eyes look, shaded as a lit ball, the dark ground showing only in the corner it leaves.**

So, built that way (`appIcon` in the generator): the daruma at 11.5× in Apple's 824 macOS tile,
turned 28°, looking up and right; a radial shade lit from the upper left and a faint rim; the
ground sumi, or washi for the ink daruma, whose dark body is lost on sumi. Icon Composer's layers
take the same placement scaled to its full canvas, flat, for the system to light.

- **Every icon keeps the record eye**, a red disc. A pass drew it as a red pill to match the other
  eye, and the eyes-on-body icon as two ink pills, the reference's face; the owner kept the
  composition and asked for the record eye back — it is what the app is, and the daruma's first
  painted eye.
- **Face window** (the bundle's): an ink pill and the record eye.
- **Eyes on the body**: the record eye in the app's washi ring, or red is lost on vermilion. Shown
  beside no ring, a thin washi ring and an ink ring, the owner kept this one.
- **Ink**: the face window's, on washi.

`AppIconChoice` is those three; Settings shows each as a thumbnail beside the picker, labelled with
the face picker's own words.

## The countdown's ring finishes (2026-10-27)

The owner saw the ring round the record eye stop short in the last fraction of a second. Two
causes, both measured in the code rather than guessed: the ring was set a tenth at a time to the
tenth's **start** (1.0 … 0.1), so it never reached empty before the panel went; and the face's
spring (`LivingDaruma`, 0.32 s) eased it, so it trailed the time besides. Now the panel reads the
ring from the clock each frame — what is left of the second that began at `secondBegan` — the ring
is no longer in `DarumaView`'s animatable data, and the panel holds one frame (50 ms) of the closed
ring before it goes. The menu bar keeps its tenths: at 18 points a tenth is not visible. Tested
in `CountdownRingTests`, each test red under its own mutation (the tenths' ring, no finish, the
ring eased with the face).
