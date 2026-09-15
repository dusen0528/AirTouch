#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
source_app="$PWD/.build/packaging/AirTouch.app"
destination="${AIRTOUCH_INSTALL_DIR:-$HOME/Applications}/AirTouch.app"
registry=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$(dirname "$destination")"
staging_dir=$(mktemp -d "$(dirname "$destination")/.airtouch-install.XXXXXX")
backup_dir="$staging_dir/previous"
committed=false
cleanup() {
  if [[ "$committed" == false && -d "$backup_dir/Contents" ]]; then
    # Roll back even if verification failed after the replacement was moved in.
    if [[ -e "$destination/Contents" ]]; then
      mv "$destination/Contents" "$staging_dir/failed-Contents"
    fi
    mv "$backup_dir/Contents" "$destination/Contents"
  fi
  rm -rf -- "$staging_dir"
}
trap cleanup EXIT
ditto "$source_app" "$staging_dir/AirTouch.app"
codesign --verify --strict "$staging_dir/AirTouch.app"
if [[ -e "$destination" ]]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")
  if [[ "$bundle_id" != dev.airtouch.practice && "$bundle_id" != dev.airtouch.mac ]]; then
    printf 'Another application exists at %s\n' "$destination" >&2
    exit 1
  fi
  if pgrep -f "$destination/Contents/MacOS/AirTouch" >/dev/null; then
    printf 'Quit the installed AirTouch before updating.\n' >&2
    exit 1
  fi
  mkdir -p "$backup_dir"
  # Keep the application directory inode: existing aliases continue to point here.
  mv "$destination/Contents" "$backup_dir/Contents"
fi
mkdir -p "$destination"
mv "$staging_dir/AirTouch.app/Contents" "$destination/Contents"
codesign --verify --strict "$destination"
"$registry" -f "$destination"
committed=true
# The install directory is the only persistent .app; source history lives in Git.
"$registry" -u "$source_app" >/dev/null 2>&1 || true
rm -rf -- "$source_app"
printf 'Installed: %s\n' "$destination"
open "$destination"
