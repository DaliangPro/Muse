import SwiftUI

struct AssetLibrarySavedAssetsView: View {
    @Binding var libraryQuery: String
    @Binding var selectedLibraryType: LanguageAssetType?
    @Binding var selectedLibraryAssetID: String?
    @Binding var selectedResultRecipeID: String?
    @Binding var selectedResultID: String?
    let creatorAssets: [LanguageAsset]
    let extractionResults: [ExtractionResult]
    /// 配方 ID → 展示名/点色。资产库按配方分类分组（2026-07-08 大梁老师：
    /// 「候选资产」只属于待确认阶段，入库后按分类展示，不再挂候选名）
    let recipeName: (String) -> String
    let recipeAccent: (String) -> Color
    let selectedLibraryAsset: LanguageAsset?
    let selectedExtractionResult: ExtractionResult?
    let copiedAssetID: String?
    let formattedDate: (Date) -> String
    let onCopyAsset: (LanguageAsset) -> Void
    let onShowResultSources: (ExtractionResult) -> Void
    let onCopyResult: (ExtractionResult) -> Void
    let onToggleFavorite: (LanguageAsset) -> Void
    let onDeleteAsset: (LanguageAsset) -> Void
    let onDeleteResult: (ExtractionResult) -> Void

    @State private var assetPendingDeletion: LanguageAsset?
    @State private var resultPendingDeletion: ExtractionResult?

    /// 各分类的展开状态（可自由单击收起/展开，2026-07-08 大梁老师）。
    /// nil = 初始态：只展开当前详情所属分类
    @State private var expandedRecipeIDs: Set<String>?

    var body: some View {
        AssetLibrarySplitPanel {
            libraryNavigationPanel
        } detail: {
            libraryDetailPanel
        }
        .confirmationDialog(
            L("删除这条资产？", "Delete this asset?"),
            isPresented: Binding(
                get: { assetPendingDeletion != nil },
                set: { if !$0 { assetPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除", "Delete"), role: .destructive) {
                if let asset = assetPendingDeletion {
                    onDeleteAsset(asset)
                }
                assetPendingDeletion = nil
            }
            Button(L("取消", "Cancel"), role: .cancel) {
                assetPendingDeletion = nil
            }
        }
        .confirmationDialog(
            L("删除这条资产？", "Delete this asset?"),
            isPresented: Binding(
                get: { resultPendingDeletion != nil },
                set: { if !$0 { resultPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除", "Delete"), role: .destructive) {
                if let result = resultPendingDeletion {
                    onDeleteResult(result)
                }
                resultPendingDeletion = nil
            }
            Button(L("取消", "Cancel"), role: .cancel) {
                resultPendingDeletion = nil
            }
        }
    }

    private var searchedLibraryAssets: [LanguageAsset] {
        AssetLibraryAssetFilters.filteredLibraryAssets(
            from: creatorAssets,
            selectedType: nil,
            query: libraryQuery
        )
    }

    private var searchedExtractionResults: [ExtractionResult] {
        let trimmedQuery = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // 2026-07 重构批三：金句/创作素材(assetCandidates)也是统一产物，入库后同样在资产库展示
        let visibleResults = extractionResults
        guard !trimmedQuery.isEmpty else { return visibleResults }

        return visibleResults.filter { result in
            [
                recipeName(result.recipeID),
                result.recipeID,
                result.title,
                result.content,
                result.summary ?? "",
            ].joined(separator: " ").localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var libraryGroups: [(type: LanguageAssetType, assets: [LanguageAsset])] {
        LanguageAssetType.creatorCases.compactMap { type in
            let assets = searchedLibraryAssets.filter { $0.assetType == type }
            return assets.isEmpty ? nil : (type, assets)
        }
    }

    /// 按配方分类分组（组序 = 结果列表中的首现顺序，即最近有产出的分类靠前）
    private var resultGroups: [(recipeID: String, results: [ExtractionResult])] {
        var order: [String] = []
        var buckets: [String: [ExtractionResult]] = [:]
        for result in searchedExtractionResults {
            if buckets[result.recipeID] == nil { order.append(result.recipeID) }
            buckets[result.recipeID, default: []].append(result)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var expandedLibraryType: LanguageAssetType? {
        if let selectedLibraryType,
           libraryGroups.contains(where: { $0.type == selectedLibraryType }) {
            return selectedLibraryType
        }
        return nil
    }

    private var displayedLibraryAsset: LanguageAsset? {
        if selectedResultID != nil {
            return nil
        }
        if let selectedLibraryAsset,
           searchedLibraryAssets.contains(where: { $0.id == selectedLibraryAsset.id }) {
            return selectedLibraryAsset
        }
        return libraryGroups.first?.assets.first
    }

    private var displayedExtractionResult: ExtractionResult? {
        if let selectedResultID,
           let result = searchedExtractionResults.first(where: { $0.id == selectedResultID }) {
            return result
        }
        if displayedLibraryAsset == nil {
            return resultGroups.first?.results.first
        }
        return nil
    }

    private var libraryNavigationPanel: some View {
        AssetLibraryNavigationPanel(
            query: $libraryQuery,
            prompt: L("搜索资产", "Search assets"),
            searchPosition: .bottom
        ) {
            assetGroups
        }
    }

    private var assetGroups: some View {
        Group {
            if searchedLibraryAssets.isEmpty && searchedExtractionResults.isEmpty {
                Text(L("没有匹配资产", "No matching assets"))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ForEach(libraryGroups, id: \.type) { group in
                    libraryTypeGroup(type: group.type, items: group.assets)
                }
                ForEach(resultGroups, id: \.recipeID) { group in
                    resultRecipeGroup(recipeID: group.recipeID, items: group.results)
                }
            }
        }
    }

    private func libraryTypeGroup(type: LanguageAssetType, items: [LanguageAsset]) -> some View {
        let isExpanded = expandedLibraryType == type

        return VStack(alignment: .leading, spacing: 5) {
            AssetLibraryGroupHeaderRow(
                type: type,
                count: items.count,
                isSelected: isExpanded,
                action: {
                    if isExpanded {
                        selectedLibraryType = nil
                    } else {
                        selectedLibraryType = type
                        selectedLibraryAssetID = items.first?.id
                    }
                }
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: AssetLibraryStyle.navigationItemSpacing) {
                    ForEach(items) { asset in
                        libraryAssetButton(asset)
                    }
                }
            }
        }
    }

    private func libraryAssetButton(_ asset: LanguageAsset) -> some View {
        let isSelected = displayedLibraryAsset?.id == asset.id

        return AssetLibraryCompactItemRow(
            title: asset.title ?? asset.content,
            grade: asset.grade,
            isSelected: isSelected,
            action: {
                selectedLibraryAssetID = asset.id
                selectedLibraryType = asset.assetType
                selectedResultID = nil
                selectedResultRecipeID = nil
            }
        )
    }

    /// 生效的展开集合：用户动过手就用记忆值，否则默认只展开当前详情所属分类
    private var effectiveExpandedRecipeIDs: Set<String> {
        if let expandedRecipeIDs { return expandedRecipeIDs }
        if let recipeID = displayedExtractionResult?.recipeID { return [recipeID] }
        return []
    }

    private func resultRecipeGroup(recipeID: String, items: [ExtractionResult]) -> some View {
        let isExpanded = effectiveExpandedRecipeIDs.contains(recipeID)

        return VStack(alignment: .leading, spacing: 5) {
            SettingsSelectableRow(
                isSelected: isExpanded,
                minHeight: 34,
                verticalPadding: 6
            ) {
                var ids = effectiveExpandedRecipeIDs
                if isExpanded {
                    ids.remove(recipeID)
                } else {
                    ids.insert(recipeID)
                    selectedResultRecipeID = recipeID
                    selectedResultID = items.first?.id
                    selectedLibraryType = nil
                    selectedLibraryAssetID = nil
                }
                expandedRecipeIDs = ids
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(recipeAccent(recipeID))
                        .frame(width: 6, height: 6)
                    Text(recipeName(recipeID))
                        .font(TF.settingsFontBodyStrong)
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(items.count)")
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .monospacedDigit()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: AssetLibraryStyle.navigationItemSpacing) {
                    ForEach(items) { result in
                        resultButton(result)
                    }
                }
            }
        }
    }

    private func resultButton(_ result: ExtractionResult) -> some View {
        let isSelected = displayedExtractionResult?.id == result.id

        return AssetLibraryCompactItemRow(
            title: result.title.isEmpty ? result.content : result.title,
            grade: nil,
            isSelected: isSelected,
            action: {
                selectedResultID = result.id
                selectedResultRecipeID = result.recipeID
                selectedLibraryType = nil
                selectedLibraryAssetID = nil
            }
        )
    }

    @ViewBuilder
    private var libraryDetailPanel: some View {
        if let asset = displayedLibraryAsset {
            AssetLibraryDetailPane(
                accentColor: asset.assetType.settingsAccentColor,
                metadata: "\(asset.assetType.settingsDisplayTitle) · \(formattedDate(asset.createdAt))",
                grade: asset.grade,
                title: asset.title ?? asset.content,
                bodyText: asset.content,
                tags: combinedTags(for: asset)
            ) {
                HStack(spacing: 8) {
                    // 只留「已入库」（2026-06-12 用户拍板：长文案被按钮挤到截断没人看得懂）；
                    // 命中的提炼规则挂悬停提示
                    Text(L("已入库", "Saved"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                        .help(asset.ruleHit ?? asset.assetType.settingsDisplayTitle)

                    Spacer(minLength: 6)

                    // 收藏置顶（改造方案 #4）
                    SettingsPlainButton {
                        onToggleFavorite(asset)
                    } label: {
                        Image(systemName: asset.isFavorite ? "star.fill" : "star")
                            .font(TF.settingsFontIconBody)
                            .foregroundStyle(asset.isFavorite ? TF.settingsAccentAmber : TF.settingsTextTertiary)
                            .frame(width: SettingsControlSpec.actionHeight, height: SettingsControlSpec.actionHeight)
                            .contentShape(Rectangle())
                    }
                    .help(asset.isFavorite ? L("取消收藏", "Unfavorite") : L("收藏置顶", "Favorite"))

                    // 软删除，二次确认（改造方案 #4）；悬停变红
                    SettingsDeleteIconButton(
                        systemName: "xmark",
                        accessibilityLabel: L("删除资产", "Delete asset"),
                        size: SettingsControlSpec.actionHeight
                    ) {
                        assetPendingDeletion = asset
                    }
                    .help(L("删除资产", "Delete asset"))


                    SettingsTextButton(
                        copiedAssetID == asset.id ? L("已复制", "Copied") : L("复制资产", "Copy"),
                        variant: .primary
                    ) {
                        onCopyAsset(asset)
                    }
                }
            }
        } else if let result = displayedExtractionResult {
            AssetLibraryDetailPane(
                accentColor: recipeAccent(result.recipeID),
                metadata: "\(recipeName(result.recipeID)) · \(formattedDate(result.createdAt))",
                grade: nil,
                title: result.title.isEmpty ? recipeName(result.recipeID) : result.title,
                bodyText: result.content,
                tags: result.summary.map { [$0] } ?? []
            ) {
                HStack(spacing: 8) {
                    Text(L("提炼产物", "Extracted asset"))
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    // 移出资产库（二次确认；悬停变红）
                    SettingsDeleteIconButton(
                        systemName: "xmark",
                        accessibilityLabel: L("删除资产", "Delete asset"),
                        size: SettingsControlSpec.actionHeight
                    ) {
                        resultPendingDeletion = result
                    }

                    SettingsTextButton(L("来源", "Sources"), variant: .secondary) {
                        onShowResultSources(result)
                    }

                    SettingsTextButton(
                        copiedAssetID == result.id ? L("已复制", "Copied") : L("复制资产", "Copy"),
                        variant: .primary
                    ) {
                        onCopyResult(result)
                    }
                }
            }
        } else {
            Text(L("没有可查看的资产", "No asset to inspect"))
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.top, 15)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func combinedTags(for asset: LanguageAsset) -> [String] {
        AssetLibraryTagSorting.sortedCombinedTags(
            scenes: asset.scenes,
            audiences: asset.audiences,
            limit: 5
        )
    }
}
