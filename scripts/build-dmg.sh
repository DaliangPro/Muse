#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
APP_NAME="Muse"
APP_VERSION="${APP_VERSION:-1.7.2}"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
DMG_NAME="${DMG_NAME:-${APP_NAME}-v${APP_VERSION}.dmg}"
DMG_PATH="$DIST_DIR/$DMG_NAME"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muse-dmg.XXXXXX")"

trash_path() {
    local path="$1"
    [ -e "$path" ] || return 0

    local base stamp target
    base="$(basename "$path")"
    stamp="$(date +%Y%m%d-%H%M%S)"
    target="$HOME/.Trash/${base}-${stamp}"
    while [ -e "$target" ]; do
        stamp="$(date +%Y%m%d-%H%M%S)-$RANDOM"
        target="$HOME/.Trash/${base}-${stamp}"
    done
    /bin/mv "$path" "$target"
}

cleanup() {
    trash_path "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"

APP_PATH="$STAGING_DIR/${APP_NAME}.app" bash "$SCRIPT_DIR/package-app.sh"
ln -s /Applications "$STAGING_DIR/Applications"

trash_path "$DMG_PATH"
echo "Creating DMG at $DMG_PATH..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "DMG ready at $DMG_PATH"
