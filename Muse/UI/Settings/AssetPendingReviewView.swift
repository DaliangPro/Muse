import SwiftUI

/// 待确认页（2026-07 重构批三）：所有配方产物统一在此拍板——入库或抛弃。
/// 左栏按提炼批次分组，右栏详情带严审评分与判决理由（可审计「为什么留」）。
struct AssetPendingReviewView: View {
    @Binding var query: String
    @Binding var selectedResultID: String?
    let pendingResults: [ExtractionResult]
    /// 严审砍掉的产物：按批可翻砍单，可捞回（防错杀防黑箱，2026-07）
    let rejectedResults: [ExtractionResult]
    let runs: [ExtractionRun]
    let formattedDate: (Date) -> String
    let onShowSources: (ExtractionResult) -> Void
    let onSave: (ExtractionResult) -> Void
    let onDiscard: (ExtractionResult) -> Void
    let onSaveAll: ([ExtractionResult]) -> Void
    let onRestore: (ExtractionResult) -> Void
    let onDiscardAll: ([ExtractionResult]) -> Void

    @State private var expandedRejectedRunIDs: Set<String> = []
    @State private var isClearAllConfirmPresented = false

    var body: some View {
        AssetLibrarySplitPanel {
            navigationPanel
        } detail: {
            detailPanel
        }
        .confirmationDialog(
            L("清空全部 \(pendingResults.count) 条待确认？", "Discard all \(pendingResults.count) pending items?"),
            isPresented: $isClearAllConfirmPresented,
            titleVisibility: .visible
        ) {
            Button(L("清空", "Discard all"), role: .destructive) {
                onDiscardAll(pendingResults)
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("清空后可在提炼记录中重新提炼，已清空的内容不会进入资产库。", "Cleared items will not enter the library; you can re-extract later."))
        }
    }
}

private extension AssetPendingReviewView {
    struct RunGroup: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let results: [ExtractionResult]
        let rejected: [ExtractionResult]
    }

    func matchesQuery(_ result: ExtractionResult, _ trimmed: String) -> Bool {
        result.title.localizedCaseInsensitiveContains(trimmed)
            || result.content.localizedCaseInsensitiveContains(trimmed)
    }

    var searchedResults: [ExtractionResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pendingResults }
        return pendingResults.filter { matchesQuery($0, trimmed) }
    }

    var searchedRejected: [ExtractionResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rejectedResults }
        return rejectedResults.filter { matchesQuery($0, trimmed) }
    }

    var runGroups: [RunGroup] {
        let runByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        let rejectedByRun = Dictionary(grouping: searchedRejected, by: \.runID)
        var grouped = Dictionary(grouping: searchedResults, by: \.runID)
        // 只有砍单没有留存的批次也要显示(比如 30 天金句全砍那种)——否则用户只看到 0 条黑箱
        for runID in rejectedByRun.keys where grouped[runID] == nil {
            grouped[runID] = []
        }
        return grouped
            .map { runID, results -> RunGroup in
                let run = runByID[runID]
                let rejected = rejectedByRun[runID] ?? []
                let latest = (results + rejected).map(\.createdAt).max() ?? Date.distantPast
                return RunGroup(
                    id: runID,
                    title: run?.recipeName ?? L("提炼批次", "Run"),
                    subtitle: "\(formattedDate(run?.createdAt ?? latest)) · \(results.count)",
                    results: results.sorted { ($0.score ?? 0) > ($1.score ?? 0) },
                    rejected: rejected.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = (lhs.results + lhs.rejected).map(\.createdAt).max() ?? .distantPast
                let rhsDate = (rhs.results + rhs.rejected).map(\.createdAt).max() ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    var displayedResult: ExtractionResult? {
        if let selectedResultID {
            if let match = searchedResults.first(where: { $0.id == selectedResultID }) {
                return match
            }
            if let rejectedMatch = searchedRejected.first(where: { $0.id == selectedResultID }) {
                return rejectedMatch
            }
        }
        return runGroups.first?.results.first
    }

    var navigationPanel: some View {
        AssetLibraryNavigationPanel(
            query: $query,
            prompt: L("搜索待确认", "Search pending"),
            searchPosition: .hidden,
            bottomAccessory: pendingResults.isEmpty ? nil : AnyView(clearAllRow)
        ) {
            if runGroups.isEmpty {
                Text(L("没有待确认的产物", "Nothing to review"))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ForEach(runGroups) { group in
                    runGroupSection(group)
                }
            }
        }
    }

    /// 一键清空：沉底的标准按钮（带确认弹窗）——不占用户进来的第一视线
    var clearAllRow: some View {
        SettingsTextButton(
            L("清空全部 \(pendingResults.count) 条", "Clear all \(pendingResults.count)"),
            variant: .secondary
        ) {
            isClearAllConfirmPresented = true
        }
        .frame(maxWidth: .infinity)
    }

    func runGroupSection(_ group: RunGroup) -> some View {
        VStack(alignment: .leading, spacing: AssetLibraryStyle.navigationItemSpacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                Text(group.subtitle)
                    .font(TF.settingsFontMetadata)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)

            ForEach(group.results) { result in
                AssetLibraryCompactItemRow(
                    title: scorePrefixedTitle(result),
                    grade: nil,
                    isSelected: displayedResult?.id == result.id
                ) {
                    selectedResultID = result.id
                }
            }

            if !group.rejected.isEmpty {
                rejectedSection(group)
            }
        }
    }

    /// 砍单折叠区：严审砍掉的产物按批可翻、可捞回
    @ViewBuilder
    func rejectedSection(_ group: RunGroup) -> some View {
        let isExpanded = expandedRejectedRunIDs.contains(group.id)

        SettingsSelectableRow(
            isSelected: false,
            minHeight: TF.settingsControlHeight,
            verticalPadding: 4
        ) {
            if isExpanded {
                expandedRejectedRunIDs.remove(group.id)
            } else {
                expandedRejectedRunIDs.insert(group.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "xmark.bin")
                    .font(TF.settingsFontIconSmall)
                Text(L("严审砍掉 \(group.rejected.count) 条", "\(group.rejected.count) dropped"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(TF.settingsFontIconSmall)
                    .frame(width: 10)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(TF.settingsFontMetadata)
            .foregroundStyle(TF.settingsTextTertiary)
        }

        if isExpanded {
            ForEach(group.rejected) { result in
                AssetLibraryCompactItemRow(
                    title: scorePrefixedTitle(result),
                    grade: nil,
                    isSelected: displayedResult?.id == result.id
                ) {
                    selectedResultID = result.id
                }
                .opacity(0.62)
            }
        }
    }

    func scorePrefixedTitle(_ result: ExtractionResult) -> String {
        guard let score = result.score else { return result.title }
        return "\(Int(score)) · \(result.title)"
    }

    @ViewBuilder
    var detailPanel: some View {
        if let result = displayedResult {
            pendingDetail(result)
        } else {
            emptyDetail
        }
    }

    func pendingDetail(_ result: ExtractionResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AssetLibraryDetailHeader(
                accentColor: result.outputKind.settingsAccentColor,
                metadata: detailMetadata(for: result),
                grade: nil
            )
            .frame(height: AssetLibraryStyle.detailHeaderHeight, alignment: .center)
            .padding(.bottom, AssetLibraryStyle.detailSectionSpacing)

            Text(result.title)
                .font(TF.settingsFontReading)
                .foregroundStyle(TF.settingsText)
                .lineLimit(2)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(result.content)
                        .font(TF.settingsFontReading)
                        .foregroundStyle(TF.settingsText)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if let reason = result.reviewReason, !reason.isEmpty {
                        reviewReasonCard(
                            reason: reason,
                            score: result.score,
                            isRejected: result.status == .rejected
                        )
                    }
                }
                .padding(.bottom, SettingsScrollFade.contentPadding)
            }
            .settingsThinScrollIndicators()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .settingsBottomScrollFade(color: TF.settingsCard)
            .padding(.top, AssetLibraryStyle.detailSectionSpacing)

            detailFooter(result)
        }
        .padding(.top, AssetLibraryStyle.detailTopPadding)
        .padding(.leading, AssetLibraryStyle.detailLeadingPadding)
        .padding(.trailing, AssetLibraryStyle.discoverPanelPadding)
        .padding(.bottom, AssetLibraryStyle.discoverPanelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func detailMetadata(for result: ExtractionResult) -> String {
        var parts = [result.outputKind.settingsDisplayTitle, formattedDate(result.createdAt)]
        if let score = result.score {
            parts.append(L("严审 \(Int(score)) 分", "Review \(Int(score))"))
        }
        return parts.joined(separator: " · ")
    }

    /// 严审判决卡：用户在拍板时能看到「为什么留/为什么砍」——筛选严不严可审计
    func reviewReasonCard(reason: String, score: Double?, isRejected: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: isRejected ? "xmark.seal" : "checkmark.seal")
                    .font(TF.settingsFontIconSmall)
                Text(rejectionHeading(score: score, isRejected: isRejected))
                    .font(TF.settingsFontMetadata)
            }
            .foregroundStyle(TF.settingsTextTertiary)

            Text(reason)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextSecondary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AssetLibraryStyle.controlCornerRadius, style: .continuous)
                .fill(TF.settingsSegmentTrackFill.opacity(0.5))
        )
    }

    func rejectionHeading(score: Double?, isRejected: Bool) -> String {
        if isRejected {
            return score.map { L("严审砍掉 · \(Int($0)) 分 — 觉得错杀可捞回", "Dropped · \(Int($0)) — restore if wrong") }
                ?? L("严审砍掉 — 觉得错杀可捞回", "Dropped — restore if wrong")
        }
        return score.map { L("严审通过 · \(Int($0)) 分", "Passed review · \(Int($0))") }
            ?? L("严审说明", "Review note")
    }

    func detailFooter(_ result: ExtractionResult) -> some View {
        let groupResults = runGroups.first { $0.id == result.runID }?.results ?? []
        let isRejected = result.status == .rejected

        return HStack(spacing: 8) {
            Text(L("来源 \(result.sourceRecordCount) 条", "\(result.sourceRecordCount) sources"))
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)

            // secondary 而非 ghost：ghost 字色过暗，看着像不可点（2026-07 大梁老师）
            SettingsTextButton(L("原始输入", "Source"), variant: .secondary) {
                onShowSources(result)
            }

            Spacer(minLength: 6)

            if isRejected {
                // 砍单条目：唯一动作是捞回待确认，捞回后再正常拍板
                SettingsTextButton(L("捞回到待确认", "Restore"), variant: .primary) {
                    onRestore(result)
                }
            } else {
                if groupResults.count > 1 {
                    SettingsTextButton(
                        L("本批全入库(\(groupResults.count))", "Save all (\(groupResults.count))"),
                        variant: .secondary
                    ) {
                        onSaveAll(groupResults)
                    }
                }

                SettingsTextButton(L("抛弃", "Discard"), variant: .secondary) {
                    onDiscard(result)
                }

                SettingsTextButton(L("入库", "Save"), variant: .primary) {
                    onSave(result)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: AssetLibraryStyle.detailFooterMinHeight, alignment: .center)
        .padding(.top, AssetLibraryStyle.detailFooterTopPadding)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TF.settingsStroke.opacity(0.55))
                .frame(height: 1)
        }
    }

    var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("没有待确认的产物", "Nothing to review"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)
            Text(L("去「提炼」页跑一次配方，产物会先经过严审，再进入这里等你拍板：入库或抛弃。", "Run a recipe on the Extract page. Results pass strict review, then wait here for your decision."))
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(2)
        }
        .padding(.top, 15)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
