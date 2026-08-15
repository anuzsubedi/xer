#!/bin/bash

set -euo pipefail

TAG="${1:?usage: build-release.sh vMAJOR.MINOR.PATCH BUILD_NUMBER}"
BUILD_NUMBER="${2:?usage: build-release.sh vMAJOR.MINOR.PATCH BUILD_NUMBER}"

if [[ ! "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  echo "Invalid release tag: $TAG" >&2
  exit 1
fi

VERSION="${BASH_REMATCH[1]}"
TEAM="${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required}"
IDENTITY="${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}"
NOTARY_PROFILE="${NOTARY_PROFILE:-xer-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${RUNNER_TEMP:-$ROOT/.build}/xer-release-${GITHUB_RUN_ID:-local}"
ARCHIVE="$WORK_ROOT/xer.xcarchive"
EXPORT_OPTIONS="$WORK_ROOT/ExportOptions.plist"
EXPORT_DIR="$WORK_ROOT/export"
STAGE="$WORK_ROOT/dmg-root"
DIST="$ROOT/dist"
APP="$EXPORT_DIR/xer.app"

notarize() {
  local artifact="$1"
  local label="$2"
  local result_file="$WORK_ROOT/notary-$label.json"
  local submission_id=""
  local submit_status=0

  set +e
  xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json | tee "$result_file"
  submit_status=${PIPESTATUS[0]}
  set -e

  if [[ $submit_status -ne 0 ]]; then
    submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_file" 2>/dev/null || true)"
    if [[ -n "$submission_id" ]]; then
      echo "Notarization failed. Fetching Apple log for $submission_id…" >&2
      xcrun notarytool log "$submission_id" \
        --keychain-profile "$NOTARY_PROFILE" || true
    fi
    return "$submit_status"
  fi
}

cleanup() {
  if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

rm -rf "$WORK_ROOT" "$DIST"
mkdir -p "$WORK_ROOT" "$DIST" "$STAGE"

echo "Archiving xer $VERSION ($BUILD_NUMBER)…"
xcodebuild archive \
  -project "$ROOT/xer.xcodeproj" \
  -scheme xer \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean archive

/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
/usr/bin/plutil -insert destination -string export "$EXPORT_OPTIONS"
/usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS"
/usr/bin/plutil -insert signingCertificate -string "$IDENTITY" "$EXPORT_OPTIONS"
/usr/bin/plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
/usr/bin/plutil -insert teamID -string "$TEAM" "$EXPORT_OPTIONS"

echo "Exporting the archive for Developer ID distribution…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

test -d "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/xer")"
grep -qw arm64 <<<"$APP_ARCHS"
grep -qw x86_64 <<<"$APP_ARCHS"

ditto -c -k --keepParent --sequesterRsrc "$APP" "$WORK_ROOT/xer-notary.zip"
notarize "$WORK_ROOT/xer-notary.zip" app
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

ditto -c -k --keepParent --sequesterRsrc "$APP" "$DIST/xer.app.zip"

ditto "$APP" "$STAGE/xer.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "xer $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DIST/xer.dmg"

codesign --force --timestamp --sign "$IDENTITY" "$DIST/xer.dmg"
codesign --verify --verbose=2 "$DIST/xer.dmg"
notarize "$DIST/xer.dmg" dmg
xcrun stapler staple "$DIST/xer.dmg"
xcrun stapler validate "$DIST/xer.dmg"
hdiutil verify "$DIST/xer.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DIST/xer.dmg"

if [[ -d "$ARCHIVE/dSYMs" ]]; then
  ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$DIST/xer-dSYMs.zip"
else
  ditto -c -k --keepParent "$APP/Contents/MacOS" "$DIST/xer-dSYMs.zip"
fi

(
  cd "$DIST"
  shasum -a 256 xer.dmg xer.app.zip xer-dSYMs.zip > SHA256SUMS
)

echo "Release artifacts are in $DIST"
