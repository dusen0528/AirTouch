#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
destination="${AIRTOUCH_INSTALL_DIR:-$HOME/Applications}/AirTouch.app"
mkdir -p "$(dirname "$destination")"
staging_dir=$(mktemp -d "$(dirname "$destination")/.airtouch-install.XXXXXX")
backup_dir=""
cleanup() {
  if [[ -n "$backup_dir" && ! -e "$destination/Contents" && -d "$backup_dir/Contents" ]]; then
    mv "$backup_dir/Contents" "$destination/Contents"
  fi
  rm -rf -- "$staging_dir"
}
trap cleanup EXIT
ditto build/AirTouch.app "$staging_dir/AirTouch.app"
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
  backup_dir="$HOME/Library/Application Support/AirTouch/Backups/$(date +%Y%m%d-%H%M%S)-$RANDOM.airtouch-backup"
  mkdir -p "$backup_dir"
  # Preserve the application directory inode so macOS does not follow its alias to a backup app.
  mv "$destination/Contents" "$backup_dir/Contents"
fi
mkdir -p "$destination"
mv "$staging_dir/AirTouch.app/Contents" "$destination/Contents"
rmdir "$staging_dir/AirTouch.app" "$staging_dir"
codesign --verify --strict "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
printf 'Installed: %s\n' "$destination"
open "$destination"
