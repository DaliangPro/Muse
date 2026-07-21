#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
if [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
    [ -n "${MUSE_PACKAGE_PROJECT_DIR:-}" ] || {
        echo "MUSE_PACKAGE_PROJECT_DIR is required in package test mode" >&2
        exit 1
    }
    PROJECT_DIR="$(cd "$MUSE_PACKAGE_PROJECT_DIR" && /bin/pwd -P)"
else
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
fi
APP_PATH="${APP_PATH:-$PROJECT_DIR/dist/Muse.app}"
APP_NAME="${APP_NAME:-Muse}"
APP_EXECUTABLE="Muse"
APP_ICON_NAME="AppIcon"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-pro.daliang.muse}"
APP_VERSION="${APP_VERSION:-1.7.4}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
MICROPHONE_USAGE_DESCRIPTION="${MICROPHONE_USAGE_DESCRIPTION:-Muse 需要访问麦克风以录制语音并将其转换为文本。}"
SPEECH_RECOGNITION_USAGE_DESCRIPTION="${SPEECH_RECOGNITION_USAGE_DESCRIPTION:-Muse 需要语音识别权限以将你的语音转写为文字。}"
APPLE_EVENTS_USAGE_DESCRIPTION="${APPLE_EVENTS_USAGE_DESCRIPTION:-Muse 需要辅助功能权限来注入转写文字到其他应用}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
SENSEVOICE_DIST="$PROJECT_DIR/sensevoice-server/dist/sensevoice-server"
QWEN3_DIST="$PROJECT_DIR/qwen3-asr-server/dist/qwen3-asr-server"

# Local packaging must fail before building or replacing an existing Bundle when
# either frozen service distribution is unavailable.
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] \
    && { [ ! -d "$SENSEVOICE_DIST" ] || [ ! -d "$QWEN3_DIST" ]; }; then
    echo "Local bundle requested, but both frozen service distributions are required." >&2
    exit 1
fi
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] \
    && { [ ! -f "$SENSEVOICE_DIST/sensevoice-server" ] \
        || [ ! -x "$SENSEVOICE_DIST/sensevoice-server" ] \
        || [ ! -f "$QWEN3_DIST/qwen3-asr-server" ] \
        || [ ! -x "$QWEN3_DIST/qwen3-asr-server" ]; }; then
    echo "Local bundle requested, but both frozen service launchers are required and must be executable." >&2
    exit 1
fi

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

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Muse Dev"; then
    SIGNING_IDENTITY="Muse Dev"
elif [ -d "$APP_PATH" ] && codesign -dv "$APP_PATH" 2>/dev/null; then
    # Existing app is already signed -- reuse its identity to preserve Accessibility permission.
    # Changing signing identity invalidates macOS TCC entries (Accessibility, etc).
    EXISTING_AUTHORITY=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2)
    if [ -n "$EXISTING_AUTHORITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$EXISTING_AUTHORITY"; then
        SIGNING_IDENTITY="$EXISTING_AUTHORITY"
        echo "Reusing existing signing identity: $SIGNING_IDENTITY"
    else
        # Existing app was ad-hoc signed or cert is gone -- keep ad-hoc to not break permission
        SIGNING_IDENTITY="-"
    fi
else
    # Fresh install, no existing app. Default to ad-hoc signing. Creating and trusting
    # a local certificate modifies the user's login keychain, so it is opt-in.
    CERT_NAME="Muse Local"
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
        if [ "${ALLOW_LOCAL_CERT_BOOTSTRAP:-0}" != "1" ]; then
            echo "No code signing identity found; using ad-hoc signing."
            echo "Set ALLOW_LOCAL_CERT_BOOTSTRAP=1 to create a persistent local signing certificate."
            SIGNING_IDENTITY="-"
        else
            echo "Creating self-signed certificate '$CERT_NAME' for consistent code signing..."
            echo "This opt-in operation updates the login keychain trust settings."
            CERT_TEMP=$(mktemp -d)
            CERT_PASSWORD="$(openssl rand -hex 16)"
            cat > "$CERT_TEMP/cert.cfg" <<CERTEOF
[ req ]
distinguished_name = req_dn
[ req_dn ]
CN = $CERT_NAME
[ extensions ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
CERTEOF
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$CERT_TEMP/key.pem" -out "$CERT_TEMP/cert.pem" \
                -days 3650 -subj "/CN=$CERT_NAME" -extensions extensions \
                -config "$CERT_TEMP/cert.cfg" 2>/dev/null
            # -legacy + 非空密码：openssl 3.x 默认 p12 加密 security import 不识别，
            # 会只导入证书、丢私钥 → codesign 退回 ad-hoc（CDHash 每次变、辅助功能授权反复失效）。
            # -A 让 codesign 可无授权框访问私钥。（2026-06-22 修复）
            openssl pkcs12 -export -legacy -out "$CERT_TEMP/cert.p12" \
                -inkey "$CERT_TEMP/key.pem" -in "$CERT_TEMP/cert.pem" \
                -name "$CERT_NAME" -passout "pass:$CERT_PASSWORD" 2>/dev/null
            security import "$CERT_TEMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
                -T /usr/bin/codesign -A -P "$CERT_PASSWORD" 2>/dev/null || \
            security import "$CERT_TEMP/cert.p12" -k ~/Library/Keychains/login.keychain \
                -T /usr/bin/codesign -A -P "$CERT_PASSWORD" 2>/dev/null || true
            security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db \
                "$CERT_TEMP/cert.pem" 2>/dev/null || \
            security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain \
                "$CERT_TEMP/cert.pem" 2>/dev/null || true
            trash_path "$CERT_TEMP"
            echo "Certificate '$CERT_NAME' created and trusted."
            SIGNING_IDENTITY="$CERT_NAME"
        fi
    else
        SIGNING_IDENTITY="$CERT_NAME"
    fi
fi

run_swift_build() {
    set +e
    swift build "$@" 2>&1 | grep -E "Build complete|Build succeeded|error:|warning:"
    local build_status=${PIPESTATUS[0]}
    set -e
    if [ "$build_status" -ne 0 ]; then
        echo "swift build failed with exit code $build_status"
        exit "$build_status"
    fi
}

if [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
    BINARY="${MUSE_PACKAGE_BINARY:-}"
    [ -f "$BINARY" ] || {
        echo "MUSE_PACKAGE_BINARY must point to a fixture executable" >&2
        exit 1
    }
else
    XCBUILD_BIN="/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild"
    if [ -x "$XCBUILD_BIN" ]; then
        echo "Building universal release (arm64 + x86_64)..."
        run_swift_build -c release --package-path "$PROJECT_DIR" --arch arm64 --arch x86_64
    else
        echo "xcbuild not found, falling back to single-arch release build..."
        run_swift_build -c release --package-path "$PROJECT_DIR"
    fi

    if [ -f "$PROJECT_DIR/.build/apple/Products/Release/Muse" ]; then
        BINARY="$PROJECT_DIR/.build/apple/Products/Release/Muse"
    elif [ -f "$PROJECT_DIR/.build/release/Muse" ]; then
        BINARY="$PROJECT_DIR/.build/release/Muse"
    else
        BINARY="$(find "$PROJECT_DIR/.build" -path '*/release/Muse' -type f -not -path '*/x86_64/*' -not -path '*/arm64/*' | head -n 1)"
    fi
fi

if [ ! -f "$BINARY" ]; then
    echo "Build failed: binary not found"
    exit 1
fi

echo "Packaging app bundle at $APP_PATH..."
trash_path "$APP_PATH/Contents"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
cp "$PROJECT_DIR/Muse/Resources/${APP_ICON_NAME}.icns" "$APP_PATH/Contents/Resources/${APP_ICON_NAME}.icns" 2>/dev/null || true
cp "$PROJECT_DIR/Muse/Resources/BrandLogo.png" "$APP_PATH/Contents/Resources/BrandLogo.png" 2>/dev/null || true

cat >"$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_EXECUTABLE}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_ICON_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_SYSTEM_VERSION}</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>${MICROPHONE_USAGE_DESCRIPTION}</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>${SPEECH_RECOGNITION_USAGE_DESCRIPTION}</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APPLE_EVENTS_USAGE_DESCRIPTION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${APP_BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>muse</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

mkdir -p "$APP_PATH/Contents/Resources/Sounds"
cp "$PROJECT_DIR/Muse/Resources/Sounds/"*.wav "$APP_PATH/Contents/Resources/Sounds/" 2>/dev/null || true

# Copy SenseVoice model if available (for full DMG builds)
SENSEVOICE_MODEL_CACHE="$HOME/.cache/modelscope/hub/models/iic/SenseVoiceSmall"
if [ "${BUNDLE_SENSEVOICE_MODEL:-0}" = "1" ] && [ -d "$SENSEVOICE_MODEL_CACHE" ]; then
    echo "Bundling SenseVoice model..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp -R "$SENSEVOICE_MODEL_CACHE" "$APP_PATH/Contents/Resources/Models/SenseVoiceSmall"
    echo "SenseVoice model bundled."
fi

# Copy Qwen3-ASR model (4-bit quantized) if available
QWEN3_MODEL_CACHE="${QWEN3_MODEL_PATH:-$HOME/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B-4bit}"
if [ "${BUNDLE_SENSEVOICE_MODEL:-0}" = "1" ] && [ -d "$QWEN3_MODEL_CACHE" ]; then
    echo "Bundling Qwen3-ASR model (4-bit)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models/Qwen3-ASR"
    cp "$QWEN3_MODEL_CACHE"/model.safetensors "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/"
    cp "$QWEN3_MODEL_CACHE"/config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/"
    cp "$QWEN3_MODEL_CACHE"/tokenizer_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/vocab.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/merges.txt "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/generation_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/preprocessor_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    echo "Qwen3-ASR model bundled."
fi

# Copy both local services only for the Local product. A requested Local build
# must never silently degrade into a Cloud bundle.
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ]; then
    echo "Bundling sensevoice-server..."
    cp -R "$SENSEVOICE_DIST" "$APP_PATH/Contents/MacOS/sensevoice-server-dist"
    mkdir -p "$APP_PATH/Contents/Resources/LocalServices"
    # Shell wrapper remains a sealed resource. The executable entry is an in-bundle
    # symlink to the signed PyInstaller Mach-O, so codesign does not treat a shell
    # script under Contents/MacOS as unsigned nested code.
    cat > "$APP_PATH/Contents/Resources/LocalServices/sensevoice-server-wrapper.sh" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/../../MacOS/sensevoice-server-dist/sensevoice-server" "$@"
WRAPPER
    ln -s "sensevoice-server-dist/sensevoice-server" "$APP_PATH/Contents/MacOS/sensevoice-server"
    echo "sensevoice-server bundled."

    echo "Bundling qwen3-asr-server..."
    cp -R "$QWEN3_DIST" "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist"
    cat > "$APP_PATH/Contents/Resources/LocalServices/qwen3-asr-server-wrapper.sh" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/../../MacOS/qwen3-asr-server-dist/qwen3-asr-server" "$@"
WRAPPER
    ln -s "qwen3-asr-server-dist/qwen3-asr-server" "$APP_PATH/Contents/MacOS/qwen3-asr-server"
    echo "qwen3-asr-server bundled."
fi

# Copy LLM model if available (for local LLM DMG builds)
LLM_MODEL_DIR="$PROJECT_DIR/sensevoice-server/models"
LLM_MODEL_SIZE="${BUNDLE_LOCAL_LLM:-0}"  # 0=none, 9b（2026-06-11 起 4B 已从产品除名）
if [ "$LLM_MODEL_SIZE" = "9b" ] && [ -f "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" ]; then
    echo "Bundling Qwen3.5-9B LLM model (5.3GB)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" "$APP_PATH/Contents/Resources/Models/qwen3.5-9b-q4_k_m.gguf"
    echo "Qwen3.5-9B model bundled."
fi

# Remove quarantine flag that macOS adds to downloaded apps.
# This must happen before the final outer signature; after that the Bundle is read-only.
/usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "Signing with '${SIGNING_IDENTITY}'..."
SIGNING_IDENTITY="$SIGNING_IDENTITY" APP_BUNDLE_ID="$APP_BUNDLE_ID" \
    /bin/bash "$SCRIPT_DIR/sign-app-bundle.sh" "$APP_PATH"

EXPECT_LOCAL_BUNDLE="${BUNDLE_LOCAL_ASR:-0}" \
APP_BUNDLE_ID="$APP_BUNDLE_ID" \
APP_VERSION="$APP_VERSION" \
APP_BUILD="$APP_BUILD" \
MIN_SYSTEM_VERSION="$MIN_SYSTEM_VERSION" \
    /bin/bash "$SCRIPT_DIR/test_app_bundle.sh" "$APP_PATH"

echo "App bundle ready at $APP_PATH"
