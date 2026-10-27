#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

SIM="SailBrowser-$(basename "$(git rev-parse --show-toplevel)")"
xcrun simctl list devices | grep -qF "    $SIM (" || xcrun simctl create "$SIM" "iPhone 17 Pro" >/dev/null

mkdir -p .build
xcodegen generate --quiet
status=0
xcodebuild build -project SailBrowser.xcodeproj -scheme SailBrowser \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath .build/DerivedData \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES 2>&1 | tee .build/build.log || status=$?

if grep -E 'SailBrowser/[^:]+\.swift:[0-9]+:[0-9]+: (warning|error):' .build/build.log >&2; then
  echo "build.sh: compiler diagnostics in SailBrowser/" >&2
  exit 1
fi
exit "$status"
