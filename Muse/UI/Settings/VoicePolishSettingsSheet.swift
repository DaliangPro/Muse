import SwiftUI

/// 兼容旧调用方的薄包装。Voice Polish 的唯一编辑内容由一级设置页承载，
/// 避免弹窗与一级页分别维护 Prompt、术语或学习开关。
struct VoicePolishSettingsSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("语音润色设置", "Voice Polish Settings"))
                        .font(TF.settingsFontSectionTitle)
                        .foregroundStyle(TF.settingsText)
                    Text(L(
                        "这些设置与侧栏中的“语音润色”一级页面完全一致。",
                        "These are the same settings shown on the top-level Voice Polish page."
                    ))
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                }
                Spacer(minLength: 8)
                SettingsIconButton(
                    systemName: "xmark",
                    accessibilityLabel: L("关闭", "Close"),
                    action: onClose
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.35)

            ScrollView(showsIndicators: false) {
                VoicePolishSettingsTab(showsIntroduction: false)
                    .padding(18)
            }
            .settingsThinScrollIndicators()
        }
        .frame(width: 600, height: 720)
        .background(TF.settingsCanvas)
    }
}
