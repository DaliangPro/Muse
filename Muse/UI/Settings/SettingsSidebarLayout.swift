import SwiftUI

enum SettingsSidebarLayout {
    static let navTopInset: CGFloat = SettingsLayout.sidebarNavTopInset
    static let controlWidth: CGFloat = SettingsLayout.sidebarControlWidth
    static let leadingInset: CGFloat = SettingsLayout.sidebarLeadingInset
    static let navItemSpacing: CGFloat = 2
    static let navTextLeadingInset: CGFloat = 12
    static let navItemHeight: CGFloat = 30
    static let navItemVerticalPadding: CGFloat = 0
    static let navItemCornerRadius: CGFloat = 8
    static let navItemTextFont = TF.settingsFontNavigation

    static let settingsLeadingInset: CGFloat = SettingsLayout.sidebarLeadingInset
    static let settingsBottomInset: CGFloat = 12
    static let settingsControlWidth: CGFloat = SettingsLayout.sidebarControlWidth
    static let settingsControlHeight: CGFloat = navItemHeight
    static let settingsControlHorizontalPadding: CGFloat = navTextLeadingInset
    static let settingsCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let settingsPanelHorizontalInset: CGFloat = 8
    static let settingsPanelTopInset: CGFloat = 8
    static let settingsPanelBottomInset: CGFloat = 8
    static let settingsPanelTextColor = TF.settingsTextSecondary

    /// 重构面板（2026-07-06 大梁老师）：点选图标按钮的行高与行距（外观 / 语言 / 三开关共 5 行）
    static let settingsPanelOptionHeight: CGFloat = 26
    static let settingsPanelOptionSpacing: CGFloat = 5
    static let settingsPanelOptionRowCount: CGFloat = 5

    static var settingsPanelHeight: CGFloat {
        settingsPanelTopInset
            + settingsPanelBottomInset
            + settingsPanelOptionHeight * settingsPanelOptionRowCount
            + settingsPanelOptionSpacing * settingsPanelOptionRowCount
            + 1 // 上下两区之间的分隔线
    }

    // 红绿灯保持在系统惯例的 16pt，不跟着导航边距走
    private static let trafficLightOpticalInset: CGFloat = 4
    static let trafficLightTopInset: CGFloat = trafficLightLeadingInset

    static var trafficLightLeadingInset: CGFloat {
        leadingInset + trafficLightOpticalInset
    }
}
