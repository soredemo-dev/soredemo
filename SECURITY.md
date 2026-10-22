# Security

**Report a vulnerability privately**, through GitHub's *Report a vulnerability* button on this
repository's Security tab — not in a public issue. A fix ships before the report is made public.

## What counts

Soredemo records screens. What goes wrong in a recorder is usually about what it records or what
it opens, so these are in scope:

- **A shared `.soredemo` package doing something it should not.** A package is a document people
  send each other and every byte in it is treated as hostile: a name escaping its folder, a link to
  elsewhere, a file large enough to exhaust memory, a value that crashes a decoder.
- **Something reaching a recording that was meant to stay out of it** — ordinary typing (only
  approved shortcuts are ever recorded), this app's own windows, anything a "hide" switch promised
  to leave out.
- **Anything leaving the Mac.** Soredemo sends nothing anywhere except one optional request to
  GitHub's public releases API to ask whether a newer version exists. Anything else is a bug.
- **A permission used for more than its stated purpose** — Screen Recording, Accessibility, Input
  Monitoring, Microphone, Camera.

## What it is not

Soredemo is not sandboxed, deliberately: following the accessibility element under a click needs
it. That is why every name read from a package is validated rather than trusted — see
`docs/design/2026-10-22-audit-and-how-to-stand-out.md` for the audit, what it found and what is
still open.

## Supported versions

The latest release only. Fixes are not backported.
