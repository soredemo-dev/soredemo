---
name: Bug report
about: Something did not do what it should
labels: bug
---

**What you did**

**What happened**

**What you expected**

**Which build** — paste the first lines this prints (build time, commit, macOS, and which
permissions the app holds). A report against a build three commits old describes a different
program.

    /Applications/Soredemo.app/Contents/MacOS/Soredemo --dump-permissions

**Your Mac** — macOS version and build (`sw_vers`), Apple chip, and how many displays were attached.

**If it crashed** — attach the report from `~/Library/Logs/DiagnosticReports/Soredemo-*.ips`.
Running from Xcode, no report is written: type `bt all` at the `(lldb)` prompt and paste what it
prints.

**Was a call, a second display, or headphones involved?** Each changes how audio and capture
behave, and saying so saves a round of questions.
