#!/bin/bash
# Run upstream's Library tests (TestShared) against the rebuilt library on a simulator.
#
# Usage: upstream-tests.sh <work directory> <result bundle> [destination]
# Run after `upgrade.py build`. The tests build upstream's Library project from the candidate's
# c2pa-swift checkout, with the C2PAC framework made from the rebuilt simulator libraries instead
# of upstream's c2pa-rs release. Without a destination, they run on an available iPhone simulator
# of the newest iOS runtime.
set -euo pipefail

scripts="$(cd "$(dirname "$0")" && pwd)"
work="$(cd "$1" && pwd)"
result="$2"
destination="${3:-$("$scripts/simulator-destination.sh")}"

# Tests of features that the build removes on purpose: PDF, Rust thumbnail generation and the
# async HTTP stack. Add `-skip-testing:C2PATests/<class>/<test>` entries here with a reason.
# Upstream v0.1.0 has no tests that depend on these features, so the list is empty.
excluded=()

# The Library project's framework build phase takes one c2pa-*-<target>.zip per target from
# C2PA_ARCHIVE_DIR, in the layout of c2pa-rs release archives.
archives="$work/upstream-test-archives"
mkdir "$archives"
for target in aarch64-apple-ios-sim x86_64-apple-ios; do
  staging="$work/upstream-test-archives-staging/$target"
  mkdir -p "$staging/lib" "$staging/include"
  cp "$work/rust/target/$target/release/libc2pa_c.a" "$staging/lib/"
  cp "$work/c2pa.h" "$staging/include/"
  (cd "$staging" && zip -qr "$archives/c2pa-rebuilt-$target.zip" lib include)
done

echo "Testing on $destination"
xcodebuild -workspace "$work/swift/C2PA.xcworkspace" -scheme Library -configuration Debug \
  -destination "$destination" -derivedDataPath "$work/derived-upstream" \
  -resultBundlePath "$result" C2PA_ARCHIVE_DIR="$archives" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
  ${excluded[@]+"${excluded[@]}"} test
