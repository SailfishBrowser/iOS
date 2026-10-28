#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

SIM="SailBrowser-$(basename "$(git rev-parse --show-toplevel)")"
xcrun simctl list devices | grep -qF "    $SIM (" || xcrun simctl create "$SIM" "iPhone 17 Pro" >/dev/null
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl spawn "$SIM" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true

only=()
for arg in "$@"; do
  only+=("-only-testing:$arg")
done

xcodegen generate --quiet
xcodebuild test -project SailBrowser.xcodeproj -scheme SailBrowser \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath .build/DerivedData \
  ${TEST_RUNNER_SAIL_CI:+-retry-tests-on-failure -test-iterations 2} \
  ${only[@]+"${only[@]}"}
