import AppKit
import SwiftUI

struct ModeDetailInner: View, SettingsCardHelpers {
    let mode: ProcessingMode
    let onSave: (ProcessingMode) -> Void

    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ModeSettingsLayout.modeWorkbenchGap) {
            if isDirectMode {
                // 直出模式不走文本处理，Prompt 与试跑无意义（2026-06-12 用户拍板）
                directModeNotice
            } else {
                modePromptBlock
                // 2026-06-12 用户拍板方案 A：撤掉写死的假「输出示例」，
                // 挂上真试跑——用当前编辑中的 Prompt 实调模型看输出
                ModeTrialCard(
                    mode: mode,
                    name: mode.name,
                    processingLabel: mode.processingLabel,
                    prompt: prompt,
                    hotkeyStyle: mode.hotkeyStyle
                )
            }
        }
        .frame(width: ModeSettingsLayout.modeWorkspaceWidth, alignment: .topLeading)
        .frame(minHeight: ModeSettingsLayout.modeWorkbenchHeight, alignment: .topLeading)
        .onAppear(perform: syncFields)
        .onChange(of: mode.id) { _, _ in
            syncFields()
        }
    }

    private var isDirectMode: Bool {
        mode.id == ProcessingMode.directId
    }

    private var directModeNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("直出模式", "Direct Mode"))
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsTextTertiary)

            Text(L("识别结果原样输出，不经过任何文本处理，因此无需配置 Prompt，也没有输出差异可供示例。", "Recognized text is inserted as-is with no post-processing, so there is no prompt to configure and nothing to preview."))
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextSecondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ModeSettingsLayout.modeGutter)
        .frame(width: ModeSettingsLayout.modeWorkspaceWidth, alignment: .topLeading)
        .background {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .fill(modeFieldFill)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .stroke(modeFieldStroke, lineWidth: 1)
        }
    }
}

private extension ModeDetailInner {
    var modePromptBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            modePromptHeader

            modePromptEditor
        }
        // Prompt 块定高 40%（2026-06-13 用户拍板重构）：配置低频、克制占高,
        // 剩余 60% 归下方测试区(输入/输出左右对照、各撑满)
        .frame(
            width: ModeSettingsLayout.modeWorkspaceWidth,
            height: ModeSettingsLayout.modePromptBlockHeight,
            alignment: .topLeading
        )
        .background {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .fill(modeFieldFill)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: ModeSettingsLayout.modeFieldCornerRadius,
                style: .continuous
            )
            .stroke(modeFieldStroke, lineWidth: 1)
        }
    }

    var modePromptHeader: some View {
        HStack(spacing: ModeSettingsLayout.modePromptActionSpacing) {
            Text("Prompt")
                .font(TF.settingsFontBodyLarge)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)

            Spacer(minLength: 12)

            SettingsIconButton(
                systemName: "arrow.counterclockwise",
                accessibilityLabel: L("恢复默认", "Restore default"),
                variant: .ghost,
                size: ModeSettingsLayout.modePromptRestoreButtonSize
            ) {
                restoreDefaults()
            }

            modeHeaderButton(L("保存修改", "Save"), isPrimary: true) {
                saveChanges()
            }
        }
        .padding(.horizontal, ModeSettingsLayout.modeGutter)
        .padding(.vertical, 12)
    }

    var modePromptEditor: some View {
        ZStack(alignment: .topLeading) {
            ModeTextArea(
                text: $prompt,
                isEditable: true
            )
            .settingsVerticalScrollFade(color: modeInputAreaFill)

            if shouldShowPromptPlaceholder {
                Text(L("在这里编辑当前模式的 Prompt...", "Edit the current mode prompt here..."))
                    .font(TF.settingsFontReading)
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.58))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .padding(.leading, 10)
                    .padding(.top, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, ModeSettingsLayout.modeGutter)
        .padding(.bottom, ModeSettingsLayout.modePromptVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var modeFieldFill: Color {
        TF.settingsCardAlt
    }

    /// Prompt 输入框上下渐隐用的底色（与灰块填充一致，渐变到它即"文字淡出"）
    var modeInputAreaFill: Color {
        TF.settingsDropdownTriggerFill
    }

    var modeFieldStroke: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.isDark {
                return NSColor.white.withAlphaComponent(0.035)
            }
            return NSColor(
                srgbRed: 25 / 255,
                green: 31 / 255,
                blue: 41 / 255,
                alpha: 0.045
            )
        }))
    }

    var shouldShowPromptPlaceholder: Bool {
        mode.id != ProcessingMode.directId
            && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var usesLegacyNewModePromptTemplate: Bool {
        !mode.isBuiltin
            && ["新模式", "New Mode", L("新模式", "New Mode")].contains(mode.name)
            && mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == "{text}"
    }

    func modeHeaderButton(
        _ title: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SettingsTextButton(
            title,
            variant: isPrimary ? .primary : .secondary,
            width: ModeSettingsLayout.modePromptSaveButtonWidth,
            action: action
        )
    }

    func restoreDefaults() {
        guard let defaultMode = ProcessingMode.defaults.first(where: { $0.id == mode.id })
            ?? ProcessingMode.defaults.first(where: { $0.name == mode.name })
        else {
            return
        }

        prompt = defaultMode.prompt
    }

    func saveChanges() {
        var updated = mode
        updated.prompt = prompt
        onSave(updated)
    }

    func syncFields() {
        prompt = usesLegacyNewModePromptTemplate ? "" : mode.prompt
    }
}
