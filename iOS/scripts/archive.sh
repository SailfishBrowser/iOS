#!/bin/bash
# Archives, exports and uploads a TestFlight build. Needs DEVELOPMENT_TEAM (the Apple team ID that signs it) and
# the App Store Connect API key in ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH. CURRENT_PROJECT_VERSION sets the build
# number (the HEAD commit's UTC time as yyyyMMddHHmm when unset); MARKETING_VERSION and SAIL_DEFAULT_BROWSER, when
# set, override project.yml's.
set -euo pipefail
cd "$(dirname "$0")/.."

upload=1
for arg in "$@"; do
  case "$arg" in
    --no-upload) upload=0 ;;
    *) echo "usage: scripts/archive.sh [--no-upload]" >&2; exit 2 ;;
  esac
done

if [ -n "$(git status --porcelain -- .)" ]; then
  echo "archive.sh: commit or stash changes first" >&2
  exit 1
fi

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to the Apple team ID that signs the app}"
: "${ASC_KEY_ID:?set ASC_KEY_ID to the App Store Connect API key id}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the App Store Connect issuer id}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the AuthKey .p8 file}"
auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

build="${CURRENT_PROJECT_VERSION:-$(TZ=UTC git show -s --format=%cd --date=format-local:%Y%m%d%H%M HEAD)}"
overrides=()
[ -z "${MARKETING_VERSION:-}" ] || overrides+=(MARKETING_VERSION="$MARKETING_VERSION")
[ -z "${SAIL_DEFAULT_BROWSER:-}" ] || overrides+=(SAIL_DEFAULT_BROWSER="$SAIL_DEFAULT_BROWSER")
archive=".build/Archives/SailBrowser-$build.xcarchive"
mkdir -p .build/Archives
rm -rf "$archive" .build/Export

xcodegen generate --quiet
status=0
xcodebuild archive -project SailBrowser.xcodeproj -scheme SailBrowser \
  -configuration Release -destination generic/platform=iOS \
  -archivePath "$archive" -derivedDataPath .build/DerivedData \
  -allowProvisioningUpdates "${auth[@]}" \
  CURRENT_PROJECT_VERSION="$build" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" ${overrides[@]+"${overrides[@]}"} \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES 2>&1 | tee .build/archive.log || status=$?

if grep -E 'SailBrowser/[^:]+\.swift:[0-9]+:[0-9]+: (warning|error):' .build/archive.log >&2; then
  echo "archive.sh: compiler diagnostics in SailBrowser/" >&2
  exit 1
fi
if [ "$status" != 0 ] && grep -qE 'com\.apple\.developer\.web-browser|Default Browser' .build/archive.log; then
  echo "archive.sh: signing failed on com.apple.developer.web-browser: the profile does not grant it." \
    "Apple must approve the request and the App ID needs the Default Browser capability," \
    "or set SAIL_DEFAULT_BROWSER to NO to build without it." >&2
  exit 1
fi
[ "$status" = 0 ] || exit "$status"

scripts/check-release.sh "$archive/Products/Applications/SailBrowser.app"

cp scripts/ExportOptions.plist .build/ExportOptions.plist
/usr/libexec/PlistBuddy -c "Add :teamID string $DEVELOPMENT_TEAM" .build/ExportOptions.plist

# IPA packaging shells out to rsync and breaks on Homebrew rsync 3.x, so export on the system PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist .build/ExportOptions.plist \
  -exportPath .build/Export -allowProvisioningUpdates "${auth[@]}" 2>&1 | tee .build/export.log

ipa=$(ls .build/Export/*.ipa | head -1)
echo "archive.sh: build $build exported to $ipa"
[ "$upload" = 1 ] || exit 0

# altool exits 0 on some upload failures, so its output is checked for ERROR too.
status=0
xcrun altool --upload-app -f "$ipa" -t ios \
  --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH" \
  > .build/upload.log 2>&1 || status=$?
if [ "$status" != 0 ] || grep -q 'ERROR' .build/upload.log; then
  cat .build/upload.log >&2
  echo "archive.sh: upload of build $build failed" >&2
  exit 1
fi
cat .build/upload.log
echo "archive.sh: build $build uploaded"
