import SwiftUI

struct AssetLibraryDiscoverView: View {
    let panelHeight: CGFloat
    let isExtracting: Bool
    let extractionProgressPhase: AssetExtractionProgressStage
    @Binding var statusFilter: AssetCandidateStatusFilter
    let latestJob: AssetExtractionJob?
    @Binding var candidateQuery: String
    let candidates: [LanguageAssetCandidateRecord]
    let canClearPending: Bool
    @Binding var selectedCandidateType: LanguageAssetType?
    @Binding var selectedCandidateID: String?
    let selectedCandidate: LanguageAssetCandidateRecord?
    let displayDate: String?
    let onShowSources: (LanguageAssetCandidateRecord) -> Void
    let onUpdate: (LanguageAssetCandidateRecord) -> Void
    let onIgnore: (LanguageAssetCandidateRecord) -> Void
    let onSave: (LanguageAssetCandidateRecord) -> Void
    let onRestore: (LanguageAssetCandidateRecord) -> Void
    let onClearPending: () -> Void

    var body: some View {
        let progressHeight: CGFloat = isExtracting ? 50 + 8 : 0
        let headerHeight: CGFloat = 26 + 8
        let contentHeight = max(
            0,
            panelHeight - progressHeight - headerHeight
        )

        VStack(alignment: .leading, spacing: 8) {
            if isExtracting {
                AssetExtractionProgressBanner(stage: extractionProgressPhase)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 与上下两张卡片同缘左对齐（卡片贴页面左缘，此行不再额外缩进）
            discoverHeader
                .frame(height: 26)

            AssetLibrarySplitPanel {
                AssetCandidateGroupsPanel(
                    candidateQuery: $candidateQuery,
                    candidates: candidates,
                    latestJobID: recentJobID,
                    selectedCandidateType: $selectedCandidateType,
                    selectedCandidateID: $selectedCandidateID
                )
                    .frame(height: contentHeight, alignment: .topLeading)
            } detail: {
                candidateDetailPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: contentHeight, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: panelHeight, alignment: .topLeading)
        .clipped()
    }

    /// 状态筛选（待审/已忽略）+ 上次提炼时间。
    /// 时间文字与下方详情区内容左对齐（2026-06-12 用户拍板），不挨着切换按钮
    private var discoverHeader: some View {
        ZStack(alignment: .leading) {
            SettingsSwitchGroup(width: 132, height: 26) {
                ForEach(AssetCandidateStatusFilter.allCases) { filter in
                    SettingsSwitchOption(
                        title: filter.title,
                        isSelected: statusFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            statusFilter = filter
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let summaryText = latestJobSummary {
                Text(summaryText)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
                    .padding(.leading, AssetLibraryStyle.navigationWidth + AssetLibraryStyle.detailLeadingPadding)
            }

            if canClearPendingCandidates {
                SettingsTextButton(
                    L("清空", "Clear"),
                    variant: .danger,
                    controlSize: .compact,
                    onCanvas: true,
                    action: onClearPending
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var canClearPendingCandidates: Bool {
        statusFilter == .pending && canClearPending
    }

    /// 「新」点只在最近一次提炼完成后 24 小时内亮（2026-06-12 用户拍板），
    /// 过期自动消失，不让陈年产出顶着「新」标变成噪音
    private var recentJobID: String? {
        guard let job = latestJob,
              let finishedAt = job.finishedAt,
              Date().timeIntervalSince(finishedAt) < 24 * 3600
        else { return nil }
        return job.id
    }

    /// 只保留时间（2026-06-12 用户拍板）：候选分布摘要在 Job 记录里仍可查
    private var latestJobSummary: String? {
        guard let job = latestJob, let finishedAt = job.finishedAt else { return nil }
        let time = AssetLibraryDateFormatters.displayDateTime(finishedAt)
        return L("上次提炼 \(time)", "Last run \(time)")
    }

    private var candidateDetailPanel: some View {
        CandidateDetailPanel(
            candidate: selectedCandidate,
            displayDate: displayDate,
            isIgnoredView: statusFilter == .ignored,
            onShowSources: onShowSources,
            onUpdate: onUpdate,
            onIgnore: onIgnore,
            onSave: onSave,
            onRestore: onRestore
        )
    }
}
