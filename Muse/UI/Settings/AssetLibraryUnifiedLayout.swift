import SwiftUI

struct AssetLibrarySplitPanel<Navigation: View, Detail: View>: View {
    @ViewBuilder let navigation: () -> Navigation
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        // 两张独立白卡 + 间隙（2026-06-13 用户拍板）：照搬常用词替换规则页结构——
        // 左导航/右详情各自是白卡,靠明度浮在暖背景上,不再连体靠「左暖右白」分栏
        HStack(alignment: .top, spacing: AssetLibraryStyle.sectionSpacing) {
            navigation()
                .frame(width: AssetLibraryStyle.navigationWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(TF.settingsCard)
                .clipShape(RoundedRectangle(cornerRadius: AssetLibraryStyle.innerPanelCornerRadius, style: .continuous))

            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TF.settingsCard)
                .clipShape(RoundedRectangle(cornerRadius: AssetLibraryStyle.innerPanelCornerRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 搜索框位置：低频操作沉底不占黄金位（2026-07 大梁老师）
enum AssetLibraryNavigationSearchPosition {
    case top
    case bottom
    case hidden
}

struct AssetLibraryNavigationPanel<Content: View>: View {
    @Binding var query: String
    let prompt: String
    var searchPosition: AssetLibraryNavigationSearchPosition = .top
    /// 沉底的低频操作行（如待确认页的「清空全部」）
    var bottomAccessory: AnyView?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AssetLibraryStyle.navigationSearchListSpacing) {
            if searchPosition == .top {
                AssetLibrarySearchField(text: $query, prompt: prompt)
                    .padding(.horizontal, AssetLibraryStyle.navigationHorizontalPadding)
                    .padding(.top, AssetLibraryStyle.navigationTopPadding)
            } else {
                Color.clear.frame(height: 1)
                    .padding(.top, AssetLibraryStyle.navigationTopPadding - AssetLibraryStyle.navigationSearchListSpacing)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: AssetLibraryStyle.navigationGroupSpacing) {
                    content()
                }
                .padding(.horizontal, AssetLibraryStyle.navigationHorizontalPadding)
                .padding(.bottom, SettingsScrollFade.contentPadding)
            }
            .settingsThinScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .settingsBottomScrollFade(color: TF.settingsCard)

            // 沉底控件与右侧详情底部按钮行中心对齐（2026-07 大梁老师）：
            // 右侧按钮中心距面板底 = discoverPanelPadding(12) + detailFooterMinHeight(38)/2 = 31；
            // 左栏控件高 28，底距取 31 - 14 = 17
            if searchPosition == .bottom {
                // 底色深一档：让用户一眼看出这是可输入的搜索区
                AssetLibrarySearchField(text: $query, prompt: prompt, fill: TF.settingsDropdownTriggerFill)
                    .frame(height: 28)
                    .padding(.horizontal, AssetLibraryStyle.navigationHorizontalPadding)
                    .padding(.bottom, 17)
            }

            if let bottomAccessory {
                bottomAccessory
                    .frame(height: 28)
                    .padding(.horizontal, AssetLibraryStyle.navigationHorizontalPadding)
                    .padding(.bottom, 17)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AssetLibraryGroupHeaderRow: View {
    let type: LanguageAssetType
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        SettingsSelectableRow(
            isSelected: isSelected,
            minHeight: TF.settingsControlHeight,
            verticalPadding: 5,
            action: action
        ) {
            HStack(spacing: 6) {
                Circle()
                    .fill(type.settingsAccentColor)
                    .frame(width: 5, height: 5)
                Text(type.settingsDisplayTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .foregroundStyle(TF.settingsTextTertiary)
                Image(systemName: "chevron.right")
                    .font(TF.settingsFontIconSmall)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(width: 10)
                    .rotationEffect(.degrees(isSelected ? 90 : 0))
            }
            .font(TF.settingsFontBody)
            .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextTertiary)
        }
    }
}

struct AssetLibraryCompactItemRow: View {
    let title: String
    let grade: LanguageAssetGrade?
    let isSelected: Bool
    /// 最近一次提炼产出的标识点（改造方案 #8）
    var isNew: Bool = false
    let action: () -> Void

    var body: some View {
        SettingsSelectableRow(
            isSelected: isSelected,
            minHeight: AssetLibraryStyle.compactItemMinHeight,
            verticalPadding: 6,
            action: action
        ) {
            HStack(alignment: .top, spacing: 6) {
                if isNew {
                    Circle()
                        .fill(TF.amber)
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                        .help(L("本次提炼新产出", "New from last run"))
                }

                Text(title)
                    .font(TF.settingsFontCaption)
                    .lineLimit(2)
                    .lineSpacing(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let grade {
                    AssetLibraryGradeBadge(grade: grade, style: .compact)
                }
            }
            .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
        }
    }
}

struct AssetLibraryDetailPane<Footer: View>: View {
    let accentColor: Color
    let metadata: String
    let grade: LanguageAssetGrade?
    let title: String
    let bodyText: String
    let tags: [String]
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AssetLibraryDetailHeader(
                accentColor: accentColor,
                metadata: metadata,
                grade: grade
            )
            .frame(height: AssetLibraryStyle.detailHeaderHeight, alignment: .center)
            .padding(.bottom, AssetLibraryStyle.detailSectionSpacing)

            Text(title)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsText)
                .lineLimit(2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: AssetLibraryStyle.detailTitleHeight, alignment: .topLeading)

            bodyScroll
                .padding(.top, AssetLibraryStyle.detailSectionSpacing)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            bottomInfo
        }
        .padding(.top, AssetLibraryStyle.detailTopPadding)
        .padding(.leading, AssetLibraryStyle.detailLeadingPadding)
        .padding(.trailing, AssetLibraryStyle.discoverPanelPadding)
        .padding(.bottom, AssetLibraryStyle.discoverPanelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var bodyScroll: some View {
        ScrollView(showsIndicators: false) {
            Text(bodyText)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsText)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, SettingsScrollFade.contentPadding)
        }
        .settingsThinScrollIndicators()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsBottomScrollFade(color: TF.settingsCard)
    }

    private var bottomInfo: some View {
        VStack(alignment: .leading, spacing: AssetLibraryStyle.detailFooterTopPadding) {
            if !tags.isEmpty {
                Text(tags.prefix(5).joined(separator: " · "))
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer()
                .frame(maxWidth: .infinity, minHeight: AssetLibraryStyle.detailFooterMinHeight, alignment: .center)
        }
        .padding(.top, AssetLibraryStyle.detailFooterTopPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TF.settingsStroke.opacity(0.55))
                .frame(height: 1)
        }
    }
}

struct AssetLibraryDetailHeader: View {
    let accentColor: Color
    let metadata: String
    let grade: LanguageAssetGrade?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(accentColor)
                .frame(width: 5, height: 5)
            Text(metadata)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
            Spacer(minLength: 0)
            if let grade {
                AssetLibraryGradeBadge(grade: grade, style: .detail)
            }
        }
    }
}

struct AssetLibraryGradeBadge: View {
    enum BadgeStyle {
        case compact
        case detail
    }

    let grade: LanguageAssetGrade
    let style: BadgeStyle

    private var color: Color {
        switch grade {
        case .a:
            return TF.settingsAccentBlue
        case .b:
            return TF.settingsAccentAmber
        }
    }

    var body: some View {
        Text(grade.rawValue)
            .font(style == .compact ? TF.settingsFontCaption : TF.settingsFontMetadata)
            .foregroundStyle(color)
            .frame(minWidth: style == .compact ? 14 : 20, minHeight: style == .compact ? 16 : 18)
            .background(
                RoundedRectangle(cornerRadius: AssetLibraryStyle.controlCornerRadius)
                    .fill(color.opacity(0.12))
            )
    }
}
