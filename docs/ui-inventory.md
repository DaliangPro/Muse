# Settings UI Inventory and Cleanup Plan

Date: 2026-06-04

This document audits the current SwiftUI settings UI and defines the cleanup plan for turning scattered local styling into a small, shared UI system.

## Executive Summary

The current UI inconsistency is not primarily a radius problem. Radius is only one symptom. The real problem is that many settings views hand-build controls with local combinations of:

- `.buttonStyle(.plain)`
- manual `.frame(height:)`
- local `.padding(...)`
- local `.background { RoundedRectangle(...).fill(...) }`
- local font sizes and weights
- local opacity values for rest/active states
- local control groups nested inside rounded containers

This makes visually similar elements behave like different components. A radius token cannot fix that by itself.

## Current Scope

The settings UI is the main target.

Audit counts from `Muse/UI`:

| Metric | Count |
|---|---:|
| Swift UI files | 103 |
| Settings Swift files | 88 |
| `Button(` occurrences in settings | 91 |
| `.buttonStyle(.plain)` occurrences in settings | 42 |
| `RoundedRectangle` / `Capsule` occurrences in settings | 111 |
| `.frame(... height:)` occurrences in settings | 136 |
| `.padding(...)` occurrences in settings | 172 |

The top hotspot files by local UI styling density are:

| File | Notes |
|---|---|
| `AssetLibrarySavedAssetsView.swift` | Search field, type filters, asset rows, grade badges, copy button all hand-styled. |
| `AssetLibraryDetailComponents.swift` | Detail action buttons, tags, rows, dividers all hand-styled. |
| `AssetLibraryRulesView.swift` | Reset button, scope buttons, text blocks, inner panels hand-styled. |
| `SettingsSidebarControls.swift` | Nav rows, segmented controls, toggles use local shapes and sizing. |
| `AssetLibraryToolbar.swift` | Toolbar group, view switch, extraction button all local. |
| `ModeToolbarControls.swift` | Hotkey control and trigger segmented control are local variants. |
| `ModeDetailInner.swift` | Header actions and text-area surfaces use local styling. |
| `ModesSettingsTab.swift` | Model chip and new button are locally styled. |

## Current Design Primitives

The project currently has some shared tokens in `Muse/UI/DesignSystem.swift`:

| Token | Value | Intended Role |
|---|---:|---|
| `TF.radiusControl` | `8` | Interactive controls. |
| `TF.radiusSurface` | `12` | Cards, panels, popovers, surfaces. |
| `TF.settingsControlHeight` | `28` | Default control height. |
| `TF.settingsMiniButtonHeight` | `26` | Legacy mini button height. Candidate for removal. |
| `TF.settingsControlCornerRadius` | `8` | Alias for control radius. |
| `TF.settingsPrimaryCardCornerRadius` | `12` | Alias for surface radius. |
| `TF.settingsInnerCardCornerRadius` | `12` | Alias for surface radius. |

This is a good base, but it is not enough. Local views still create their own controls instead of using shared components.

## Target UI System

The cleanup should create a small set of components. The goal is fewer choices, not a richer design system.

### 1. `SettingsButton`

All interactive text/icon buttons in settings should use this component unless they are native macOS controls.

Variants:

| Variant | Use |
|---|---|
| `primary` | Main affirmative actions: Save, Confirm, Extract, Save Asset. |
| `secondary` | Normal actions: Cancel, Edit, Source, Ignore, Reset, Record. |
| `ghost` | Low-emphasis text actions only when a filled button would be too heavy. |
| `danger` | Destructive actions. |
| `icon` | Square icon-only actions. |

Contract:

| Property | Value |
|---|---:|
| Default height | `28` |
| Radius | `8` |
| Horizontal padding | `12` or tokenized equivalent |
| Font | one shared settings control font |
| Background | defined by variant, not per call site |
| Disabled opacity | defined by component |

Forbidden in call sites:

- Manually applying `.frame(height:)` to a button.
- Manually applying `.background(RoundedRectangle...)` to a button.
- Manually choosing background opacity for rest/active button states.
- Creating same-row actions where one is a chip, one is plain text, and one is a button.

### 2. `SettingsControlGroup`

Use only where multiple controls are logically one grouped selector, such as segmented navigation.

Variants:

| Variant | Use |
|---|---|
| `segmented` | Mutually exclusive choices: Today / Library / Rules, Hold / Toggle. |
| `toolbar` | Dense mode toolbar controls, only when grouping is necessary. |

Contract:

| Property | Rule |
|---|---|
| Outer radius | `12` for segmented track, or no track if grouping is not needed. |
| Inner selected control radius | `8` |
| Height | one token per group type, not per feature file |
| Active/rest fill | component-owned |

Anti-pattern to remove:

- Arbitrary `HStack` groups with their own `padding(3)`, `height: 30`, inner `height: 22`, and mixed opacities.

### 3. `SettingsField`

Use for text fields, secure fields, search fields, hotkey display fields, and fixed-width fields.

Contract:

| Property | Value |
|---|---:|
| Height | `28` |
| Radius | `8` |
| Font | shared settings field font |
| Fill/stroke | component-owned |

Native macOS controls can remain native only when they are intentionally platform-standard and not mixed beside custom controls in the same row.

### 4. `SettingsChip`

Use only for non-primary metadata, not for same-level actions.

Examples:

- Model name (`DeepSeek`)
- Grade badge
- Asset tag
- Saved/status badge

Contract:

| Property | Rule |
|---|---|
| Interactive chip | should probably be a `SettingsButton`, not `SettingsChip`. |
| Informational chip | smaller is allowed, but must not visually compete with buttons. |
| Radius | `8` |
| Fill | component-owned by semantic tone. |

### 5. `SettingsSurface`

Use for cards, panels, popovers, and modal-like containers.

Contract:

| Property | Value |
|---|---:|
| Radius | `12` |
| Padding | tokenized by surface size |
| Fill | shared surface fill tokens |

Nesting rules:

- Do not put card-like surfaces inside card-like surfaces unless there is a genuine embedded editor or detail pane.
- Prefer spacing, dividers, and section headers over stacked rounded backgrounds.
- If an inner surface is required, it must use `SettingsSurface` and be justified by structure, not decoration.

## Component Categories in the Current UI

### Mode Toolbar

Files:

- `ModePickerControl.swift`
- `ModeToolbarControls.swift`
- `ModesSettingsTab.swift`
- `ModeDetailInner.swift`

Current problems:

- `直出模式`, `重录`, `按住录制`, `按下切换`, `DeepSeek`, `+ 新建`, `恢复默认`, and `保存修改` are all control-like elements but are built in separate files.
- Heights and inner heights are split across `modeToolbarControlHeight`, `modeHotkeyRecordHeight`, local padding, and fixed widths.
- Some controls use group tracks, some are standalone, some are chips, but they sit in one visual row.

Target:

- Use one `SettingsToolbar` or `SettingsControlGroup` for the mode toolbar.
- Use `SettingsButton` for all interactive actions.
- Use `SettingsChip` only for non-interactive metadata like model name.
- Keep one height contract for toolbar controls.

### Asset Library Toolbar and Detail Actions

Files:

- `AssetLibraryToolbar.swift`
- `AssetLibraryDetailComponents.swift`
- `AssetLibrarySavedAssetsView.swift`
- `AssetLibraryRuleStrategyCard.swift`
- `AssetCandidateGroupsPanel.swift`

Current problems:

- `今日发现 / 资产库 / 规则 / 提炼` are manually built segmented/action controls.
- `原始输入 / 忽略 / 入库` were visually different despite being same-row actions.
- Filter chips, asset rows, tags, grade badges, and buttons share similar shapes but are locally styled.

Target:

- Use `SettingsControlGroup` for view switching.
- Use `SettingsButton(primary/secondary)` for action rows.
- Use `SettingsChip` for filters and metadata only if they are not primary actions.
- Asset list rows should use a shared `SettingsListRow` or a feature-specific row that delegates selection fill/radius to the shared system.

### Model Settings Forms

Files:

- `ASRSettingsCard.swift`
- `LLMSettingsCard.swift`
- `LocalModelSettingsCard.swift`
- `ASRCredentialRows.swift`
- `LLMCredentialRows.swift`
- `FixedWidthTextField.swift`
- `SettingsCardButtons.swift`

Current status:

- This area already has more shared helpers than Modes and Asset Library.
- It still mixes helper buttons with native controls and custom fixed-width field styling.

Target:

- Convert existing `settingsMiniButton`, `primaryButton`, `secondaryButton`, and `testButton` into `SettingsButton` wrappers or remove them after migration.
- Move field styling into `SettingsField`.

### Vocabulary

Files:

- `VocabularyTab.swift`
- `VocabularyTextField.swift`
- `VocabularyTag.swift`
- `VocabularyReplacementChip.swift`
- `VocabularySnippetGroupRow.swift`
- `VocabularyTabHelpers.swift`

Current status:

- Vocabulary has local style helpers and reference-frame modifiers.
- It is less chaotic than Asset Library, but it still has its own chip/text-field styling.

Target:

- Replace vocabulary-specific field/chip components with shared `SettingsField` and `SettingsChip`.
- Keep feature-specific layout widths in `VocabularySettingsStyle`, but remove visual definitions from that style.

### Sidebar

Files:

- `SettingsSidebarView.swift`
- `SettingsSidebarControls.swift`
- `SettingsSidebarLayout.swift`
- `SettingsSidebarSettingsPanel.swift`

Current problems:

- Sidebar has custom nav rows, custom segmented controls, custom mini switch, custom hover backgrounds.
- Some of this is legitimate because sidebar density differs from content panes.

Target:

- Keep sidebar layout constants in `SettingsSidebarLayout`.
- Move nav row background/hover/selection styling into a shared sidebar row component.
- Keep the mini switch as a special `Capsule` control.

## Proposed File Structure

Create a small UI kit under `Muse/UI/Settings/Components/` or directly in `Muse/UI/Settings/` if the project prefers a flat folder.

Suggested files:

| File | Purpose |
|---|---|
| `SettingsButton.swift` | Button variants and icon button. |
| `SettingsControlGroup.swift` | Segmented control and toolbar group primitives. |
| `SettingsField.swift` | Text/search/hotkey display field styling. |
| `SettingsChip.swift` | Metadata chip/badge styles. |
| `SettingsSurface.swift` | Card/panel/popover surfaces. |
| `SettingsListRow.swift` | Optional selected/rest row style for asset lists/sidebar-like rows. |

## Migration Plan

### Phase 0: Freeze Visual Rules

Before migrating, agree on:

- One interactive control height.
- One text control font.
- Which controls deserve a group track.
- Which items are chips vs buttons.
- Which nested surfaces are structural and which should be removed.

Recommended initial defaults:

| Rule | Value |
|---|---:|
| Interactive control height | `28` |
| Control radius | `8` |
| Surface radius | `12` |
| Main content surface padding | `16` |
| Inner surface padding | `12` |
| Toolbar control font size | `10` or `11`, choose one |
| Normal control font size | `11` |

### Phase 1: Build Primitives Without Replacing Everything

Add the shared components and a local preview/demo view or update `docs/radius-preview.html` into a broader UI preview.

No visual migration yet except possibly replacing the existing `SettingsCardButtons` helpers internally.

### Phase 2: Migrate the Most Visible Broken Area

Start with Modes:

- `ModePickerControl.swift`
- `ModeToolbarControls.swift`
- `ModesSettingsTab.swift`
- `ModeDetailInner.swift`

Reason: this is where the toolbar screenshot shows inconsistent control shapes and nesting.

Acceptance:

- Top toolbar looks like one designed system.
- Same-row controls have consistent height and visual grammar.
- Model name is clearly metadata, not a button.
- Header actions use the same button component as other settings actions.

### Phase 3: Migrate Asset Library

Files:

- `AssetLibraryToolbar.swift`
- `AssetLibraryDetailComponents.swift`
- `AssetLibrarySavedAssetsView.swift`
- `AssetLibraryRuleStrategyCard.swift`
- `AssetCandidateGroupsPanel.swift`
- `AssetLibraryRulesView.swift`

Acceptance:

- View switch and extract action are visually coherent.
- Detail actions are all buttons, with only primary/secondary distinction.
- Asset tags and badges are clearly metadata chips.
- Rows use consistent selected/rest backgrounds.

### Phase 4: Migrate Forms and Vocabulary

Files:

- model/credential rows
- `VocabularyTextField.swift`
- `VocabularyTag.swift`
- `VocabularyReplacementChip.swift`
- `VocabularyTabHelpers.swift`

Acceptance:

- Text fields and search fields share one spec.
- Mini buttons and footer buttons share one button component.
- Feature style files only hold layout dimensions, not visual recipes.

### Phase 5: Sidebar and Surface Cleanup

Files:

- `SettingsSidebarControls.swift`
- `SettingsSidebarView.swift`
- card/surface helper files

Acceptance:

- Sidebar remains dense but uses shared selection/fill/radius primitives.
- Card nesting is removed where it is purely decorative.
- Remaining nested surfaces are intentional editors/detail panes.

### Phase 6: Delete Legacy Helpers

Candidates to remove or collapse:

- `settingsMiniButton`, `primaryButton`, `secondaryButton`, `testButton` once replaced by `SettingsButton`.
- Feature-level aliases like `AssetLibraryStyle.chipCornerRadius` if they only mirror global tokens.
- Style constants that describe visual styling rather than layout.

## Rules for Future UI Code

After migration, new settings UI should follow these rules:

1. Do not create buttons by composing `Button + .plain + frame + background` in feature files.
2. Do not create chip/badge visuals by hand in feature files.
3. Do not choose ad hoc background opacity in feature files.
4. Do not add a rounded background only to create visual grouping; use spacing or dividers first.
5. Do not nest card-like surfaces unless there is a clear structural reason.
6. Feature `Style` and `Layout` enums may define widths and layout constraints, but not button/surface/chip visual recipes.
7. If a new visual variant is needed, add it to the shared component deliberately.

## Definition of Done

This refactor is done when:

- Settings UI has no direct local button backgrounds except inside shared components.
- All interactive controls use shared `SettingsButton`, native macOS controls, or a documented exception.
- All metadata badges/tags use shared `SettingsChip`.
- All custom fields use shared `SettingsField`.
- All custom surfaces use shared `SettingsSurface` or existing `SettingsCardHelpers` internally rewritten to use it.
- Local feature style enums contain layout only.
- `rg "Button\\(" Muse/UI/Settings` mostly points to shared components or feature call sites using shared styles, not hand-built style chains.
- Visual review passes on Modes, Asset Library, Model, Vocabulary, General, and Sidebar.

## Open Decisions

These should be decided before broad migration:

1. Should informational chips use the same `28` height as buttons, or a smaller metadata height such as `22`?
2. Should toolbar segmented controls keep an outer track, or should standalone buttons be preferred unless selection is mutually exclusive?
3. Should model name chips like `DeepSeek` be visually quieter than buttons, or should they align to the same height for rhythm?
4. Should all button labels use one font size, or should toolbar use a slightly smaller size?
5. Which current nested panels are structural enough to keep?

