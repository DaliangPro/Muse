#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_PATH="${MUSE_VOICE_POLISH_LIVE_REPORT:-$PROJECT_DIR/build/voice-polish-live-report.json}"
LIMIT="${MUSE_VOICE_POLISH_LIVE_LIMIT:-100}"

mkdir -p "$(dirname "$REPORT_PATH")"
cd "$PROJECT_DIR"
MUSE_VOICE_POLISH_LIVE=1 \
MUSE_VOICE_POLISH_LIVE_LIMIT="$LIMIT" \
MUSE_VOICE_POLISH_LIVE_REPORT="$REPORT_PATH" \
swift test --filter VoicePolishLiveBenchmarkTests/testExplicitLiveProviderBenchmark

echo "Voice Polish Live Benchmark 报告：$REPORT_PATH"
