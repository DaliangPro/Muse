#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVER_DIR="$PROJECT_DIR/sensevoice-server"

echo "=== Building sensevoice-server standalone binary ==="

cd "$SERVER_DIR"

# Ensure venv exists
if [ ! -d .venv ]; then
    echo "Creating venv..."
    # 用 uv 建 venv（自带 python 管理，不依赖系统 brew python3.12 是否存在）
    uv venv --python 3.12 .venv
fi

source .venv/bin/activate

# Install dependencies + pyinstaller（.venv 由 uv 创建，不含 pip，改用 uv pip）
echo "Installing dependencies..."
REQUIREMENTS_FILE="requirements.lock.txt"
[ -f "$REQUIREMENTS_FILE" ] || REQUIREMENTS_FILE="requirements.txt"
uv pip install -q -r "$REQUIREMENTS_FILE"
uv pip install -q pyinstaller

# Clean previous build
rm -rf build dist *.spec

# Build standalone binary
echo "Running PyInstaller..."
pyinstaller \
    --onedir \
    --name sensevoice-server \
    --hidden-import=funasr \
    --hidden-import=funasr.models \
    --hidden-import=asr_decoder \
    --hidden-import=asr_decoder.ctc_decoder \
    --hidden-import=asr_decoder.context_graph \
    --hidden-import=online_fbank \
    --hidden-import=pysilero \
    --hidden-import=sentencepiece \
    --hidden-import=torch \
    --hidden-import=torchaudio \
    --hidden-import=soundfile \
    --hidden-import=uvicorn \
    --hidden-import=uvicorn.logging \
    --hidden-import=uvicorn.loops \
    --hidden-import=uvicorn.loops.auto \
    --hidden-import=uvicorn.protocols \
    --hidden-import=uvicorn.protocols.http \
    --hidden-import=uvicorn.protocols.http.auto \
    --hidden-import=uvicorn.protocols.websockets \
    --hidden-import=uvicorn.protocols.websockets.auto \
    --hidden-import=uvicorn.lifespan \
    --hidden-import=uvicorn.lifespan.on \
    --hidden-import=email_validator \
    --collect-all funasr \
    --collect-all asr_decoder \
    --collect-all online_fbank \
    --collect-all email_validator \
    --noconfirm \
    server.py

echo ""
echo "=== Signing binaries for macOS Gatekeeper ==="
DIST="$SERVER_DIR/dist/sensevoice-server"
# Ad-hoc sign all executables and dylibs to avoid Gatekeeper blocking
find "$DIST" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - "$DIST/sensevoice-server" 2>/dev/null || true
echo "Signing complete."

echo ""
echo "=== Build complete ==="
echo "Output: $DIST"
du -sh "$DIST" 2>/dev/null || true
echo ""
echo "Test with:"
echo "  $DIST/sensevoice-server --model-dir iic/SenseVoiceSmall --port 8765"
