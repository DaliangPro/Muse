import SwiftUI

/// 关于页（2026-06-11 用户拍板卡片化）：沿用模型设置页的产品设计语言——
/// 灰底圆角卡片承载内容，行间靠间距分隔不再画横线
struct AboutTab: View, SettingsCardHelpers {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroupCard(
                L("关于", "About"),
                titleAccessory: AnyView(
                    SettingsBrandLogo(width: 84, lightOpacity: 0.72, darkOpacity: 0.76)
                        .padding(.leading, 4)
                ),
                expandVertically: false,
                cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
                headerBottomSpacing: 10,
                fillColor: ModelSettingsStyle.cardFillColor,
                showsBorder: false
            ) {
                Text(L("语音，流畅输入。面向 macOS 的原生语音输入工具。", "Voice to text, seamlessly. A native voice input tool for macOS."))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsGroupCard(
                L("版本信息", "Version Info"),
                expandVertically: false,
                cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
                headerBottomSpacing: 6,
                fillColor: ModelSettingsStyle.cardFillColor,
                showsBorder: false
            ) {
                VStack(spacing: 0) {
                    aboutRow(label: L("版本", "Version"), value: appVersion)
                    aboutRow(label: L("构建者", "Built by"), value: "Daliang")
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextSecondary)
            Spacer()
            Text(value)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsText)
        }
        .frame(height: 32)
    }
}
// MARK: - 实时预览入口（macOS专用）
#Preview("设置页面-浅色模式") {
    SettingsView()
        .frame(width: SettingsLayout.windowContentWidth, height: SettingsLayout.windowContentHeight)
        .preferredColorScheme(.light)
}

#Preview("设置页面-深色模式") {
    SettingsView()
        .frame(width: SettingsLayout.windowContentWidth, height: SettingsLayout.windowContentHeight)
        .preferredColorScheme(.dark)
}
