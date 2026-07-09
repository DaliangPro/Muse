import SwiftUI

struct AssetLibraryToolbar: View {
    @Binding var selectedView: PurifierView
    let isExtracting: Bool
    let canExtract: Bool
    let onExtract: () -> Void
    let onCancelExtraction: () -> Void

    private let controlSpacing: CGFloat = 10
    // 2026-07 重构批三：四区(提炼/待确认/资产库/配方)需要更宽的切换器
    private let switchWidth: CGFloat = 280

    // 2026-07-08 大梁老师：去掉背景壳，与常用词页顶部同款——裸排开关 + 右侧提炼按钮；
    // 省出的高度由下方面板吃掉（toolbarHeight 同步降为控件高）
    var body: some View {
        HStack(alignment: .center, spacing: controlSpacing) {
            viewSwitch(width: switchWidth)

            Spacer(minLength: 0)

            extractionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var extractionButton: some View {
        if isExtracting {
            SettingsTextButton(L("取消", "Cancel"), variant: .secondary, action: onCancelExtraction)
        } else {
            SettingsTextButton(L("提炼", "Extract"), variant: .primary, action: onExtract)
                .disabled(!canExtract)
                .opacity(!canExtract ? 0.72 : 1)
        }
    }

    private func viewSwitch(width: CGFloat) -> some View {
        SettingsSwitchGroup(width: width, height: SettingsControlSpec.actionHeight) {
            ForEach(PurifierView.visibleCases) { view in
                SettingsSwitchOption(
                    title: view.title,
                    isSelected: selectedView == view
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedView = view
                    }
                }
            }
        }
    }
}
