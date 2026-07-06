import SwiftUI

struct AssetCandidateGroupsPanel: View {
    @Binding var candidateQuery: String
    let candidates: [LanguageAssetCandidateRecord]
    /// 最近一次提炼任务 id：其产出在列表里标「新」点（改造方案 #8）
    var latestJobID: String? = nil
    @Binding var selectedCandidateType: LanguageAssetType?
    @Binding var selectedCandidateID: String?

    private var expandedCandidateType: LanguageAssetType? {
        selectedCandidateType
    }

    var body: some View {
        AssetLibraryNavigationPanel(
            query: $candidateQuery,
            prompt: L("搜索金句", "Search quotes")
        ) {
            candidateGroups
        }
    }

    private var candidateGroups: some View {
        Group {
            let quoteItems = candidates.filter { $0.assetType == .quote }
            if !quoteItems.isEmpty {
                typeGroup(type: .quote, items: quoteItems)
            }

            if quoteItems.isEmpty {
                Text(emptyStateText)
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(10)
            }
        }
    }

    private var emptyStateText: String {
        candidateQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L("暂无金句候选。", "No quote candidates.")
            : L("没有匹配金句", "No matching quotes")
    }

    private func typeGroup(type: LanguageAssetType, items: [LanguageAssetCandidateRecord]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            AssetLibraryGroupHeaderRow(
                type: type,
                count: items.count,
                isSelected: expandedCandidateType == type,
                action: {
                    if expandedCandidateType == type {
                        selectedCandidateType = nil
                    } else {
                        selectedCandidateType = type
                        selectedCandidateID = items.first?.id
                    }
                }
            )

            if expandedCandidateType == type {
                VStack(alignment: .leading, spacing: AssetLibraryStyle.navigationItemSpacing) {
                    ForEach(items) { candidate in
                        miniCandidateButton(candidate)
                    }
                }
            }
        }
    }

    private func miniCandidateButton(_ candidate: LanguageAssetCandidateRecord) -> some View {
        AssetLibraryCompactItemRow(
            title: candidate.title,
            grade: candidate.grade,
            isSelected: selectedCandidateID == candidate.id,
            isNew: latestJobID != nil && candidate.extractionJobID == latestJobID,
            action: {
                selectedCandidateType = candidate.assetType
                selectedCandidateID = candidate.id
            }
        )
    }
}
