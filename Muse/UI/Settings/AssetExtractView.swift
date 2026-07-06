import SwiftUI

/// 提炼页（2026-07 重构批三）：语料池状态 + 发起提炼 + 最近批次。
/// 说话即积累，提炼按需发起；产物经两段式筛选后进「待确认」。
struct AssetExtractView: View {
    let totalRecordCount: Int
    let savedCount: Int
    let pendingCount: Int
    let isExtracting: Bool
    let extractionProgressPhase: AssetExtractionProgressStage
    let recentRuns: [ExtractionRun]
    let formattedDate: (Date) -> String
    let onOpenPending: () -> Void
    let onDeleteRun: (ExtractionRun) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: AssetLibraryStyle.sectionSpacing) {
            corpusCard

            recentRunsCard
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension AssetExtractView {
    // MARK: - 语料池状态 + 主动作

    var corpusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 提炼进行中才显示阶段指示；平时不占行
            if isExtracting {
                HStack(spacing: 7) {
                    Spacer(minLength: 0)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.68)
                    Text(extractionProgressPhase.title)
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
            }

            // 与「概览与记录」完全同构：三张彩卡直接并排裸放（无外层白卡容器），
            // 宽度天然与下方卡片对齐（2026-07 大梁老师）
            HStack(alignment: .top, spacing: GeneralSettingsStyle.componentSpacing) {
                corpusStat(value: totalRecordCount, label: L("累计语料", "Total"), color: TF.settingsAccentGreen)
                corpusStat(value: savedCount, label: L("已入库", "Saved"), color: TF.settingsAccentBlue)
                corpusStatButton(value: pendingCount, label: L("待确认", "Pending"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 统计彩卡：与「概览与记录」页统计卡同款设计语言(白底染 accent + 数字染色 + 柔投影)
    func corpusStat(value: Int, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)

            Spacer(minLength: 0)

            Text("\(value)")
                .font(TF.settingsFontMetric)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
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
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 10, x: 0, y: 2)
        )
    }

    /// 待确认统计彩卡：琥珀(对齐概览第三卡)，可点直达待确认页
    func corpusStatButton(value: Int, label: String) -> some View {
        Button(action: onOpenPending) {
            corpusStat(value: value, label: label, color: TF.settingsAccentAmber)
                .contentShape(RoundedRectangle(cornerRadius: GeneralSettingsStyle.statCardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 最近提炼批次

    var recentRunsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("最近提炼", "Recent runs"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)

            if recentRuns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("还没有提炼记录", "No runs yet"))
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextSecondary)
                    Text(L("点右上角「提炼」选配方和范围。产物会先宽提找全、再按配方标准严审，最后进「待确认」由你拍板。", "Hit Extract (top right) to pick a recipe and range. Results are widened, strictly reviewed, then wait for your decision."))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(recentRuns.enumerated()), id: \.element.id) { index, run in
                            runRow(run)
                            if index < recentRuns.count - 1 {
                                Rectangle()
                                    .fill(TF.settingsStroke.opacity(0.14))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.bottom, SettingsScrollFade.contentPadding)
                }
                .settingsThinScrollIndicators()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .settingsBottomScrollFade(color: TF.settingsCard)
            }
        }
        .padding(AssetLibraryStyle.discoverPanelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TF.settingsCard)
        .clipShape(RoundedRectangle(cornerRadius: AssetLibraryStyle.innerPanelCornerRadius, style: .continuous))
    }

    func runRow(_ run: ExtractionRun) -> some View {
        ExtractRunRow(
            run: run,
            timeText: formattedDate(run.createdAt),
            onDelete: { onDeleteRun(run) }
        )
    }
}

/// 单行式提炼记录（2026-07 大梁老师）：配方名亮色、与描述同行同字号；
/// 删除键与「概览与记录」完全同款（行悬停提亮、按钮悬停变红）
private struct ExtractRunRow: View {
    let run: ExtractionRun
    let timeText: String
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(run.recipeName)
                .font(TF.settingsFontCaption)
                .foregroundStyle(isHovering ? TF.settingsText : TF.settingsTextSecondary)
                .lineLimit(1)
                .layoutPriority(1)

            Text("·")
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)

            Text(run.summary ?? run.errorMessage ?? "")
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary.opacity(isHovering ? 1.0 : 0.8))
                .lineLimit(1)
                .truncationMode(.tail)

            statusBadge

            Spacer(minLength: 8)

            Text(timeText)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)

            RecentHistoryActionIconButton(
                systemName: "xmark",
                accessibilityLabel: L("删除记录", "Delete run"),
                isDestructive: true,
                isRowHovering: isHovering,
                action: onDelete
            )
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch run.status {
        case .succeeded:
            EmptyView()
        case .failed:
            Text(L("失败", "Failed"))
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsAccentAmber)
        case .running, .queued:
            Text(L("进行中", "Running"))
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
        }
    }
}
