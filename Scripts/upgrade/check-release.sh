#!/bin/bash
# Check a published release the way an app consumes it: check that the tag is on main, compare the
# published XCFramework ZIP with the manifest's checksum and the checksum asset, verify that the
# upgrade workflow on main built it, then resolve the package by URL in a clean SwiftPM consumer
# and build the consumer for iOS devices.
#
# Usage: check-release.sh <tag> [repository URL]
# Set CHECK_IOS_ONLY=0 to check a release that isn't a Lightricks release, such as upstream's: it
# then accepts other platforms and plain version tags, and skips the checksum asset and the build
# provenance. Set CHECK_CONSUMER=0 to skip the SwiftPM consumer.
set -euo pipefail

tag="$1"
repository="${2:-https://github.com/Lightricks/c2pa-swift}"
ios_only="${CHECK_IOS_ONLY:-1}"
version="${tag#v}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

semver='v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
if [ "$ios_only" = 1 ]; then
  [[ "$tag" =~ ^$semver-lightricks\.[1-9][0-9]*$ ]] ||
    fail "expected a tag such as v0.1.0-lightricks.1, got '$tag'"
else
  [[ "$tag" =~ ^$semver(-[0-9A-Za-z.-]+)?$ ]] || fail "expected a tag such as v0.1.0, got '$tag'"
fi

# A partial clone has the whole history, so that the tag can be checked against main.
git -c advice.detachedHead=false clone --quiet --filter=blob:none --branch "$tag" "$repository" \
  "$work/source"
revision="$(git -C "$work/source" rev-parse HEAD)"
git -C "$work/source" merge-base --is-ancestor "$revision" origin/main ||
  fail "$tag ($revision) isn't on main"
manifest="$work/source/Package.swift"
url="$(sed -nE 's/^ *url: "(.*\/C2PAC\.xcframework\.zip)",?$/\1/p' "$manifest")"
expected="$(sed -nE 's/^ *checksum: "([0-9a-f]{64})",?$/\1/p' "$manifest")"
[ "$url" = "$repository/releases/download/$tag/C2PAC.xcframework.zip" ] ||
  fail "Package.swift at $tag points to '$url'"
[ -n "$expected" ] || fail "Package.swift at $tag has no C2PAC checksum"
if [ "$ios_only" = 1 ]; then
  platforms="$(tr -d '\n ' < "$manifest" | sed -nE 's/.*platforms:\[([^]]*)\].*/\1/p')"
  [ "$platforms" = ".iOS(.v16)" ] || fail "Package.swift at $tag declares platforms $platforms"
fi

curl --fail --silent --show-error --location --retry 2 "$url" --output "$work/C2PAC.xcframework.zip"
actual="$(swift package compute-checksum "$work/C2PAC.xcframework.zip")"
[ "$actual" = "$expected" ] || fail "the published ZIP has checksum $actual, Package.swift declares $expected"

if [ "$ios_only" = 1 ]; then
  checksum_url="$repository/releases/download/$tag/C2PAC.xcframework.checksum"
  curl --fail --silent --show-error --location --retry 2 "$checksum_url" \
    --output "$work/published.checksum" || fail "$tag has no C2PAC.xcframework.checksum asset"
  [ "$(tr -d '[:space:]' < "$work/published.checksum")" = "$expected" ] ||
    fail "C2PAC.xcframework.checksum doesn't match Package.swift"

  # The ZIP must come from the upgrade workflow on main, from a commit whose Swift sources the tag
  # ships unchanged.
  slug="${repository#https://github.com/}"
  gh attestation verify "$work/C2PAC.xcframework.zip" --repo "$slug" \
    --signer-workflow "$slug/.github/workflows/lightricks-upgrade.yml" --source-ref refs/heads/main \
    --format json > "$work/attestation.json" || fail "the published ZIP has no valid build provenance"
  built="$(python3 -c 'import json, sys
results = json.load(open(sys.argv[1]))
print(results[0]["verificationResult"]["signature"]["certificate"]["sourceRepositoryDigest"])' \
    "$work/attestation.json")"
  git -C "$work/source" merge-base --is-ancestor "$built" "$revision" ||
    fail "the ZIP was built from $built, which isn't an ancestor of $tag"
  git -C "$work/source" diff --quiet "$built" "$revision" -- Library/Sources ||
    fail "Library/Sources at $tag differs from $built, which built the ZIP"
  echo "$tag: C2PAC.xcframework.zip was built by the upgrade workflow from $built"
fi

if [ "${CHECK_CONSUMER:-1}" = 1 ]; then
  consumer="$work/consumer"
  mkdir -p "$consumer/Sources/Consumer"
  cat > "$consumer/Package.swift" <<EOF
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.iOS(.v16)],
    dependencies: [.package(url: "$repository", exact: "$version")],
    targets: [.target(name: "Consumer", dependencies: [.product(name: "C2PA", package: "c2pa-swift")])]
)
EOF
  cat > "$consumer/Sources/Consumer/Consumer.swift" <<'EOF'
import C2PA

public let c2paVersion = C2PA.version
EOF
  cd "$consumer"
  # SwiftPM verifies the downloaded ZIP against the manifest's checksum while resolving.
  swift package --cache-path "$work/cache" --scratch-path "$work/build" resolve
  resolved="$(python3 -c 'import json
pins = json.load(open("Package.resolved"))["pins"]
print(next(pin["state"]["revision"] for pin in pins if pin["identity"] == "c2pa-swift"))')"
  [ "$resolved" = "$revision" ] || fail "SwiftPM resolved $resolved, $tag is $revision"
  [ -d "$work/build/artifacts/c2pa-swift/C2PAC/C2PAC.xcframework/ios-arm64" ] ||
    fail "SwiftPM didn't extract the iOS device slice"
  xcodebuild -scheme Consumer -destination 'generic/platform=iOS' -derivedDataPath "$work/derived" \
    -clonedSourcePackagesDirPath "$work/packages" CODE_SIGNING_ALLOWED=NO build
fi
echo "$tag: $revision is on main, C2PAC.xcframework.zip SHA-256 $actual matches Package.swift"
