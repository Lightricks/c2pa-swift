# Updating Lightricks' C2PA package

[`upgrade.py`](upgrade.py) rebuilds the C2PA package of an upstream c2pa-swift tag for iOS, with a
trimmed c2pa-rs library, so that the fork can publish it as a Lightricks release.

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

3. Commit both in a pull request.

`upgrade.py drift` lists the updates available on top of the lockfile (`cargo update --dry-run`).
It doesn't affect the build.

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
  that the ZIP depends only on its contents. `build` prints its checksum.

The generated `Package.swift` declares only `.iOS(.v16)`, since the XCFramework has no macOS or
Mac Catalyst slices.

`upgrade.py release` writes the same manifest with the URL of the ZIP in a release of the fork.

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
   permits the timestamp authority, thumbnails made by the caller, and parent ingredients from
   archives written by the previous release (v0.0.16). For images, that is a
   context that allows only `timestamp.digicert.com` with an explicit timestamp request timeout, no
   custom HTTP resolver, the async signer with DigiCert's TSA, and a 1024 px ImageIO thumbnail
   (JPEG, or PNG if the image has alpha). The 1600×1200 images are generated at runtime. For JPEG,
   PNG, transparent PNG, HEIC and TIFF, the tests require a validated and trusted DigiCert
   timestamp, decode the signed image with ImageIO, check the thumbnail, and check that the JPEG
   manifest spans several APP11 segments. They also add parent ingredients from archives written
   with c2pa-swift v0.0.16 and check the ingredients' own validation results, and check that signing
   fails without connecting when the TSA host isn't allowed.

The test signing key is the upstream public ES256 fixture. Timestamps are verified against the
self-signed DigiCert Trusted Root G4 in the test bundle. No production signing credentials are
needed.
