import SwiftUI

struct AssetLibraryToolbar: View {
    @Binding var selectedView: PurifierView
    let isExtracting: Bool
    let canExtract: Bool
    let onExtract: () -> Void
    let onCancelExtraction: () -> Void

    private let horizontalPadding: CGFloat = 12
    private let controlSpacing: CGFloat = 10
    // 与配方页「新建」同款窄按钮预留宽（2026-07 大梁老师：提炼按钮太宽）
    private let extractionButtonWidth: CGFloat = 56
    // 2026-07 重构批三：四区(提炼/待确认/资产库/配方)需要更宽的切换器
    private let maximumSwitchWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width - horizontalPadding * 2, 0)
            let contentHeight = max(geometry.size.height - 16, 0)
            let reservedActionWidth = extractionButtonWidth + controlSpacing
            let availableSwitchWidth = max(
                contentWidth - reservedActionWidth,
                0
            )
            let switchWidth = min(maximumSwitchWidth, availableSwitchWidth)

            HStack(alignment: .center, spacing: controlSpacing) {
                viewSwitch(width: switchWidth)

                Spacer(minLength: 0)

                extractionButton
            }
            .frame(width: contentWidth, height: contentHeight, alignment: .center)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: AssetLibraryStyle.panelCornerRadius)
                .fill(AssetLibraryStyle.shellFill)
        )
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
        SettingsSwitchGroup(width: width) {
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
