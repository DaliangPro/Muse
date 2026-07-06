import SwiftUI

extension VocabularyTab {
    func vocabularyDivider() -> some View {
        Rectangle()
            .fill(TF.settingsPopoverEdge.opacity(0.55))
            .frame(height: 1)
    }

    func vocabularyFlexibleTextField(
        prompt: String,
        text: Binding<String>
    ) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(TF.settingsTextTertiary))
            .textFieldStyle(.plain)
            .font(TF.settingsFontControl)
            .foregroundStyle(TF.settingsText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: SettingsControlSpec.actionHeight, maxHeight: SettingsControlSpec.actionHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                    .fill(TF.settingsSecondaryActionFill)
            )
    }

}
