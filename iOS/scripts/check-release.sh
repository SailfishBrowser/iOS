#!/bin/bash
set -euo pipefail

app="${1:?usage: scripts/check-release.sh <App.app>}"
plist="$app/Info.plist"
status=0

expect() {
  local actual
  actual=$(plutil -extract "$1" raw -o - "$plist") || actual="<missing>"
  if [ "$actual" != "$2" ]; then
    echo "check-release.sh: $1 is $actual, expected $2" >&2
    status=1
  fi
}

expect CFBundleIdentifier com.haladir.arcmobile
expect CFBundleDisplayName Sail
expect CFBundleName Sailfish
expect ITSAppUsesNonExemptEncryption false
expect LSApplicationCategoryType public.app-category.utilities
expect UIDeviceFamily.0 1
expect UIDeviceFamily.1 "<missing>"
expect UISupportedInterfaceOrientations.0 UIInterfaceOrientationPortrait
expect UISupportedInterfaceOrientations.1 "<missing>"
expect CFBundleURLTypes.0.CFBundleURLSchemes.0 http
expect CFBundleURLTypes.0.CFBundleURLSchemes.1 https

version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "check-release.sh: CFBundleShortVersionString $version is not a version like 1.2 or 1.2.3" >&2
  status=1
fi

build=$(plutil -extract CFBundleVersion raw -o - "$plist")
if ! [[ "$build" =~ ^[1-9][0-9]*$ ]]; then
  echo "check-release.sh: CFBundleVersion $build is not a positive integer" >&2
  status=1
fi

# A signed app that claims the default browser entitlement needs a profile that grants it. Unsigned builds carry neither.
web=com.apple.developer.web-browser
tmp=$(mktemp -d)
if codesign -d --entitlements - --xml "$app" >"$tmp/signed.plist" 2>/dev/null \
  && /usr/libexec/PlistBuddy -c "Print :$web" "$tmp/signed.plist" 2>/dev/null | grep -qx true; then
  if ! security cms -D -i "$app/embedded.mobileprovision" >"$tmp/profile.plist" 2>/dev/null \
    || ! /usr/libexec/PlistBuddy -c "Print :Entitlements:$web" "$tmp/profile.plist" 2>/dev/null | grep -qx true; then
    echo "check-release.sh: the app claims $web but its provisioning profile does not grant it." \
      "Apple must approve the request and the App ID needs the Default Browser capability," \
      "or set SAIL_DEFAULT_BROWSER to NO to build without it." >&2
    status=1
  fi
fi
rm -rf "$tmp"

privacy="$app/PrivacyInfo.xcprivacy"
if [ ! -f "$privacy" ]; then
  echo "check-release.sh: PrivacyInfo.xcprivacy is not in the app bundle" >&2
  status=1
else
  plist="$privacy"
  expect NSPrivacyTracking false
  expect NSPrivacyCollectedDataTypes.0 "<missing>"
  expect NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType NSPrivacyAccessedAPICategoryUserDefaults
  expect NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 CA92.1
  expect NSPrivacyAccessedAPITypes.1 "<missing>"
fi

exit "$status"
