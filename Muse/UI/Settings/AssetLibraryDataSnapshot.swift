import Foundation

struct AssetLibraryDataSnapshot {
    let recipes: [ExtractionRecipe]
    /// 已停用配方（可恢复）
    let archivedRecipes: [ExtractionRecipe]
    let assets: [LanguageAsset]
    let extractionResults: [ExtractionResult]
    let pendingCandidates: [LanguageAssetCandidateRecord]
    let ignoredCandidates: [LanguageAssetCandidateRecord]
    let sourceRecordMap: [String: HistoryRecord]
    // 2026-07 重构批三：四区数据——待确认产物 / 已入库资产 / 最近批次 / 语料池计数
    let pendingResults: [ExtractionResult]
    let savedResults: [ExtractionResult]
    /// 严审砍掉的产物：待确认页可翻砍单、可捞回（防错杀防黑箱）
    let rejectedResults: [ExtractionResult]
    let recentRuns: [ExtractionRun]
    let totalRecordCount: Int

    static func load(
        assetStore: LanguageAssetStore,
        historyStore: HistoryStore
    ) async throws -> AssetLibraryDataSnapshot {
        let recipes = try await assetStore.fetchRecipesOrThrow()
        let archivedRecipes = try await assetStore.fetchRecipesOrThrow(status: .archived)
        let assets = try await assetStore.fetchAllOrThrow()
        let extractionResults = try await assetStore.fetchResultsOrThrow()
        let pendingCandidates = try await assetStore.fetchCandidatesOrThrow()
        let ignoredCandidates = try await assetStore.fetchCandidatesOrThrow(status: .ignored)
        let pendingResults = try await assetStore.fetchResultsOrThrow(status: .pending)
        let savedResults = try await assetStore.fetchResultsOrThrow(status: .saved)
        let rejectedResults = try await assetStore.fetchResultsOrThrow(status: .rejected)
        let recentRuns = try await assetStore.fetchRunsOrThrow(limit: 20)
        // 语料池计数与提炼输入同口径(completed 且有正文)，COUNT 查询不拉全行
        let totalExtractable = try await historyStore.extractableRecordCountOrThrow()
        var sourceIDSet = Set<String>()
        sourceIDSet.formUnion(assets.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(extractionResults.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(pendingCandidates.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(ignoredCandidates.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(pendingResults.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(savedResults.flatMap(\.sourceRecordIDs))
        let sourceIDs = Array(sourceIDSet)
        let sourceRecords = sourceIDs.isEmpty
            ? []
            : try await historyStore.fetchOrThrow(ids: sourceIDs)

        return AssetLibraryDataSnapshot(
            recipes: recipes,
            archivedRecipes: archivedRecipes,
            assets: assets,
            extractionResults: extractionResults,
            pendingCandidates: pendingCandidates,
            ignoredCandidates: ignoredCandidates,
            sourceRecordMap: Dictionary(uniqueKeysWithValues: sourceRecords.map { ($0.id, $0) }),
            pendingResults: pendingResults,
            savedResults: savedResults,
            rejectedResults: rejectedResults,
            recentRuns: recentRuns,
            totalRecordCount: totalExtractable
        )
    }
}
