# Settings Smoke Verification

Use this flow after settings layout or settings component changes. Old screenshots
in `dist/`, `tmp/`, or `docs/screenshots/` are historical references only; they
are not evidence for current UI behavior.

For cross-module session, hotkey, injection, persistence, and app lifecycle
checks, use `docs/full-smoke-verification.md`.

## Build and test

```bash
swift build
swift test
```

## Launch the app

```bash
APP_PATH="$PWD/dist/Muse.app" APP_NAME="Muse" bash scripts/package-app.sh
open "$PWD/dist/Muse.app"
```

Open `Muse 设置` from the menu bar app so verification uses real saved
credentials and user settings.

## Capture current screenshots

Create a fresh output directory if needed:

```bash
mkdir -p tmp/current-ui-verification
```

Use the current window location and size from Accessibility or a first broad
screen capture, then capture the settings window with `screencapture -R`:

```bash
screencapture -x -R<left>,<top>,<width>,<height> tmp/current-ui-verification/settings-current.png
```

For sidebar-tab checks, click the target row in the current window before
capturing. Example from the 2026-06-04 verification run:

```bash
osascript -e 'tell application "System Events" to click at {1200, 488}'
screencapture -x -R1121,273,765,722 tmp/current-ui-verification/settings-vocabulary-current.png
```

## What to check

- The settings window opens with the expected title.
- Sidebar selection is visible and stable.
- Cards do not overlap or clip text.
- Buttons, chips, fields, and menu controls fit within their containers.
- The content area uses the current `SettingsLayout` width and insets.

## Cleanup

Stop the app after capture:

```bash
pgrep -fl Muse
kill <process-id>
```

Keep only screenshots needed for the current report or commit notes.
