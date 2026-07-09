import AppKit
import SwiftUI

enum GeneralSettingsStyle {
    static let surfaceSpacing: CGFloat = TF.settingsInnerCardPadding
    static let componentSpacing: CGFloat = TF.settingsCardSpacing
    static let surfaceCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let sectionCardCornerRadius: CGFloat = surfaceCornerRadius
    static let sectionCardFillColor: Color = TF.settingsCardAlt
    static let sectionCardContentPadding: CGFloat = TF.settingsPrimaryCardPadding
    static let sectionTitleSpacing: CGFloat = componentSpacing
    static let statCardCornerRadius: CGFloat = surfaceCornerRadius
    static let recordRowVerticalPadding: CGFloat = 10
    static let recordColumnSpacing: CGFloat = TF.settingsCardSpacing
    static let recordInfoColumnWidth: CGFloat = 62
    static let recordActionButtonSize: CGFloat = 20
    // 光学对齐 metrics 专用字号，从不渲染（capHeight 计算），不并入字体 token
    static let recordActionIconFontSize: CGFloat = 8.5
    private static let recordBodyMetricsFont = TF.settingsNSFontReading
    private static let recordActionMetricsFont = NSFont.systemFont(ofSize: recordActionIconFontSize, weight: .medium)
    static let recordActionRowOpticalOffset: CGFloat = -(
        ((recordActionButtonSize - recordActionMetricsFont.capHeight) / 2)
        - (recordBodyMetricsFont.ascender - recordBodyMetricsFont.capHeight)
    )
    static let overviewTopSpacing: CGFloat = componentSpacing
    static let overviewHistoryTopSpacing: CGFloat = componentSpacing
    /// 66 = 定稿的紧凑横幅高度（2026-07-08 大梁老师；原引用语料资产工具栏高度，
    /// 该工具栏后续去壳变矮，横幅高度就地固化不再联动）
    static let museBannerHeight: CGFloat = 66
    static let museBannerCornerRadius: CGFloat = surfaceCornerRadius
    static let museBannerHorizontalPadding: CGFloat = surfaceSpacing
    static let museBannerVerticalPadding: CGFloat = surfaceSpacing
    static let museBannerStatusTopPadding: CGFloat = 8
    static let museBannerStatusTrailingPadding: CGFloat = museBannerHorizontalPadding
    static let museBannerStatusFont = TF.settingsFontCaption
    static let recordBodyLineSpacing: CGFloat = 2
}
