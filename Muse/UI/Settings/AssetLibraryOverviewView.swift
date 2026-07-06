import SwiftUI

struct AssetLibraryOverviewView: View {
    let panelHeight: CGFloat
    let assets: [LanguageAsset]
    let pendingCandidates: [LanguageAssetCandidateRecord]
    let isExtracting: Bool
    let extractionProgressPhase: AssetExtractionProgressStage
    let onShowCandidates: () -> Void
    let onShowLibrary: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AssetLibraryStyle.sectionSpacing) {
                if isExtracting {
                    AssetExtractionProgressBanner(stage: extractionProgressPhase)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                metricsRow
                middlePanels
                recentAssetsPanel
            }
            .padding(.bottom, SettingsScrollFade.contentPadding)
            .frame(minHeight: panelHeight, alignment: .topLeading)
        }
        .settingsThinScrollIndicators()
        .settingsBottomScrollFade(color: TF.settingsBg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension AssetLibraryOverviewView {
    var creatorAssets: [LanguageAsset] {
        AssetLibraryAssetFilters.creatorAssets(from: assets)
    }

    var gradeACandidateCount: Int {
        pendingCandidates.filter { $0.grade == .a }.count
    }

    var recentAssets: [LanguageAsset] {
        creatorAssets.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var typeRows: [(type: LanguageAssetType, count: Int)] {
        let counts = Dictionary(grouping: creatorAssets, by: \.assetType).mapValues(\.count)
        return Array(LanguageAssetType.creatorCases.compactMap { type in
            guard let count = counts[type], count > 0 else { return nil }
            return (type, count)
        }.prefix(5))
    }

    var metricsRow: some View {
        HStack(alignment: .top, spacing: AssetLibraryStyle.sectionSpacing) {
            OverviewMetricCard(
                label: L("正式资产", "Saved assets"),
                value: "\(creatorAssets.count)",
                unit: L("条", "items"),
                color: TF.settingsAccentGreen,
                action: onShowLibrary
            )

            OverviewMetricCard(
                label: L("待审候选", "Pending"),
                value: "\(pendingCandidates.count)",
                unit: L("条", "items"),
                color: TF.settingsAccentBlue,
                action: onShowCandidates
            )

            OverviewMetricCard(
                label: L("建议入库", "Ready to save"),
                value: "\(gradeACandidateCount)",
                unit: L("条", "items"),
                color: TF.settingsAccentAmber,
                action: onShowCandidates
            )
        }
        .frame(height: 76)
    }

    var middlePanels: some View {
        HStack(alignment: .top, spacing: AssetLibraryStyle.sectionSpacing) {
            overviewPanel(title: L("资产类型分布", "Asset distribution")) {
                if typeRows.isEmpty {
                    emptyText(L("暂无正式资产", "No saved assets yet"))
                } else {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(typeRows, id: \.type) { row in
                            distributionRow(type: row.type, count: row.count)
                        }
                    }
                }
            }

            overviewPanel(title: L("待处理状态", "Review status")) {
                reviewStatusContent
            }
        }
        .frame(height: 196)
    }

    var reviewStatusContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("可入库候选", "Ready candidates"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)

                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(gradeACandidateCount)")
                            .font(TF.settingsFontMetric)
                            .foregroundStyle(TF.settingsAccentGreen)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text(L("条", "items"))
                            .font(TF.settingsFontBody)
                            .foregroundStyle(TF.settingsTextTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(readyRateText)
                    .font(TF.settingsFontBodyStrong)
                    .foregroundStyle(TF.settingsAccentGreen)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            ProgressBar(
                value: gradeACandidateCount,
                maxValue: max(pendingCandidates.count, 1),
                color: TF.settingsAccentGreen
            )

            HStack(spacing: 8) {
                statusPill(label: L("待审总数", "Pending"), value: pendingCandidates.count, color: TF.settingsAccentBlue)
                statusPill(label: L("已入库", "Saved"), value: creatorAssets.count, color: TF.settingsAccentGreen)
            }

            Text(L("绿色进度表示可入库候选占待审池比例", "Green progress shows ready share of pending candidates"))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var recentAssetsPanel: some View {
        overviewPanel(
            title: L("最近沉淀资产", "Recent assets"),
            actionTitle: L("进入资产库", "Open library"),
            action: onShowLibrary
        ) {
            if recentAssets.isEmpty {
                emptyText(L("暂无正式资产", "No saved assets yet"))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentAssets.prefix(6))) { asset in
                        recentAssetRow(asset)
                    }
                }
            }
        }
        .frame(minHeight: recentAssetsPanelMinHeight, alignment: .topLeading)
    }

    var recentAssetsPanelMinHeight: CGFloat {
        let progressHeight: CGFloat = isExtracting ? 50 : 0
        let visibleSectionCount: CGFloat = isExtracting ? 4 : 3
        let spacingHeight = max(visibleSectionCount - 1, 0) * AssetLibraryStyle.sectionSpacing
        let fixedHeight = progressHeight + 76 + 196 + spacingHeight + SettingsScrollFade.contentPadding
        return max(244, panelHeight - fixedHeight)
    }

    func overviewPanel<Content: View>(
        title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(TF.settingsFontBodyStrong)
                    .foregroundStyle(TF.settingsText)

                Spacer(minLength: 8)

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(TF.settingsFontMetadata)
                            .foregroundStyle(TF.settingsTextTertiary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 14)

            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(AssetLibraryStyle.discoverPanelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AssetLibraryStyle.panelCornerRadius, style: .continuous)
                .fill(AssetLibraryStyle.shellFill)
        )
    }

    func distributionRow(type: LanguageAssetType, count: Int) -> some View {
        let maxCount = max(typeRows.map(\.count).max() ?? 1, 1)

        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(type.settingsAccentColor)
                .frame(width: 6, height: 6)
            Text(type.settingsDisplayTitle)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextSecondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)

            ProgressBar(value: count, maxValue: maxCount, color: type.settingsAccentColor)

            Text("\(count) 条")
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    var readyRateText: String {
        guard pendingCandidates.count > 0 else { return "0%" }
        let rate = Double(gradeACandidateCount) / Double(pendingCandidates.count)
        return "\(Int((rate * 100).rounded()))%"
    }

    func statusPill(label: String, value: Int, color: Color) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextSecondary)
                .lineLimit(1)

            Text("\(value)")
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius, style: .continuous)
                .fill(TF.settingsSecondaryActionFill)
        )
    }

    func recentAssetRow(_ asset: LanguageAsset) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(asset.assetType.settingsAccentColor)
                .frame(width: 6, height: 6)

            Text(asset.assetType.settingsDisplayTitle)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)

            Text(asset.title ?? asset.content)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if let grade = asset.grade {
                AssetLibraryGradeBadge(grade: grade, style: .compact)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TF.settingsStroke.opacity(0.45))
                .frame(height: 1)
        }
    }

    func emptyText(_ value: String) -> some View {
        Text(value)
            .font(TF.settingsFontBody)
            .foregroundStyle(TF.settingsTextTertiary)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
    }

}

private struct OverviewMetricCard: View {
    let label: String
    let value: String
    let unit: String
    let color: Color
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cardContent
                }
                .buttonStyle(.plain)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(value)
                    .font(TF.settingsFontMetric)
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if !unit.isEmpty {
                    Text(unit)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                }
            }

        }
        .padding(GeneralSettingsStyle.surfaceSpacing)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: GeneralSettingsStyle.statCardCornerRadius, style: .continuous)
                .fill(TF.settingsStatCardBase)
                .overlay(
                    RoundedRectangle(cornerRadius: GeneralSettingsStyle.statCardCornerRadius, style: .continuous)
                        .fill(color.opacity(0.10))
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: GeneralSettingsStyle.statCardCornerRadius, style: .continuous))
    }
}

private struct ProgressBar: View {
    let value: Int
    let maxValue: Int
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = maxValue > 0 ? min(max(Double(value) / Double(maxValue), 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(TF.settingsStroke.opacity(0.42))
                Capsule()
                    .fill(color)
                    .frame(width: max(width * fraction, value > 0 ? 8 : 0))
            }
        }
        .frame(height: 8)
    }
}
