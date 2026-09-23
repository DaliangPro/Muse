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
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
PREVIEW_APP_PATH="$ROOT_DIR/dist/Muse-Preview.app"

quit_app() {
  local bundle_id="$1"
  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
}

running_app_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v executable="$APP_EXECUTABLE" '
    {
      pid = $1
      command = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command)
      if (command == executable || index(command, executable " ") == 1) {
        print pid
      }
    }
  '
}

wait_for_app_exit() {
  local attempts="${1:-20}"
  while [ "$attempts" -gt 0 ]; do
    if [ -z "$(running_app_pids)" ]; then
      return 0
    fi
    sleep 0.1
    attempts=$((attempts - 1))
  done
  return 1
}

terminate_running_instances() {
  quit_app "$APP_BUNDLE_ID"
  if wait_for_app_exit 20; then
    return 0
  fi

  local pid
  while IFS= read -r pid; do
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      /bin/kill "$pid" >/dev/null 2>&1 || true
    fi
  done < <(running_app_pids)

  if ! wait_for_app_exit 20; then
    echo "ERROR: existing $APP_NAME process did not exit: $(running_app_pids)" >&2
    return 1
  fi
}

verify_single_running_instance() {
  local pids count
  pids="$(running_app_pids)"
  count="$(printf '%s\n' "$pids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  if [ "$count" -ne 1 ]; then
    echo "ERROR: expected exactly one $APP_NAME process, found $count: $pids" >&2
    return 1
  fi
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
  terminate_running_instances
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
    verify_single_running_instance
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
