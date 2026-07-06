import SwiftUI

struct VocabularyBuiltInFooter: View {
    let summary: String
    let onOpenBuiltInFile: () -> Void
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)

            footerTextAction(L("打开内置文件", "Open built-in file"), action: onOpenBuiltInFile)
            footerTextAction(L("重新加载", "Reload"), action: onReload)

            Spacer(minLength: 0)
        }
    }
}

private extension VocabularyBuiltInFooter {
    func footerTextAction(_ title: String, action: @escaping () -> Void) -> some View {
        SettingsLinkButton(title, action: action)
    }
}
