#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/.build/packaging/AirTouch.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/AirTouch" "$app_dir/Contents/MacOS/AirTouch"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
signing_identity="${AIRTOUCH_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  development_identities=$(security find-identity -v -p codesigning | sed -n 's/.* \([A-F0-9]\{40\}\) "Apple Development:.*"/\1/p')
  if [[ "$development_identities" == *$'\n'* ]]; then
    printf 'Multiple development identities found; set AIRTOUCH_SIGN_IDENTITY.\n' >&2
    exit 1
  fi
  signing_identity="${development_identities:--}"
fi
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --strict "$app_dir"
if [[ "$signing_identity" == - ]]; then
  printf 'Ad-hoc signing: Accessibility may need to be granted again after updates.\n'
else
  printf 'Development signing: stable application identity across updates.\n'
fi
printf 'Built: %s\n' "$app_dir"
