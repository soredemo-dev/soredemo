# Toolchain setup

*Current as of 2 August 2026. Two separate things — Xcode gives you the SDK, macOS gives you somewhere
to run the result.*

---

## Target state

| | Version | Notes |
| --- | --- | --- |
| Xcode | **27 beta 4** (`27A5228h`, 20 July 2026) | Swift 6.4, macOS 27 SDK. Requires macOS 26.4+ on Apple Silicon |
| macOS for building | 26.5 or later | Xcode 27 beta runs fine here |
| macOS for running | 26.5 or later | The floor is `.macOS(.v26)` (ARCHITECTURE.md D2), so the build machine runs the result. A macOS 27 volume is **not required** — see § 2 |
| Swift | 6.4 | Strict concurrency, no exceptions |

**Phase 0 needs none of this.** It builds the old Rust/Tauri app and a Swift recorder, both of which target
older systems. Do not block Phase 0 on beta setup — run them in parallel.

---

## 1. Xcode 27 beta, alongside Xcode 26

Xcode 27 beta 4 requires macOS 26.4 or later on Apple Silicon, so it installs on a current system
without upgrading the OS.

1. Download from [developer.apple.com/download/applications](https://developer.apple.com/download/applications/)
   — free Apple Developer account is enough. `Xcode_27_beta_4.xip`, roughly 10–15 GB.
2. Unarchive, **rename the result to `Xcode-beta.app`**, and move it to `/Applications`. Renaming is
   what lets Xcode 26 and 27 coexist.
3. Point the command-line tools at it:

```bash
sudo xcode-select -s /Applications/Xcode-beta.app
xcodebuild -version
xcodebuild -showsdks | grep macos      # expect macosx27.0
swift --version                        # expect 6.4
```

Switch back at any time:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

**Keep Xcode 26 installed.** Xcode 26 does not run on macOS 27, so once the main volume moves to 27
you lose that environment. Keeping both apps on a 26.x system is the cheapest insurance.

---

## 2. macOS 27 beta on a separate APFS volume — **not required**

> **Not required at the current floor.** The deployment target is `.macOS(.v26)` (ARCHITECTURE.md
> D2), so everything Phase 1 builds launches on the 26.x build machine — verified: `otool -l` on
> `Soredemo.app/Contents/MacOS/Soredemo` reports `minos 26.0 / sdk 27.0`, and the app launches to a
> window here. **Xcode 27 beta stays** — it is the SDK, and § 1 is still required.
>
> **The section is kept, not deleted, for two reasons.** First, the floor is a decision and not a
> fact of nature: `FEATURES.md` names Music Understanding, generated subtitles, the Evaluations
> framework and `WritableDocument` as macOS 27 APIs, and Phase 4 or Phase 5 wanting one of them
> means raising the floor, at which point this is the procedure and the "at Select Destination,
> choose the new volume" step is the one that costs you a working system if it is skimmed. Second,
> running the app on the *next* OS before it ships is a thing you want to be able to do cheaply,
> independent of what the manifest targets.

**Do not upgrade the main system.** One machine, solo, full-time: a bad beta on the working volume is
a project-level risk, not an inconvenience. macOS 27 beta 1 notes list known issues across window
management, fullscreen apps, and Apple Intelligence.

A separate APFS volume shares the same physical disk with no repartitioning, and you reboot between
systems.

1. **Time Machine backup first.**
2. Disk Utility → select the internal drive's **APFS container** → `+` → name it (e.g. `macOS 27
   Beta`) → format APFS.
3. Enrol: System Settings → General → Software Update → **Beta Updates** → macOS 27 Developer Beta.
   (Or download the restore image from
   [developer.apple.com/download/os](https://developer.apple.com/download/os/).)
4. Run the installer. **At "Select Destination", choose the new volume** — this is the step where a
   mistake costs you the working system.
5. Switch systems: shut down, **hold the power button** until Startup Options appears, pick a volume.

Apple Silicon only. If a VM install fails, Apple ships *Device Support for macOS 27.0 beta*
(`2050A4a`) for exactly that case.

---

## 3. Verify before starting Phase 1

```bash
xcode-select -p                        # /Applications/Xcode-beta.app/Contents/Developer
xcodebuild -showsdks | grep macos      # macosx27.0 present
swift --version                        # 6.4
sw_vers                                # 26.x is enough — the floor is macOS 26, see § 2
```

---

## 4. Beta hygiene

- **When something is strange, suspect the beta before suspecting your code.** Reproduce on 26.5 if
  the code is not yet 27-only.
- Record the exact build in bug notes — `27A5228h`, `26A5388g`. "Xcode 27 beta" is not a version.
- File Feedback Assistant reports for framework bugs. This project depends on ScreenCaptureKit,
  Speech, and the new Document API; bugs found now can still be fixed before September.
- Betas ship every 2–4 weeks. Update deliberately, not reflexively — and never mid-task.

---

## 5. Also install

| Tool | Why |
| --- | --- |
| **a skill chain** | `/plugin install a skill chain@claude-plugins-official` — user scope. The working method in `AGENTS.md` |
| **Icon Composer** | Layered Liquid Glass app icon from `../soredemo-web/soredemo-brand-kit/` |
| **SF Symbols 8** | 7,000+ symbols, aligns with the system font |
| **Rust toolchain** | Phase 0 only, to build the old Tauri app |
