# Updating Lightricks' C2PA package

The [upgrade workflow](../../.github/workflows/lightricks-upgrade.yml) accepts an upstream
c2pa-swift tag and a tag for the matching Lightricks release. Changes to the workflow, rebuild
scripts, or test project also run the current candidate in pull requests. The baseline,
`CURRENT_SWIFT_TAG`, is the upstream Swift tag of the release in use.

## Inputs

[`upstream.json`](upstream.json) pins every upstream tag the scripts use: the c2pa-swift and
c2pa-rs commits, and the SHA-256 of upstream's C2PAC ZIP. `prepare` fails if a tag isn't pinned,
if the tag moved, or if the ZIP or its checksum in `Package.swift` differ from the pin. The ZIP
only supplies `c2pa.h`; the library is rebuilt from c2pa-rs.

[`locks/`](locks) holds the Cargo lockfile of each c2pa-rs tag, and `build` uses it with
`--locked`. To upgrade:

1. Pin the new c2pa-swift tag and the c2pa-rs tag from its `Configurations/Base.xcconfig` in
   `upstream.json`. Take the commits from `git ls-remote` (the peeled `^{}` entries for annotated
   tags) and the checksum from the tag's `Package.swift`, and check the ZIP's checksum.
2. Write the new lockfile, starting from the previous one so that only the c2pa crates and what
   they require change:

   ```sh
   python3 Scripts/upgrade/upgrade.py prepare <swift tag> /tmp/c2pa/candidate
   python3 Scripts/upgrade/upgrade.py lock /tmp/c2pa/candidate \
     --seed Scripts/upgrade/locks/<previous c2pa-rs tag>.Cargo.lock
   ```

3. Commit both in a pull request, which runs the verification below.

The workflow also lists the updates available on top of the lockfile (`cargo update --dry-run`)
in `dependency-drift.txt`. The report doesn't affect the build or the job result.

## Build

The report compares the upstream C API header, both changelogs, the timestamp and HTTP
implementation, and the Swift signing and context APIs. The build:

- Compiles `c2pa-c-ffi` with only `rust_native_crypto`, `file_io` and `c2pa/http_ureq`, and
  removes `pdf` from its `c2pa` features. `ureq` is the only HTTP client; the build fails if
  `hyper`, `image`, `lopdf`, `openssl`, `openssl-sys` or `reqwest` is in the dependency graph of a
  slice, or if `ureq` isn't. tokio remains in `c2pa-c-ffi`'s graph on non-wasm targets, but the C
  API doesn't reach it, so it is dead-stripped from apps. A `cargo tree` failure fails the build.
- Uses `opt-level=z`, fat LTO, a single codegen unit and `panic=abort`, with
  `cargo rustc --crate-type staticlib` so that LTO applies to the static library.
- Builds `aarch64-apple-ios` for devices, and `aarch64-apple-ios-sim` and `x86_64-apple-ios`,
  combined with `lipo`, for simulators on Apple silicon and Intel Macs. iPad apps that run on Mac
  as "Designed for iPad" use the device slice.
- Checks every slice: each function declared in `c2pa.h` must be exported, the number of Rust
  exports shows whether LTO ran, and the library must not contain `/Users/`, `/home/runner`, the
  work directory or the home directory. `--remap-path-prefix` replaces the Cargo registry and
  git checkouts, the Rust toolchain and the c2pa-rs checkout with fixed paths, and
  `-ffile-prefix-map` does the same for C code built by build scripts.
- Packages the slices as an XCFramework of static libraries, each with `c2pa.h` and a
  `module C2PAC` module map, instead of upstream's `C2PAC.framework` bundles. Xcode embeds a
  package's frameworks in the app and replaces a static framework's binary with a stub, which App
  Store Connect rejects when the bundle's `MinimumOSVersion` differs from the app's; libraries are
  only linked. Swift imports `C2PAC` the same way with both.
- Sorts the libraries in the XCFramework's `Info.plist`, which `xcodebuild` lists in a random
  order, and zips the XCFramework with sorted entries, fixed timestamps and fixed permissions, so
  that the ZIP depends only on its contents. Its checksum is in the job summary.

The generated `Package.swift` declares only `.iOS(.v16)`, since the XCFramework has no macOS or
Mac Catalyst slices.

## Verification

[`verify.sh`](verify.sh) stages the [test project](../../UpgradeVerification/Package.swift), which
imports the rebuilt package as a normal SwiftPM consumer. It then:

1. Builds the [DeviceLinkCheck](../../UpgradeVerification/DeviceLinkCheck) app in Release for iOS
   devices and for arm64 and x86_64 simulators. Building a package library only compiles it;
   linking an app resolves every symbol the static library needs, so a missing symbol or system
   library fails the job. The script then checks the architectures, platform and C2PA symbols of
   the linked apps.
2. Runs the tests on an iPhone simulator of the newest installed iOS runtime, unless a destination
   is given. The tests describe the supported usage profile of this build (see `SigningProfile`):
   signing exports with a live RFC 3161 timestamp from DigiCert, a network allowlist that only
   permits the timestamp authority, thumbnails made by the caller, parent ingredients from archives
   written by the previous release (v0.0.16), and low-memory video signing. For images, that is a
   context that allows only `timestamp.digicert.com` with an explicit timestamp request timeout, no
   custom HTTP resolver, the async signer with DigiCert's TSA, and a 1024 px ImageIO thumbnail
   (JPEG, or PNG if the image has alpha). The 1600×1200 images are generated at runtime. For JPEG,
   PNG, transparent PNG, HEIC and TIFF, the tests require a validated and trusted DigiCert
   timestamp, decode the signed image with ImageIO, check the thumbnail, and check that the JPEG
   manifest spans several APP11 segments. They also add parent ingredients from archives written
   with c2pa-swift v0.0.16 and check the ingredients' own validation results, and check that signing
   fails without connecting when the TSA host isn't allowed.

   `VideoSigningTests` covers the recommended way to sign large videos with this build,
   `SigningProfile.sign(videoAt:)`: the image setup with a thumbnail from AVAssetImageGenerator,
   plus two settings that keep memory flat at any video size:

   - Read the source and write the destination through `FileStream`s, which use POSIX calls.
     `Stream(readFrom:)` returns autoreleased `Data` per read, which a dispatch queue frees only
     when signing ends.
   - Set `backing_store_memory_threshold_in_mb` to 1 in the context, since c2pa-rs otherwise
     copies videos up to 512 MB into memory.

   Without either, signing a 1.1 GB video added over 1 GB of memory; with both, about 34 MB at
   37 MB, 371 MB and 1.1 GB.

   The videos are written at runtime with AVAssetWriter, as video exports typically are: a QuickTime
   H.264 movie with AAC audio, a 10-bit HLG HEVC movie, an MP4, and a movie whose parent is the
   archive of a signed movie. The tests require a BMFF hash, a trusted timestamp and the parent's
   valid manifest, check that AVFoundation decodes every frame of the signed file with the source's
   duration and tracks, and that changing a media byte fails validation. A 320 MB video, a repeated
   clip exported without re-encoding, must sign and read back on a dispatch queue with peak memory
   rising by less than 100 MB. The signing bound catches both settings regressing. The read bound
   doesn't catch reading through `Stream(readFrom:)`, since that only grows with the file above
   512 MB. A 4K performance measurement runs only locally, with `TEST_RUNNER_C2PA_VIDEO_PERF=1`.

   `PublicAPITests` covers common uses beyond that profile, offline and without timestamps:
   reading a c2pa-rs manifest chain from a file and from memory, with its JSON, detailed JSON and
   thumbnails; the digital source type of an AI-generated parent ingredient; ingredients from
   streams, resources and Builder archives; a sidecar manifest with a remote URL; Rust signers for
   ES256, ES384, PS256 and Ed25519, and a callback signer; trust anchors from JSON and TOML
   settings; and signing WebP and AVIF. Two tests document the trim and fail if PDF support or
   Rust thumbnail generation comes back.

The workflow then runs upstream's Library tests with [`upstream-tests.sh`](upstream-tests.sh):
it builds the Library project from the candidate's c2pa-swift checkout, with the C2PAC framework
made from the rebuilt simulator libraries. Tests of the removed features (PDF, Rust thumbnails,
the async HTTP stack) are skipped with the script's exclusion list; upstream v0.1.0 has no such
tests, so the list is empty. Tests that need a signing server or the Secure Enclave skip
themselves on the runner.

The test signing key is the upstream public ES256 fixture. Timestamps are verified against the
self-signed DigiCert Trusted Root G4 in the test bundle. No production signing credentials are
needed. CI uses Xcode 26.6, the newest Xcode on GitHub's runners.

If the candidate verification fails, CI repeats it against the baseline on the same runner. The
job remains failed regardless of the baseline outcome; the baseline only shows whether the
candidate or the runner, such as its connectivity to DigiCert, is at fault, so it doesn't run when
the candidate passes. If both fail, check the test results and connectivity to DigiCert before
retrying.

## Release

Pull request runs build and test only, and run the release check on upstream's v0.1.0 release
without its SwiftPM consumer, to exercise the script. A manual run on `main` needs a new release
tag, `<swift tag>-lightricks.<n>`, and fails before building if the tag has another form or
exists in this repository already. Once verification passes, the `release` job checks that
`Library/Sources` in the commit the workflow runs on matches the tested c2pa-swift tag, attests the
ZIP's build provenance, and uploads the `verified-c2pa-release` artifact: the ZIP, its checksum,
the Rust lockfile, the upstream revisions and the fork commit, and the SwiftPM manifest with the
fork's release URL. Only that job can write attestations, and publishing is manual:

1. On `main`, commit the generated `Package.swift` on top of the commit that the workflow ran on,
   push it, and tag it, for example `v0.1.0-lightricks.1`.
2. Create the GitHub release for the tag and attach `C2PAC.xcframework.zip` and
   `C2PAC.xcframework.checksum` from the artifact.
3. The [release check](../../.github/workflows/lightricks-release-check.yml) runs when the release
   is published, and can be run manually with the tag. It runs
   [`check-release.sh`](check-release.sh), which checks that the tag is on `main`, compares the
   published ZIP's checksum with `Package.swift` and the checksum asset, and checks with
   `gh attestation verify` that the upgrade workflow on `main` built the ZIP from an ancestor of the
   tag with the same `Library/Sources`. It then checks that the manifest declares only iOS,
   resolves the package by URL and exact version in a clean SwiftPM consumer, and builds the
   consumer for iOS devices. Run it locally with `Scripts/upgrade/check-release.sh <tag>`, signed
   in to `gh`.
4. Once the release is in use, update `CURRENT_SWIFT_TAG` in the workflow.

### Versions

Releases are named `<upstream version>-lightricks.<n>`. In SemVer, a pre-release sorts below its
release: `0.1.0-lightricks.1` < `0.1.0`. A range such as `from: "0.1.0-lightricks.1"` would
therefore resolve to upstream's `0.1.0` if it were ever published in this repository, and
`0.1.0-lightricks.2` sorts above `0.1.0-lightricks.1` but below `0.1.0`. Consumers must pin the
release with `exact:` (Xcode's "Exact Version").
