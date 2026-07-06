import SwiftUI

enum AssetPromptRuleSelection: Hashable, Identifiable {
    case global
    case type(LanguageAssetType)

    var id: String {
        switch self {
        case .global:
            return "global"
        case .type(let type):
            return type.rawValue
        }
    }

    var type: LanguageAssetType? {
        switch self {
        case .global:
            return nil
        case .type(let type):
            return type
        }
    }

    var title: String {
        switch self {
        case .global:
            return L("全局规则", "Global")
        case .type(let type):
            return type.settingsDisplayTitle
        }
    }

    var accent: Color {
        switch self {
        case .global:
            return TF.settingsTextTertiary
        case .type(let type):
            return type.settingsAccentColor
        }
    }

    static var allOptions: [AssetPromptRuleSelection] {
        [.global] + LanguageAssetType.creatorCases.map { .type($0) }
    }
}

struct AssetPromptRulePickerControl: View {
    let selection: AssetPromptRuleSelection
    @Binding var isOpen: Bool
    let onSelect: (AssetPromptRuleSelection) -> Void

    @State private var triggerFrame = CGRect.zero
    @State private var popoverFrame = CGRect.zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            SettingsButton(
                variant: .secondary,
                width: AssetPromptRulePickerLayout.buttonWidth
            ) {
                isOpen.toggle()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(selection.accent)
                        .frame(width: 5, height: 5)

                    Text(selection.title)
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(TF.settingsFontIconMicro)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 8, height: 8)
                }
            }
            .settingsScreenFrame($triggerFrame)

            if isOpen {
                pickerPopover
                    .offset(y: SettingsControlSpec.actionHeight + 6)
                    .settingsScreenFrame($popoverFrame)
                    .zIndex(80)
            }
        }
        .frame(
            width: AssetPromptRulePickerLayout.buttonWidth,
            height: SettingsControlSpec.actionHeight,
            alignment: .topLeading
        )
        .zIndex(isOpen ? 80 : 0)
        .settingsDismissOnOutsideClick(
            isActive: isOpen,
            allowedFrames: [triggerFrame, popoverFrame]
        ) {
            isOpen = false
        }
        .onChange(of: isOpen) { _, newValue in
            if !newValue {
                popoverFrame = .zero
            }
        }
    }
}

private extension AssetPromptRulePickerControl {
    var pickerPopover: some View {
        SettingsPopupCard(width: AssetPromptRulePickerLayout.popoverWidth) {
            VStack(spacing: 3) {
                ForEach(AssetPromptRuleSelection.allOptions) { option in
                    AssetPromptRulePickerOptionRow(
                        option: option,
                        isActive: option == selection
                    ) {
                        onSelect(option)
                        isOpen = false
                    }
                }
            }
        }
    }
}

private struct AssetPromptRulePickerOptionRow: View {
    let option: AssetPromptRuleSelection
    let isActive: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        SettingsSelectableRow(
            isSelected: isActive || isHovered,
            minHeight: 30,
            verticalPadding: 0,
            action: onSelect
        ) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(option.accent)
                    .frame(width: 5, height: 5)
                    .opacity(isActive || isHovered ? 1 : 0.64)

                Text(option.title)
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(isActive || isHovered ? TF.settingsSelectionText : TF.settingsText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
        }
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
    }
}

private enum AssetPromptRulePickerLayout {
    static let buttonWidth: CGFloat = 128
    static let popoverWidth: CGFloat = 164
}
