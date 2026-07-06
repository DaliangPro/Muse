# Muse — Development Guide

## Repair Plan（修复任务必读）

所有修复/重构工作以根目录 [REPAIR_PLAN.md](REPAIR_PLAN.md) 为唯一指导与进度台账：
动手前先读其「使用规则」，认领任务改状态，完成后按验收标准验证并销账。

## Overview

macOS menu bar voice input tool with dual-engine local ASR, multi-provider cloud ASR, and LLM post-processing.
Local ASR: SenseVoice (streaming) + Qwen3-ASR (final calibration), both as Python WebSocket services managed by `SenseVoiceServerManager`.
Cloud ASR: Volcano only（2026-06-11 产品决策：云端厂商只保留火山引擎，见 REPAIR_PLAN G1）.
Swift Package Manager project, no Xcode project file. Optional `sherpa-onnx.xcframework` for punctuation restoration.

## Build & Run

```bash
# Local ASR setup (optional, skip for cloud-only)
cd sensevoice-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.lock.txt && cd ..  # lock 为已验证版本组合，requirements.txt 仅作顶层声明
cd qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.lock.txt && cd ..  # Apple Silicon only

# Optional: punctuation restoration module (~5 min, requires cmake)
bash scripts/build-sherpa.sh

swift build -c release
```

The built binary is at `.build/release/Muse`. To package it as a `.app` bundle, see `scripts/deploy.sh`.

## ASR Provider Architecture

Multi-provider ASR support via `ASRProvider` enum + `ASRProviderConfig` protocol + `ASRProviderRegistry`.

- `ASRProvider` enum: 3 cases (sherpa/apple/volcano)
- Each provider has its own Config type (e.g., `SherpaASRConfig`, `VolcanoASRConfig`) defining `credentialFields` for dynamic UI rendering
- `ASRProviderRegistry`: maps provider to config type + client factory; `capabilities` indicates availability and streaming support
- **Fully implemented**: sherpa (local, batch), apple (on-device streaming), volcano (streaming)

### Adding a New Provider

1. Create a Config file in `Muse/ASR/Providers/`, implementing `ASRProviderConfig`
2. Write the client (implementing `SpeechRecognizer` protocol)
3. Register `createClient` in `ASRProviderRegistry.all`

## Local ASR Architecture (SenseVoice + Qwen3-ASR)

### Dual-Engine Design
- **SenseVoice** (`sensevoice-server/`): Python FastAPI WebSocket service, provides real-time streaming recognition (partial results as you speak)
- **Qwen3-ASR** (`qwen3-asr-server/`): Python WebSocket service using MLX (Metal GPU), provides final calibration on complete audio for higher accuracy. Apple Silicon only.
- `SenseVoiceServerManager`: manages both Python server processes, auto-detects Apple Silicon vs Intel, assigns dynamic ports, saves PIDs for graceful shutdown

### Recognition Pipeline
1. `SenseVoiceWSClient` connects to local Python servers via WebSocket
2. Three modes: SenseVoice streaming only, Qwen3-only (final result), or hybrid (SenseVoice streaming + Qwen3 final calibration)
3. Qwen3 incremental speculative transcription with debounce for progressive results
4. `SherpaPunctuationProcessor` (optional) — CT-Transformer post-processing adds punctuation (requires `sherpa-onnx.xcframework`)

### Models
- One streaming model in `ModelManager.StreamingModel`: `senseVoiceSmall` (~228MB, zh/en/yue/ja/ko)
- Auxiliary models: `offlineParaformer` (~700MB), `punctuation` CT-Transformer (~72MB)
- Models downloaded from GitHub releases (tar.bz2), stored at `~/Library/Application Support/Muse/models/`

### SherpaOnnx Integration (optional, for punctuation only)
- `SherpaOnnxBridge.swift` — Swift wrapper over C API (no Obj-C bridging header needed)
- `sherpa-onnx.xcframework` — built locally via `scripts/build-sherpa.sh`, not checked into git
- `Package.swift` uses runtime detection: `hasSherpaFramework` flag conditionally defines `HAS_SHERPA_ONNX` and links SherpaOnnxLib

## Download Manager (`ModelManager`)

- Progress tracking via delegate-based `URLSession.downloadTask` (NOT async `session.download()` which doesn't report progress)
- **Resumable downloads**: captures `NSURLSessionDownloadTaskResumeData` from errors, uses `downloadTask(withResumeData:)` to resume
- Auto-retry up to N times with exponential backoff
- Active sessions stored in `activeSessions` dict for cancellation via `invalidateAndCancel()`
- Cancel clears: activeTasks, activeSessions, downloadProgress, resumeData

## Credential Storage

Credentials are stored at `~/Library/Application Support/Muse/credentials.json` (file permissions 0600).

**Do not rely on environment variables** for credentials in production. GUI-launched apps cannot read shell env vars from `~/.zshrc`. Credentials must be configured through the Settings UI.

### credentials.json Structure

```json
{
    "tf_asr_volcano": { "appKey": "...", "accessKey": "...", "resourceId": "..." },
    "tf_asr_openai": { "apiKey": "sk-..." },
    "tf_llmApiKey": "...",
    "tf_llmModel": "...",
    "tf_llmBaseURL": "..."
}
```

## Permissions Required

| Permission | Purpose |
|---|---|
| Microphone | Audio capture |
| Accessibility | Global hotkey listening + text injection into other apps |

## Key Files

| Path | Responsibility |
|---|---|
| `Muse/ASR/ASRProvider.swift` | Provider enum + protocol + CredentialField |
| `Muse/ASR/ASRProviderRegistry.swift` | Registry: provider → config + client factory + capabilities |
| `Muse/ASR/Providers/*.swift` | Per-vendor Config implementations |
| `Muse/ASR/SpeechRecognizer.swift` | SpeechRecognizer protocol + LLMConfig + event types |
| `Muse/ASR/SenseVoiceWSClient.swift` | Local ASR client (WebSocket to Python servers, dual-engine) |
| `Muse/ASR/VolcASRClient.swift` | Cloud streaming ASR (Volcano, WebSocket) |
| `Muse/ASR/SherpaPunctuationProcessor.swift` | Optional punctuation restoration (SherpaOnnx) |
| `Muse/Bridge/SherpaOnnxBridge.swift` | SherpaOnnx C API Swift bridge (conditional) |
| `Muse/Services/SenseVoiceServerManager.swift` | Local Python server lifecycle (SenseVoice + Qwen3-ASR) |
| `Muse/Session/RecognitionSession.swift` | Core state machine: record → ASR → inject |
| `Muse/Audio/AudioCaptureEngine.swift` | Audio capture, `getRecordedAudio()` returns full recording |
| `Muse/UI/AppState.swift` | `ProcessingMode` definition, built-in mode list |
| `Muse/Services/ModelManager.swift` | SenseVoice model download, validation, selection |
| `Muse/Services/KeychainService.swift` | Credential read/write (provider groups + migration) |
| `Muse/Services/HotwordStorage.swift` | ASR hotword storage (UserDefaults) |
| `Muse/LLM/LLMProvider.swift` | 13 LLM providers (incl. local Qwen offline) |
| `Muse/LLM/LLMProviderRegistry.swift` | LLM provider → config + client factory |
| `Muse/Session/SoundFeedback.swift` | Start/stop/error sounds, multiple sound styles |
| `sensevoice-server/server.py` | SenseVoice streaming ASR + optional local Qwen LLM |
| `qwen3-asr-server/server.py` | Qwen3-ASR calibration engine (MLX/Metal, Apple Silicon) |
| `scripts/deploy.sh` | Build + deploy + launch |
| `scripts/build-sherpa.sh` | Build sherpa-onnx.xcframework (optional, for punctuation) |

## Development Lessons & Patterns

### Streaming ASR: Duplicate Text Prevention
- Streaming ASR emits partial results that get replaced by final results
- Must track `confirmedText` (finalized segments) separately from `currentPartial`
- Display `confirmedText + currentPartial`, replace partial on each update, append on segment finalization
- Endpoint detection signals segment boundaries

### First-Character Accuracy
- Recording start sound bleeds into first ~400ms of audio
- Solution: skip initial 6400 samples (at 16kHz) in the ASR client before feeding to recognizer
- This dramatically improves first-character recognition accuracy

### URLSession Download Progress
- `async let (url, response) = session.download(for: request)` does NOT trigger delegate progress callbacks
- Must use `session.downloadTask(with:)` + `DownloadProgressDelegate` for real-time progress
- Store URLSession reference in a dict for proper cancellation

### Large File Downloads
- GitHub public forks cannot use Git LFS — keep large binaries out of repo
- For downloads >100MB, connection drops are common (error -1005)
- `NSURLSessionDownloadTaskResumeData` in error's userInfo enables resume
- Also check `NSUnderlyingErrorKey` for nested resume data

### UI Patterns
- Dangerous actions (delete) should require two-step confirmation (show button → confirm)
- Undownloaded items shouldn't show selection UI (radio buttons) — show download button instead
- Test/action buttons should be spatially separated from destructive actions
- Download progress UI must use `@Published` properties on `@MainActor` for SwiftUI updates

### Git Workflow for Fork Contributions
- `sherpa-onnx.xcframework` (156MB) cannot be pushed to GitHub public forks (no LFS)
- Solution: `.gitignore` the framework, provide `scripts/build-sherpa.sh` for local builds
- When merging upstream: `git fetch upstream && git rebase upstream/main`
- Resolve conflicts by combining both sides (e.g., keep upstream's Deepgram + our Sherpa)
- Force push after rebase: `git push origin main --force --tags`

### Package.swift Conditional Dependencies
```swift
let hasSherpaFramework = FileManager.default.fileExists(
    atPath: packageDir + "/Frameworks/sherpa-onnx.xcframework/Info.plist"
)
// Conditionally add binary target and linker settings
```
This allows the project to build even without the framework (graceful degradation).

### Sound Feedback
- `StartSoundStyle` enum: off, chime (synthesized), waterDrop1, waterDrop2
- Bundled WAV files in `Muse/Resources/Sounds/`, copied to app bundle by deploy.sh
- Use `AVAudioPlayer` for bundled sounds (cached), `afplay` via Process for synthesized tones
- Sound selection persisted via UserDefaults key `tf_startSound`
