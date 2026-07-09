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
    ) async -> AssetLibraryDataSnapshot {
        let recipes = await assetStore.fetchRecipes()
        let archivedRecipes = await assetStore.fetchRecipes(status: .archived)
        let assets = await assetStore.fetchAll()
        let extractionResults = await assetStore.fetchResults()
        let pendingCandidates = await assetStore.fetchCandidates()
        let ignoredCandidates = await assetStore.fetchCandidates(status: .ignored)
        let pendingResults = await assetStore.fetchResults(status: .pending)
        let savedResults = await assetStore.fetchResults(status: .saved)
        let rejectedResults = await assetStore.fetchResults(status: .rejected)
        let recentRuns = await assetStore.fetchRuns(limit: 20)
        // 语料池计数与提炼输入同口径(completed 且有正文)，COUNT 查询不拉全行
        let totalExtractable = await historyStore.extractableRecordCount()
        var sourceIDSet = Set<String>()
        sourceIDSet.formUnion(assets.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(extractionResults.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(pendingCandidates.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(ignoredCandidates.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(pendingResults.flatMap(\.sourceRecordIDs))
        sourceIDSet.formUnion(savedResults.flatMap(\.sourceRecordIDs))
        let sourceIDs = Array(sourceIDSet)
        let sourceRecords = sourceIDs.isEmpty ? [] : await historyStore.fetch(ids: sourceIDs)

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
