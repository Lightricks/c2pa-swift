#!/bin/bash
# Print the xcodebuild destination of an available iPhone simulator of the newest iOS runtime.
set -euo pipefail

udid="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
runtimes = json.load(sys.stdin)["devices"]
def version(runtime):
    match = re.search(r"\.iOS-([0-9-]+)$", runtime)
    return tuple(int(part) for part in match[1].split("-")) if match else None
for runtime in sorted((r for r in runtimes if version(r)), key=version, reverse=True):
    phones = [device for device in runtimes[runtime] if device["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        break
')"
test -n "$udid"
echo "platform=iOS Simulator,id=$udid"
