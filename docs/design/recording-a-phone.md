# Recording a phone

*Measured on an iPad over USB, macOS 26, 2026-08-27. Code:
`Core/Sources/Capture/MobileScreen.swift`.*

An iPhone or iPad on the end of a cable, as something this app can record. There
was no prior art to read, so this is built from what macOS actually offers and
every rule below was run rather than reasoned about.

## The one mechanism, and it is a switch rather than an API

A connected iOS device is invisible to AVFoundation until a process sets
`kCMIOHardwarePropertyAllowScreenCaptureDevices`. That is what QuickTime's "Movie
Recording → iPhone" turns on. Once it is on, the device appears as an ordinary
`AVCaptureDevice` of type `.external` carrying the phone's screen as video and its
audio as a separate device.

`CMIOObjectSetPropertyData` returns 0, and with nothing connected the
external-device list is empty rather than erroring.

## Recording one costs nothing new

An iOS screen is an `AVCaptureDevice`, and `CameraRecorder` already writes one to
a movie file with `AVCaptureMovieFileOutput`. So a phone recording is
`CameraRecorder.start(camera: .device(uniqueID:name:))` with this id — no second
capture path, no second writer, no second set of failure modes.

**What a phone recording does not get, said here rather than discovered.** There
is no cursor to draw, no accessibility tree to read, and no clicks to zoom to, so
the automatic framing this app is built around has nothing to work from.
Everything else works: the look, the background, cutting, speed, captions, export,
manual zoom. A person expecting the automatic zoom they get on a Mac recording
will not get it, and that is a property of there being no observations to derive
it from rather than a feature that was skipped.

## Notification, not a discovery session

With an iPad connected over USB and unlocked:

```
CONNECTED  <name>  model=iOS Device  type=AVCaptureDeviceTypeExternal
DiscoverySession(external, .video) -> 0
```

The device announces itself and the discovery session does not list it —
repeatedly, over twenty-five seconds, in the same process. An implementation built
on enumeration alone finds nothing however long it waits, which is what the first
version did.

**And the run loop has to be running.** CoreMediaIO discovers these on the main
run loop; a probe that threw the switch and then slept saw nothing for six
seconds, and the same code pumping `RunLoop.main` saw the device at once. In the
app this is free — AppKit runs the loop — but it is why a command-line check of
this feature reports nothing.

## Identifying one: `modelID` first, the snapshot second

`AVCaptureDevice.modelID` reads `iOS Device` for a screen-capture device. That
string had been written into an earlier version as "widely said and therefore not
used" — a branch nobody has run is a claim rather than a mechanism. It has now
been run, and using it removes a limitation the previous rule carried whole: it no
longer matters whether some other application threw the switch before this app
launched.

The snapshot rule — "it was not visible until this process allowed screen-capture
devices" — stays as a fallback. It is right whenever it applies and silently wrong
if another application threw the switch first, and it costs nothing to keep
against a future macOS that stops reporting the model string.

The predicate is separated from the device so it can be tested without a phone on
the end of a cable: `AVCaptureDevice` cannot be constructed, so a predicate taking
one could only ever be exercised against whatever happened to be plugged in.

## The empty list has a knowable cause

Measured with an iPad plugged in and **locked**: `ioreg` shows
`iPad@00100000 <class IOUSBHostDevice>`, vendor "Apple Inc.", but the device
exposes only PTP, Apple's USB multiplexor, and two NCM interfaces. The
screen-capture interface is simply absent, so the device list is correctly empty
and a person sees nothing at all — with a cable in their hand.

The screen interface appears once the device is unlocked. Trust is asked once and
remembered, so somebody who has plugged this iPad in before will never see that
prompt again and has no way to guess. It does **not** need Developer Mode; that is
for running your own builds from Xcode and has nothing to do with this — measured,
because it is the first thing anybody searches for.

**Names, not a count.** "Unlock iPad" is a sentence somebody can act on; "1 device
unavailable" is not.

### Counted, not name-matched, and a real iPad is why

The first version compared the USB product string against the capture device's
`localizedName` and asked whether one contained the other. Measured with an iPad
attached and working:

```
available=["<the iPad's own name>"]   waiting=["iPad"]
```

USB reports the family — "iPad" — and AVFoundation reports what the person called
their device, which here shared not one character with it. So a device recording
perfectly well was also reported as needing to be unlocked, and the menu would
have shown a working card beside "unlock it".

There is no reliable mapping between the two names, and inventing one would be
guessing at what somebody names their iPad. Counting needs no mapping: if three
Apple mobile devices are on the bus and two are offering screens, one is waiting.
Dropping from the front is arbitrary and has to be — without a name mapping there
is no way to say *which* of three iPads is locked, only how many are.

## The device's own name, whatever it looks like

AVFoundation reported this iPad's name as `[226, 150, 161, 226, 150, 161]` — two
U+25A1 WHITE SQUARE characters and nothing else. That was taken for a placeholder
and replaced with a generic label. It is not a placeholder: the device's owner
confirmed it is the name they chose.

So the rule is the producer-value rule, which this project states plainly and
which the first version broke: an authored value wins over a derived one and is
never silently replaced. Somebody who names their iPad in boxes, in Chinese, in
emoji or in nothing legible at all has named it, and a recorder that decides their
name carries no information is deciding something that is not its to decide.

The only fallback left is for a name with no characters in it at all. A card has
to say something, and that is the one case where there is nothing to say.

## No touch data, and why the automatic zoom was taken out

*Moved here from the retired competitor survey, 2026-10-25.*

**There is no touch data, for anyone.** iOS does not send touch coordinates over the CoreMediaIO
screen-capture interface, and nothing on the Mac can obtain them; a connected iPad exposes PTP,
Apple's USB multiplexor and two network-over-USB interfaces, and the capture device carries video
and audio only. Screen Studio's own guide says automatic zoom is not supported on iOS recordings
for the same reason.

**A zoom from what changes on screen was built, measured and removed on 2026-08-29.** It rested on
"change means intent", which is false on a phone. Three detections on a real iPad recording, three
wrong: a home-screen widget animating by itself, a banner mid-transition, empty space while a
sidebar slid in. Wrong structurally, not by a margin: navigation animates the whole screen and is
always a larger change than the tap; the interface animates on its own; and the tap comes before
the change, so by the time the change peaks the finger is elsewhere. A peak-relative threshold, a
fixed target, rejecting frame-wide changes and framing from the clearest burst each improved a
method that cannot work.

A wrong zoom costs somebody a deletion; a missing one costs nothing. **What works instead** is a
Bluetooth mouse paired to the device: a real cursor appears in the recording, and everything that
follows a cursor has something to follow — which the menu bar panel says before the take.
