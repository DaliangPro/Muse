import SwiftUI

struct RecentHistoryRowView: View {
    let record: HistoryRecord
    let timeText: String
    let isCopied: Bool
    let copyAction: () -> Void
    let deleteAction: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: GeneralSettingsStyle.recordColumnSpacing) {
            Text(timeText)
                .font(TF.settingsFontMono)
                .monospacedDigit()
                .foregroundStyle(TF.settingsTextTertiary.opacity(isHovering ? 1.0 : 0.7))
                .lineLimit(1)
                .truncationMode(.tail)
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
