import SwiftUI

struct RecentHistoryRowView: View {
    let record: HistoryRecord
    let timeText: String
    let isCopied: Bool
    let isCorrected: Bool
    let copyAction: () -> Void
    let learnAction: (() -> Void)?
    let undoCorrectionAction: (() -> Void)?
    let deleteAction: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: GeneralSettingsStyle.recordColumnSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeText)
                    .font(TF.settingsFontMono)
                    .monospacedDigit()
                    .foregroundStyle(TF.settingsTextTertiary.opacity(isHovering ? 1.0 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isVoicePolishRecord {
                    Text(L("语音润色", "Voice Polish"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsAccentAmber)
                        .lineLimit(1)
                        .accessibilityLabel(L("语音润色记录", "Voice Polish record"))
                }
            }
            .frame(width: GeneralSettingsStyle.recordInfoColumnWidth, alignment: .leading)

            // 默认淡一档（与 Prompt 输入区同色），悬停整行提亮（2026-06-12 用户拍板）
            Text(record.finalText)
                .font(TF.settingsFontReading)
                .foregroundStyle(isHovering ? TF.settingsText : TF.settingsTextSecondary)
                .textSelection(.enabled)
                .lineSpacing(GeneralSettingsStyle.recordBodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 1) {
                RecentHistoryActionIconButton(
                    systemName: isCopied ? "checkmark" : "square.on.square",
                    accessibilityLabel: isCopied ? L("已复制", "Copied") : L("复制", "Copy"),
                    isDestructive: false,
                    isRowHovering: isHovering,
                    action: copyAction
                )

                if let learnAction {
                    SettingsTextButton(
                        isCorrected ? L("查看/编辑", "View/Edit") : L("纠正", "Correct"),
                        variant: isCorrected ? .success : .secondary,
                        controlSize: .compact,
                        minWidth: isCorrected ? 66 : 52,
                        action: learnAction
                    )
                    .help(isCorrected
                        ? L("查看或修改上次保存的纠正和学习授权", "View or edit the saved correction and learning permissions")
                        : L("纠正结果，并分别选择是否记住术语或学习表达习惯", "Correct the result and separately choose term memory or style learning"))
                    .accessibilityLabel(isCorrected
                        ? L("查看或编辑这条纠正", "View or edit this correction")
                        : L("纠正这条语音润色结果", "Correct this Voice Polish result"))
                }

                if let undoCorrectionAction {
                    RecentHistoryActionIconButton(
                        systemName: "arrow.uturn.backward",
                        accessibilityLabel: L("撤销这条学习记录", "Undo this learned correction"),
                        isDestructive: false,
                        isRowHovering: isHovering,
                        action: undoCorrectionAction
                    )
                }

                RecentHistoryActionIconButton(
                    systemName: "xmark",
                    accessibilityLabel: L("删除", "Delete"),
                    isDestructive: true,
                    isRowHovering: isHovering,
                    action: deleteAction
                )
            }
            .offset(y: GeneralSettingsStyle.recordActionRowOpticalOffset)
        }
        .padding(.vertical, GeneralSettingsStyle.recordRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var isVoicePolishRecord: Bool {
        record.status.hasPrefix("voice_polish_")
    }
}

// 供其他行式列表复用（提炼页最近提炼行的删除键与本页同款,2026-07）
struct RecentHistoryActionIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isDestructive: Bool
    let isRowHovering: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        // 纯图标、零背景（2026-06-20 大梁老师拍板）：融入识别记录块,不要 ghost 的矩形底;
        // 图标默认与左侧时间戳同色(三级文字、整行悬停提亮),悬停到按钮上才变绿/红
        Button(action: action) {
            Image(systemName: systemName)
                .font(TF.settingsFontIconBody)
                .foregroundStyle(iconColor)
                .frame(width: GeneralSettingsStyle.recordActionButtonSize, height: GeneralSettingsStyle.recordActionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var iconColor: Color {
        if isHovering {
            return isDestructive ? TF.settingsAccentRed : TF.settingsAccentGreen
        }
        // 与左侧时间戳完全同色：三级文字，整行悬停时提亮
        return TF.settingsTextTertiary.opacity(isRowHovering ? 1.0 : 0.7)
    }
}
