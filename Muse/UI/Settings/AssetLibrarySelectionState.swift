import Foundation

/// 语料资产页选中态与归一化（2026-07-09 J13 拆分段）：
/// 值类型承载全部侧栏选中 / 分组展开状态；normalize 在数据刷新与搜索词变化后
/// 清掉失效选中并回落到首条。独立于 View，类型筛选与归一化共用同一套规则，可单测。
struct AssetLibrarySelectionState {
    var selectedCandidateID: String?
    var selectedCandidateType: LanguageAssetType?
    var didInitializeCandidateGroupExpansion = false

    var selectedLibraryType: LanguageAssetType?
    var selectedLibraryAssetID: String?
    var didInitializeLibraryGroupExpansion = false

    var selectedResultKind: ExtractionOutputKind?
    /// 资产库侧栏的分组选中态（按配方分类；提炼结果仍按产物类型用 selectedResultKind）
    var selectedResultRecipeID: String?
    var selectedResultID: String?

    var selectedRecipeListID: String?

    // MARK: - 类型筛选（normalize 与 View 展示共用，避免口径分叉）

    func filteredCandidates(from searched: [LanguageAssetCandidateRecord]) -> [LanguageAssetCandidateRecord] {
        guard let selectedCandidateType else { return searched }
        return searched.filter { $0.assetType == selectedCandidateType }
    }

    func filteredLibraryAssets(from searched: [LanguageAsset]) -> [LanguageAsset] {
        guard let selectedLibraryType else { return searched }
        return searched.filter { $0.assetType == selectedLibraryType }
    }

    func filteredExtractionResults(from searched: [ExtractionResult]) -> [ExtractionResult] {
        guard let selectedResultKind else { return searched }
        return searched.filter { $0.outputKind == selectedResultKind }
    }

    // MARK: - 归一化

    mutating func normalize(
        searchedCandidates: [LanguageAssetCandidateRecord],
        searchedLibraryAssets: [LanguageAsset],
        searchedExtractionResults: [ExtractionResult],
        savedResults: [ExtractionResult],
        searchedRecipes: [ExtractionRecipe]
    ) {
        if !didInitializeCandidateGroupExpansion {
            selectedCandidateType = searchedCandidates.first?.assetType
            didInitializeCandidateGroupExpansion = true
        } else if let expandedType = selectedCandidateType,
                  !searchedCandidates.contains(where: { $0.assetType == expandedType }) {
            selectedCandidateType = nil
        }

        let visibleCandidates = filteredCandidates(from: searchedCandidates)
        if let selectedCandidateID,
           visibleCandidates.contains(where: { $0.id == selectedCandidateID }) {
            // Keep current selection.
        } else {
            selectedCandidateID = visibleCandidates.first?.id ?? searchedCandidates.first?.id
        }

        if !didInitializeLibraryGroupExpansion {
            selectedLibraryType = searchedLibraryAssets.first?.assetType
            didInitializeLibraryGroupExpansion = true
        } else if let expandedType = selectedLibraryType,
                  !searchedLibraryAssets.contains(where: { $0.assetType == expandedType }) {
            selectedLibraryType = nil
        }

        let visibleLibraryAssets = filteredLibraryAssets(from: searchedLibraryAssets)
        if let selectedLibraryAssetID,
           visibleLibraryAssets.contains(where: { $0.id == selectedLibraryAssetID }) {
            // Keep current selection.
        } else {
            selectedLibraryAssetID = visibleLibraryAssets.first?.id ?? searchedLibraryAssets.first?.id
        }

        if let selectedResultKind,
           !searchedExtractionResults.contains(where: { $0.outputKind == selectedResultKind }) {
            self.selectedResultKind = nil
        }

        // 资产库按配方分组的选中态：该分类下已无入库产物时清空
        if let selectedResultRecipeID,
           !savedResults.contains(where: { $0.recipeID == selectedResultRecipeID }) {
            self.selectedResultRecipeID = nil
        }

        let visibleResults = filteredExtractionResults(from: searchedExtractionResults)
        if let selectedResultID,
           visibleResults.contains(where: { $0.id == selectedResultID }) {
            // Keep current selection.
        } else {
            selectedResultID = visibleResults.first?.id ?? searchedExtractionResults.first?.id
        }

        if let selectedRecipeListID,
           searchedRecipes.contains(where: { $0.id == selectedRecipeListID }) {
            // Keep current selection.
        } else {
            selectedRecipeListID = searchedRecipes.first?.id
        }
    }
}
