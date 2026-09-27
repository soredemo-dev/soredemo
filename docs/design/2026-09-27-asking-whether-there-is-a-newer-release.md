# Asking whether there is a newer release

2026-09-27. The first thing this app sends over a network, so it is designed around what it
sends rather than around convenience.

## Decision

**A question to GitHub, not an updater.** "Check for Updates…" asks
`api.github.com/repos/soredemo-dev/soredemo/releases/latest` for the newest release, compares its
tag with this build's version, and — if it is newer — offers to open the release page. Installing
is the person's act, in their browser, like the first download was.

Rejected:

- **Sparkle.** A third-party framework in the app, an EdDSA key to keep, an appcast to host, and an
  installer that replaces the app. Every one of those is a thing to trust; the problem is "tell me
  when there is a new version", which one request answers.
- **A daily background check.** "Once a day" needs the time, and the app target reads no ambient
  values at all (`noAppSourceReadsAnAmbientValueAtAll`). The automatic check runs at launch
  instead, and only when a person turned it on.

## What leaves the Mac

One HTTPS GET with no body. GitHub sees the address it came from and a user agent. Nothing about
the person or any recording. The manual check runs only when chosen from the menu; the automatic
one is **off by default** (Settings → Privacy says what it sends, where the switch is).

`noOtherAppSourceTalksToANetwork` holds the claim: `UpdateCheck.swift` is the only app file that
names `URLSession`. "Nothing leaves this Mac" in the privacy pane becomes "nothing leaves this Mac
unless you ask it to check for updates", which is the true sentence.

## Untrusted input

The response is written by whoever controls the release, and flows into a URL this app opens. So
the page is opened only if it is `https://github.com/soredemo-dev/soredemo/releases/…`; anything
else is reported as unreadable rather than followed. The tag is compared, never displayed raw
beyond the version it parses to.

A repository with no release yet answers 404; that is its own verdict ("no release has been
published"), not an error.
