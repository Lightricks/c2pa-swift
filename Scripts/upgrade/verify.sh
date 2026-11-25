#!/bin/bash
# Link the package into an iOS app for devices and simulators, then run the tests on a simulator.
#
# Usage: verify.sh <work directory> <UpgradeVerification directory> <result bundle> [destination]
# Without a destination, the tests run on an available iPhone simulator of the newest iOS runtime.
set -euo pipefail

scripts="$(cd "$(dirname "$0")" && pwd)"
work="$(cd "$1" && pwd)"
tests="$(cd "$2" && pwd)"
result="$3"
destination="${4:-}"
project="$work/verified-package-input/UpgradeVerification"
test ! -e "$project"
cp -R "$tests" "$project"
rm -rf "$project/FixtureGenerator" "$project/.build"
fixtures="$project/Tests/UpgradeVerificationTests/Fixtures"
cp "$tests/../TestShared/Resources/es256_certs.pem" "$fixtures/"
cp "$tests/../TestShared/Resources/es256_private.key" "$fixtures/"

# Building the package's library only compiles it. Linking an app resolves every symbol that the
# static C2PA library needs, so a missing symbol or system library fails here.
app_project="$project/DeviceLinkCheck/DeviceLinkCheck.xcodeproj"
xcodebuild -project "$app_project" -scheme DeviceLinkCheck -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$work/derived-device" \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project "$app_project" -scheme DeviceLinkCheck -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/derived-device" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

check_app() {
  local binary="$1" platform="$2" architectures="$3"
  local actual
  actual="$(xcrun lipo -archs "$binary" | tr ' ' '\n' | sort | xargs)"
  test "$actual" = "$(echo "$architectures" | tr ' ' '\n' | sort | xargs)" ||
    { echo "error: $binary has architectures $actual, expected $architectures" >&2; exit 1; }
  for architecture in $architectures; do
    # grep reads all input, since `grep -q` could fail the pipeline with SIGPIPE.
    xcrun vtool -arch "$architecture" -show-build "$binary" | grep -E "platform +$platform\$" >/dev/null
    xcrun nm -arch "$architecture" -U -j "$binary" | grep -x _c2pa_builder_sign >/dev/null
  done
  echo "$binary: $architectures, $platform, $(stat -f %z "$binary") bytes"
}
products="$work/derived-device/Build/Products"
check_app "$products/Release-iphoneos/DeviceLinkCheck.app/DeviceLinkCheck" IOS arm64
check_app "$products/Release-iphonesimulator/DeviceLinkCheck.app/DeviceLinkCheck" IOSSIMULATOR \
  'arm64 x86_64'

if [ -z "$destination" ]; then
  destination="$("$scripts/simulator-destination.sh")"
fi
echo "Testing on $destination"

cd "$project"
xcodebuild -scheme UpgradeVerification -configuration Debug \
  -destination "$destination" -derivedDataPath "$work/derived-simulator" \
  -parallel-testing-enabled NO -resultBundlePath "$result" test
