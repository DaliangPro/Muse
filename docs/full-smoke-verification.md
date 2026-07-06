# Full Smoke Verification

Use this checklist before and after high-risk changes to session state, global
hotkeys, app startup, injection, recording, or persistence. The default command
is safe for normal development; optional checks are explicit because they may
open apps, require macOS permissions, or touch real credentials.

## Stable Automated Checks

```bash
scripts/smoke-check.sh
```

This runs:

- `swift build`
- `swift test`

Expected result: all tests pass. UI injection tests remain skipped unless the
optional environment is enabled.

## Optional Text Injection Check

```bash
scripts/smoke-check.sh --ui-injection
```

Prerequisites:

- TextEdit can be launched.
- The terminal running the test has Accessibility permission.
- The terminal can send Apple Events to TextEdit.

Expected result:

- TextEdit receives the injected marker.
- The caret remains after the inserted text.
- The test closes the temporary TextEdit document without saving.

## Optional Packaged App Launch Check

```bash
scripts/smoke-check.sh --app-launch
```

Expected result:

- The app bundle is rebuilt.
- The packaged app process starts.
- The script exits successfully after detecting the running app.

## Manual Hotkey Check

Run after touching `HotkeyManager`, mode hotkey settings, app startup, or session
abort behavior.

1. Build and launch the packaged app:

   ```bash
   scripts/build_and_run.sh run
   ```

2. Confirm Accessibility permission is granted to the launched app.
3. Configure one hold hotkey and one toggle hotkey in Settings.
4. Hold hotkey path:
   - Press and hold the hotkey.
   - Recording starts once.
   - Key repeat does not start another session.
   - Releasing the hotkey stops recording once.
5. Toggle path:
   - Press once to start.
   - Press the same hotkey again to stop.
   - Press a different toggle-mode hotkey while recording.
   - The active mode stops and the new mode is selected for processing.
6. ESC path:
   - Press ESC while recording.
   - Recording aborts, UI returns to idle, no stale recording indicator remains.
   - Press ESC while post-processing if reachable.
   - Processing aborts and UI returns to idle.

## Manual Recording And Session Check

Run after touching `RecognitionSession`, ASR clients, audio capture, LLM
post-processing, injection, or history writes.

1. Confirm Microphone permission is granted.
2. Direct mode:
   - Record a short phrase.
   - Stop normally.
   - Final text is inserted or copied according to the injection outcome.
   - One history row is created with `completed` status.
3. LLM mode:
   - Record a short phrase using a mode with a prompt.
   - UI enters post-processing.
   - Final text is the processed result when LLM succeeds.
   - If LLM credentials are missing, raw text is retained and status reflects LLM failure.
4. Cancel path:
   - Start recording.
   - Abort before stopping.
   - UI returns to idle.
   - No stale transcript or progress state remains.
5. Provider switch path:
   - Start with one ASR provider selected.
   - Change global provider settings only after the session starts.
   - Stop the current session.
   - The active session finishes against its captured provider.

## Manual Persistence Check

Run after touching `HistoryStore`, `LanguageAssetStore`, migrations, or asset UI.

1. Start with an existing local database if available.
2. Open settings and inspect recent history.
3. Create a new recording and confirm it appears first.
4. Run language asset extraction on recent records.
5. Save one candidate as an asset.
6. Ignore one candidate.
7. Restart the app.
8. Confirm saved assets, ignored candidates, favorites, and history remain stable.

## Manual Window And Settings Check

For settings-only UI changes, use the narrower checklist in
`docs/settings-smoke-verification.md`.

For app or window lifecycle changes:

1. Launch the packaged app.
2. Open Settings from the menu bar.
3. Switch through General, Modes, Models, Vocabulary, Assets, and About.
4. Close and reopen Settings.
5. Start and stop a recording while Settings is open.
6. Confirm the floating bar appears above normal windows and disappears on idle.
7. Quit and relaunch the app.
8. Confirm no duplicate windows, stale floating bars, or missing menu bar item.

## Report Template

Record results in the PR, commit notes, or handoff summary:

```text
Smoke date:
Commit:
Command checks:
- scripts/smoke-check.sh:
- scripts/smoke-check.sh --ui-injection:
- scripts/smoke-check.sh --app-launch:

Manual checks:
- Hotkeys:
- Recording/session:
- Persistence:
- Window/settings:

Failures or skipped checks:
```
