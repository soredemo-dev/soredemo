# Public-alpha release candidate

The first candidate is `soredemo@0.1.0-alpha.0`. It is a CLI-only product contract: no general-purpose JavaScript API is promised. The verified environment is macOS arm64, Node.js 20.19.4, Playwright 1.61.1 with Chromium revision 1228, Canvas 1.0.2, and system FFmpeg/FFprobe 8.0 with libx264.

`pnpm release:check` runs non-mutating source, schema, documentation, visual-authority, package, and installed-package checks. `pnpm release:pack` creates an ignored candidate tarball, checksums, file inventory, npm dry-run data, and a release manifest. Neither command publishes, tags, pushes, or creates a GitHub Release.

The npm name checkpoint is read-only. The candidate is installed from its tarball into an isolated project, including a parent path containing spaces. Installation has no Soredemo network or media side effect. Chromium installation is a separate explicit onboarding step.

The support boundary and known limitations are summarized in the README and CHANGELOG. This candidate is for review; it is not a stable release.
