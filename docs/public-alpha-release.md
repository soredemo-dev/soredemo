# Public-alpha release candidate

## Alpha.0 status

Day 14 is classified **RELEASED WITH DOCUMENTED DEVIATIONS**. Because alpha.0 was npm's first
publication, both `alpha` and `latest` point to `0.1.0-alpha.0`; npm rejected removing the only
`latest`. Documentation continues to recommend `soredemo@alpha`.

The full npm packument also retained source-location metadata from publication input. The
downloadable tarball contained no private path, credential, application data, capture, or
diagnostic workspace. Future releases use the tested neutral staging workflow in
[publication hygiene](publication-hygiene.md).

The first candidate is `soredemo@0.1.0-alpha.0`. It is a CLI-only product contract: no general-purpose JavaScript API is promised. The verified environment is macOS arm64, Node.js 20.19.4, Playwright 1.61.1 with Chromium revision 1228, Canvas 1.0.2, and system FFmpeg/FFprobe 8.0 with libx264.

`pnpm release:check` runs non-mutating source, schema, documentation, visual-authority, package, and installed-package checks. `pnpm release:pack` creates an ignored candidate tarball, checksums, file inventory, npm dry-run data, and a release manifest. Neither command publishes, tags, pushes, or creates a GitHub Release.

The npm name checkpoint is read-only. The candidate is installed from its tarball into an isolated project, including a parent path containing spaces. Installation has no Soredemo network or media side effect. Chromium installation is a separate explicit onboarding step.

The support boundary and known limitations are summarized in the README and CHANGELOG. This candidate is for review; it is not a stable release.

Day-14 publication is deliberately split. Phase A may prepare documentation, render the repository-owned launch showcase, run all release gates, build the reviewed tarball, and push source commits. It must stop before public mutation. Phase B may publish the exact reviewed tarball under the `alpha` dist-tag, push the annotated tag, and create the GitHub prerelease only after the exact approval phrase `APPROVE PUBLISH 0.1.0-alpha.0` is received in the active session.

The public launch video uses only the synthetic Northstar application under `examples/launch-showcase`. The generated MP4, poster, checksums, and manifests remain ignored release artifacts; captures and diagnostic workspaces are never attached to a public release.
