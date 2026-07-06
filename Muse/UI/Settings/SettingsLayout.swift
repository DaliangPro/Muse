import SwiftUI

enum SettingsLayout {
    static let windowContentHeight: CGFloat = 690
    static let windowMinimumContentWidth: CGFloat = 240
    static let windowMinimumContentHeight: CGFloat = windowContentHeight

    static let sidebarNavTopInset: CGFloat = 48
    /// 纯文字导航收窄（2026-06-11）：最长标题「概览与记录」约 68pt，112 足够并留余量；
    /// 设置浮层面板与此同宽，再窄会挤压面板内的开关行
    static let sidebarControlWidth: CGFloat = 112
    /// 导航左边距（2026-06-11 用户两轮调整后定稿：文字离左缘约 24pt）
    static let sidebarLeadingInset: CGFloat = 12
    static let sidebarTrailingInset: CGFloat = 12
    static let sidebarWidth: CGFloat = sidebarLeadingInset + sidebarControlWidth + sidebarTrailingInset
    static let dividerWidth: CGFloat = 1

    static let functionalAreaWidth: CGFloat = 600
    static let windowContentWidth: CGFloat = sidebarWidth + dividerWidth + functionalAreaWidth

    static let pageTopInset: CGFloat = TF.settingsPagePadding
    static let pageBottomInset: CGFloat = TF.settingsPagePadding
    static let pageLeadingInset: CGFloat = TF.settingsPagePadding
    static let pageTrailingInset: CGFloat = TF.settingsPagePadding

    static var pageInsets: EdgeInsets {
        EdgeInsets(
            top: pageTopInset,
            leading: pageLeadingInset,
            bottom: pageBottomInset,
            trailing: pageTrailingInset
        )
    }
}
