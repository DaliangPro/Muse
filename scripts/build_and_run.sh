#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [ "$#" -gt 0 ]; then
  shift
fi
APP_ARGS=()
if [ "${1:-}" = "--args" ]; then
  shift
  APP_ARGS=("$@")
elif [ "$#" -gt 0 ]; then
  echo "usage: $0 [run|--verify|--logs|--telemetry|--debug] [--args <app arguments...>]" >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Muse"
APP_BUNDLE_ID="pro.daliang.muse"
APP_PATH="${MUSE_APP_PATH:-/Applications/Muse.app}"
PREVIEW_APP_PATH="$ROOT_DIR/dist/Muse-Preview.app"

quit_app() {
  local bundle_id="$1"
  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
}

move_preview_to_trash() {
  if [ -d "$PREVIEW_APP_PATH" ]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    /bin/mv "$PREVIEW_APP_PATH" "$HOME/.Trash/Muse-Preview-$stamp.app"
  fi
}

build_app() {
  quit_app "pro.daliang.muse.preview"
  quit_app "$APP_BUNDLE_ID"
  sleep 1
  move_preview_to_trash

  APP_PATH="$APP_PATH" \
  APP_NAME="$APP_NAME" \
  APP_BUNDLE_ID="$APP_BUNDLE_ID" \
  "$ROOT_DIR/scripts/package-app.sh"
}

open_app() {
  if [ "${#APP_ARGS[@]}" -gt 0 ]; then
    /usr/bin/open -n "$APP_PATH" --args "${APP_ARGS[@]}"
  else
    /usr/bin/open -n "$APP_PATH"
  fi
}

case "$MODE" in
  run)
    build_app
    open_app
    ;;
  --verify|verify)
    build_app
    open_app
    sleep 2
    /usr/bin/pgrep -af "$APP_PATH/Contents/MacOS/Muse" >/dev/null
    ;;
  --logs|logs)
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"Muse\""
    ;;
  --telemetry|telemetry)
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$APP_BUNDLE_ID\""
    ;;
  --debug|debug)
    build_app
    /usr/bin/lldb -- "$APP_PATH/Contents/MacOS/Muse"
    ;;
  *)
    echo "usage: $0 [run|--verify|--logs|--telemetry|--debug] [--args <app arguments...>]" >&2
    exit 2
    ;;
esac
