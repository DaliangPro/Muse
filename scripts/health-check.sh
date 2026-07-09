#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

FAILED=0

run_step() {
  local name="$1"
  shift
  local start end status
  start="$(date +%s)"
  echo
  echo "==> $name"
  "$@"
  status=$?
  end="$(date +%s)"
  echo "TOOL:$name EXIT:$status DURATION:$((end - start))s"
  if [ "$status" -ne 0 ]; then
    FAILED=1
  fi
}

skip_step() {
  local name="$1"
  local reason="$2"
  echo
  echo "==> $name"
  echo "SKIP: $reason"
  echo "TOOL:$name EXIT:SKIPPED DURATION:0s"
}

bash_syntax() {
  local status=0
  while IFS= read -r -d '' file; do
    bash -n "$file" || status=1
  done < <(find scripts -type f -name "*.sh" -print0 | sort -z)
  return "$status"
}

python_service_syntax() {
  python3 - <<'PY'
import ast
import pathlib
import sys

paths = [
    pathlib.Path("sensevoice-server/server.py"),
    pathlib.Path("qwen3-asr-server/server.py"),
]

failed = False
for path in paths:
    try:
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        print(f"OK {path}")
    except SyntaxError as exc:
        print(f"ERROR {path}:{exc.lineno}:{exc.offset}: {exc.msg}")
        failed = True

sys.exit(1 if failed else 0)
PY
}

run_optional_tool() {
  local name="$1"
  local command_name="$2"
  shift 2
  if command -v "$command_name" >/dev/null 2>&1; then
    run_step "$name" "$@"
  else
    skip_step "$name" "$command_name not installed"
  fi
}

echo "CODE HEALTH CHECK"
echo "Project: Muse"
echo "Branch:  $(git branch --show-current 2>/dev/null || echo unknown)"
echo "Date:    $(date '+%Y-%m-%d %H:%M:%S %Z')"

run_step "swift-build-debug" swift build
run_step "swift-build-release" swift build -c release
run_step "swift-test" swift test
run_step "bash-syntax" bash_syntax
run_step "python-service-syntax" python_service_syntax

run_optional_tool "shellcheck" shellcheck shellcheck scripts/*.sh
run_optional_tool "swiftlint" swiftlint swiftlint
run_optional_tool "periphery" periphery periphery scan

echo
if [ "$FAILED" -eq 0 ]; then
  echo "HEALTH_CHECK_RESULT: PASS"
else
  echo "HEALTH_CHECK_RESULT: FAIL"
fi

exit "$FAILED"
