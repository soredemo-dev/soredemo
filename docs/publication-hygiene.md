# Publication hygiene

## Alpha.0 release status

Soredemo `0.1.0-alpha.0` is **RELEASED WITH DOCUMENTED DEVIATIONS**.

The first npm publication necessarily retained both tags:

```text
alpha  -> 0.1.0-alpha.0
latest -> 0.1.0-alpha.0
```

The authenticated attempt to remove `latest` returned `E400`. npm registry package
metadata requires a `latest` tag, so no fake stable placeholder was published.
Installation documentation continues to recommend `soredemo@alpha`.

The approved downloadable tarball contained no private paths. The full npm packument,
however, included `_from` and `_resolved` fields derived from the local publication
source. They disclosed a local source location, but no credential, application data,
capture, diagnostic workspace, or private source file was included in the package.
Public documentation intentionally does not reproduce the original private path.

## Future publication rule

Future publication is staged in a disposable neutral root whose path contains no user
or repository identity. Release checks capture the real npm publication request with a
loopback mock registry and reject outbound metadata containing:

- macOS or Linux home-directory components;
- Windows user-profile components;
- the original repository path;
- percent-encoded or JSON-escaped variants;
- secrets, application data, capture paths, or diagnostic paths.

The request-capture gate compares absolute and relative tarball publication, prepared
package-directory publication, and neutral staging. It never contacts or mutates the
public registry.

The selected workflow is:

1. build and inspect the candidate;
2. copy the prepared package to a disposable neutral staging root;
3. capture a loopback publication request;
4. reject private source metadata;
5. publish from the reviewed neutral package directory only after a separate release
   approval.

The public alpha.0 registry metadata is immutable and is not rewritten.
