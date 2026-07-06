import SwiftUI

/// 纯文字导航行（2026-06-11 用户拍板去图标）：
/// 选中态 = 贴侧栏左缘的琥珀短竖线 + 行微亮，悬停只提字色。
struct SettingsSidebarNavItem: View {
    let tab: SettingsTab
    let isActive: Bool
    let isHovered: Bool
    let showBadge: Bool
    let textLeadingInset: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let controlWidth: CGFloat
    /// 琥珀竖线贴侧栏最左缘（相对行起点的负偏移）
    let accentLineLeadingOffset: CGFloat
    let action: () -> Void
    let onHoverActive: () -> Void

    private var foreground: Color {
        if isActive {
            return TF.settingsSidebarSelectionText
        }
        if isHovered {
            return TF.settingsSidebarHoverText
        }
        return TF.settingsSidebarText
    }

    private var rowFill: Color {
        if isActive {
            return TF.settingsSidebarActiveFill
        }
        if isHovered {
            return TF.settingsSidebarGlassHoverFill
        }
        return .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return SettingsPlainButton(action: action) {
            HStack(spacing: 0) {
                // 不做自动缩字（2026-06-12 用户拍板：各项字号必须一致）；
                // 文案长度由 SettingsTab.displayName 保证放得下
                Text(tab.displayName)
                    .font(SettingsSidebarLayout.navItemTextFont)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Spacer()
                if showBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, textLeadingInset)
            .padding(.trailing, 12)
            .frame(height: SettingsSidebarLayout.navItemHeight)
            .background {
                shape.fill(rowFill)
            }
            .overlay(alignment: .leading) {
                // 墨色一体的选中指示：一道琥珀短竖线贴侧栏最左缘
                if isActive {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(TF.amber)
                        .frame(width: 2, height: 14)
                        .offset(x: accentLineLeadingOffset)
                }
            }
            .contentShape(shape)
        }
        .frame(width: controlWidth, height: SettingsSidebarLayout.navItemHeight, alignment: .leading)
        .onHover { isHovering in
            guard isHovering else { return }
            onHoverActive()
        }
        .onContinuousHover { phase in
            if case .active = phase {
                onHoverActive()
            }
        }
    }
}

