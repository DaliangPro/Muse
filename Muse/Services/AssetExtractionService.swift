import Foundation
import os

struct AssetExtractionConfiguration: Sendable, Equatable {
    var rangeType: AssetExtractionRangeType
    var startDate: Date?
    var endDate: Date?
    var selectedRecordIDs: [String] = []
    var maxRecordCount: Int = 50
    var minimumCharacterCount: Int = 1
    var maxTotalInputCharacters: Int = 12_000
    var maxCharactersPerRecord: Int = 1_600
    var enablesCandidateFiltering: Bool = true
    var includesProcessedRecords: Bool = false
    var ruleConfig: AssetExtractionRuleConfig = .default
    var recipeID: String = ExtractionRecipe.contentCreatorAssetsID

    var recipe: ExtractionRecipe {
        ExtractionRecipe.builtInRecipe(id: recipeID) ?? ExtractionRecipe.contentCreatorAssets()
    }

    static func last1Day(maxRecordCount: Int = 50) -> Self {
        Self(
            rangeType: .last1Day,
            startDate: Calendar.current.date(byAdding: .day, value: -1, to: Date()),
            endDate: Date(),
            maxRecordCount: maxRecordCount
        )
    }

    static func last7Days(maxRecordCount: Int = 50) -> Self {
        Self(
            rangeType: .last7Days,
            startDate: Calendar.current.date(byAdding: .day, value: -7, to: Date()),
            endDate: Date(),
            maxRecordCount: maxRecordCount
        )
    }

    static func last30Days(maxRecordCount: Int = 100) -> Self {
        Self(
            rangeType: .last30Days,
            startDate: Calendar.current.date(byAdding: .day, value: -30, to: Date()),
            endDate: Date(),
            maxRecordCount: maxRecordCount
        )
    }

    static func recent(limit: Int = 50) -> Self {
        Self(rangeType: .lastNRecords, maxRecordCount: limit)
    }

    static func manualSelection(ids: [String]) -> Self {
        Self(rangeType: .manualSelection, selectedRecordIDs: ids, maxRecordCount: ids.count)
    }

    func applying(ruleConfig: AssetExtractionRuleConfig) -> Self {
        var updated = self
        updated.ruleConfig = ruleConfig
        return updated
    }

    func applying(recipeID: String) -> Self {
        var updated = self
        updated.recipeID = recipeID
        return updated
    }

    func includingProcessedRecords(_ includesProcessedRecords: Bool) -> Self {
        var updated = self
        updated.includesProcessedRecords = includesProcessedRecords
        return updated
    }

    func adaptedForAssetExtractionProvider(_ provider: LLMProvider) -> Self {
        guard provider == .localQwen else { return self }
        var updated = self
        updated.maxRecordCount = min(updated.maxRecordCount, 12)
        updated.maxTotalInputCharacters = min(updated.maxTotalInputCharacters, 1_000)
        updated.maxCharactersPerRecord = min(updated.maxCharactersPerRecord, 420)
        return updated
    }

    var rangePayload: String? {
        let payload: String?
        switch rangeType {
        case .last1Day, .last7Days, .last30Days:
            payload = [startDate, endDate]
                .compactMap { $0 }
                .map { ISO8601DateFormatter().string(from: $0) }
                .joined(separator: " -> ")
        case .lastNRecords:
            payload = "limit=\(maxRecordCount)"
        case .manualSelection:
            // 全量提炼时手选 ids 可达数千个，不把巨型列表塞进 run 记录
            payload = selectedRecordIDs.isEmpty
                ? nil
                : (selectedRecordIDs.count > 24
                    ? "count=\(selectedRecordIDs.count)"
                    : selectedRecordIDs.joined(separator: ","))
        }

        guard includesProcessedRecords, rangeType != .manualSelection else {
            return payload
        }
        return [payload, "include_processed=true"].compactMap { $0 }.joined(separator: ";")
    }
}

struct AssetExtractionCandidate: Codable, Hashable, Sendable {
    let type: LanguageAssetType?
    let grade: LanguageAssetGrade?
    let title: String?
    let content: String
    let summary: String?
    let reason: String?
    let scenes: [String]
    let audiences: [String]
    let ruleHit: String?
    let keywords: [String]
    let sourceRecordIDs: [String]

    enum CodingKeys: String, CodingKey {
        case type
        case grade
        case title
        case content
        case summary
        case reason
        case scenes
        case audiences
        case ruleHit = "rule_hit"
        case keywords
        case sourceRecordIDs = "source_record_ids"
    }

    init(
        type: LanguageAssetType? = nil,
        grade: LanguageAssetGrade? = nil,
        title: String?,
        content: String,
        summary: String?,
        reason: String? = nil,
        scenes: [String] = [],
        audiences: [String] = [],
        ruleHit: String? = nil,
        keywords: [String],
        sourceRecordIDs: [String]
    ) {
        self.type = type
        self.grade = grade
        self.title = title
        self.content = content
        self.summary = summary
        self.reason = reason
        self.scenes = scenes
        self.audiences = audiences
        self.ruleHit = ruleHit
        self.keywords = keywords
        self.sourceRecordIDs = sourceRecordIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawType = try container.decodeIfPresent(String.self, forKey: .type) {
            type = LanguageAssetType(rawValue: rawType)
        } else {
            type = nil
        }
        if let rawGrade = try container.decodeIfPresent(String.self, forKey: .grade) {
            grade = LanguageAssetGrade(rawValue: rawGrade.uppercased())
        } else {
            grade = nil
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        scenes = try container.decodeIfPresent([String].self, forKey: .scenes) ?? []
        audiences = try container.decodeIfPresent([String].self, forKey: .audiences) ?? []
        ruleHit = try container.decodeIfPresent(String.self, forKey: .ruleHit)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        sourceRecordIDs = try container.decodeIfPresent([String].self, forKey: .sourceRecordIDs) ?? []
    }

}

struct AssetExtractionSummary: Codable, Equatable, Sendable {
    let totalInputs: Int
    let candidateCount: Int
    let aCount: Int
    let bCount: Int

    enum CodingKeys: String, CodingKey {
        case totalInputs = "total_inputs"
        case candidateCount = "candidate_count"
        case aCount = "a_count"
        case bCount = "b_count"
    }

    static let empty = AssetExtractionSummary(
        totalInputs: 0,
        candidateCount: 0,
        aCount: 0,
        bCount: 0
    )
}

struct AssetExtractionResult: Codable, Equatable, Sendable {
    let assets: [AssetExtractionCandidate]
    let ignoredCount: Int
    let summary: AssetExtractionSummary

    init(
        assets: [AssetExtractionCandidate],
        ignoredCount: Int = 0,
        summary: AssetExtractionSummary = .empty
    ) {
        self.assets = assets
        self.ignoredCount = ignoredCount
        self.summary = summary
    }
}

struct AssetExtractionRunResult: Sendable, Equatable {
    let job: AssetExtractionJob
    let candidates: [LanguageAssetCandidateRecord]
}

struct RecipeExtractionRunResult: Sendable, Equatable {
    let run: ExtractionRun
    let results: [ExtractionResult]
}

enum AssetExtractionProgressStage: Int, CaseIterable, Sendable {
    case preparing
    case loadingRecords
    case filteringInputs
    case callingModel
    case normalizingResults
    /// 两段式第二段：按配方标准逐条严审（2026-07 重构批二）
    case reviewingResults
    case savingCandidates
}

/// 提炼前预览（2026-06-11 改造方案 #7/#9）：本地零成本算出实际将提炼的范围，
/// 含防重排除数与超量截断数，供确认弹窗明示
struct AssetExtractionPreview: Sendable, Equatable {
    let sourceCount: Int
    let excludedAsProcessedCount: Int
    let eligibleCount: Int
    let truncatedCount: Int
    let totalCharacters: Int
    let records: [HistoryRecord]
}

actor AssetExtractionService {

    private let logger = Logger(subsystem: "pro.daliang.muse.assets", category: "AssetExtractionService")
    private let historyStore: HistoryStore
    private let assetStore: LanguageAssetStore
    private let provider: any AssetExtractionProvider
    private let recipeProvider: any RecipeExtractionProvider
    private let reviewProvider: any ExtractionReviewProvider
    private let normalizer: AssetExtractionNormalizer

    init(
        historyStore: HistoryStore = HistoryStore(),
        assetStore: LanguageAssetStore = LanguageAssetStore(),
        provider: any AssetExtractionProvider = RemoteAssetExtractionProvider(),
        recipeProvider: any RecipeExtractionProvider = RemoteRecipeExtractionProvider(),
        reviewProvider: any ExtractionReviewProvider = RemoteExtractionReviewProvider(),
        normalizer: AssetExtractionNormalizer = AssetExtractionNormalizer()
    ) {
        self.historyStore = historyStore
        self.assetStore = assetStore
        self.provider = provider
        self.recipeProvider = recipeProvider
        self.reviewProvider = reviewProvider
        self.normalizer = normalizer
    }

    func extractAssets(
        configuration: AssetExtractionConfiguration,
        progress: (AssetExtractionProgressStage) async -> Void = { _ in }
    ) async throws -> AssetExtractionRunResult {
        await progress(.preparing)
        let recipe = await assetStore.fetchRecipe(id: configuration.recipeID)
            ?? ExtractionRecipe.contentCreatorAssets()
        guard recipe.outputKind == .assetCandidates else {
            throw AssetExtractionError.unsupportedRecipe(recipe.name)
        }
        let createdJob = AssetExtractionJob(
            id: UUID().uuidString,
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil,
            rangeType: configuration.rangeType,
            rangePayload: configuration.rangePayload,
            sourceRecordCount: 0,
            status: .queued,
            summary: nil,
            errorMessage: nil
        )
        await assetStore.insert(job: createdJob)
        let queuedRun = ExtractionRun(
            id: createdJob.id,
            recipeID: recipe.id,
            recipeName: recipe.name,
            createdAt: createdJob.createdAt,
            startedAt: nil,
            finishedAt: nil,
            rangeType: configuration.rangeType,
            rangePayload: configuration.rangePayload,
            sourceRecordCount: 0,
            status: .queued,
            resultCount: 0,
            summary: nil,
            errorMessage: nil
        )
        await assetStore.insert(run: queuedRun)

        var loadedSourceRecordCount = 0

        do {
            await progress(.loadingRecords)
            let sourceRecords = await loadFreshSourceRecords(configuration: configuration).records
            loadedSourceRecordCount = sourceRecords.count
            let runningJob = AssetExtractionJob(
                id: createdJob.id,
                createdAt: createdJob.createdAt,
                startedAt: Date(),
                finishedAt: nil,
                rangeType: configuration.rangeType,
                rangePayload: configuration.rangePayload,
                sourceRecordCount: sourceRecords.count,
                status: .running,
                summary: nil,
                errorMessage: nil
            )
            await assetStore.insert(job: runningJob)
            let runningRun = ExtractionRun(
                id: queuedRun.id,
                recipeID: queuedRun.recipeID,
                recipeName: queuedRun.recipeName,
                createdAt: queuedRun.createdAt,
                startedAt: runningJob.startedAt,
                finishedAt: nil,
                rangeType: runningJob.rangeType,
                rangePayload: runningJob.rangePayload,
                sourceRecordCount: sourceRecords.count,
                status: .running,
                resultCount: 0,
                summary: nil,
                errorMessage: nil
            )
            await assetStore.insert(run: runningRun)

            await progress(.filteringInputs)
            let filterOutcome = candidateRecords(from: sourceRecords, configuration: configuration)
            let candidateRecords = filterOutcome.records
            await assetStore.logAction(
                actionType: .extractionStarted,
                detail: extractionStartedDetail(
                    configuration: configuration,
                    sourceCount: sourceRecords.count,
                    candidateCount: candidateRecords.count
                )
            )
            guard !candidateRecords.isEmpty else {
                let finishedJob = AssetExtractionJob(
                    id: runningJob.id,
                    createdAt: runningJob.createdAt,
                    startedAt: runningJob.startedAt,
                    finishedAt: Date(),
                    rangeType: runningJob.rangeType,
                    rangePayload: runningJob.rangePayload,
                    sourceRecordCount: runningJob.sourceRecordCount,
                    status: .succeeded,
                    summary: L("本次范围内没有足够明确的高价值语料", "No high-value source material found in this range"),
                    errorMessage: nil
                )
                await assetStore.insert(job: finishedJob)
                await assetStore.insert(run: ExtractionRun(
                    id: runningRun.id,
                    recipeID: runningRun.recipeID,
                    recipeName: runningRun.recipeName,
                    createdAt: runningRun.createdAt,
                    startedAt: runningRun.startedAt,
                    finishedAt: finishedJob.finishedAt,
                    rangeType: runningRun.rangeType,
                    rangePayload: runningRun.rangePayload,
                    sourceRecordCount: runningRun.sourceRecordCount,
                    status: .succeeded,
                    resultCount: 0,
                    summary: finishedJob.summary,
                    errorMessage: nil
                ))
                await assetStore.logAction(
                    actionType: .extractionSucceeded,
                    detail: finishedJob.summary
                )
                return AssetExtractionRunResult(job: finishedJob, candidates: [])
            }

            await progress(.callingModel)
            let result = try await provider.extractAssets(from: candidateRecords, configuration: configuration)
            await progress(.normalizingResults)
            // 跨任务防重②：对照库内既有候选与资产的内容键，剔除重复产出
            let existingKeys = await assetStore.existingDedupeKeys()
            let candidates = normalizer.normalizeCandidates(
                result: result,
                sourceRecords: candidateRecords,
                extractionJobID: runningJob.id,
                existingKeys: existingKeys
            )

            await progress(.savingCandidates)
            try await assetStore.saveCandidatesOrThrow(candidates)
            try await assetStore.saveResultsOrThrow(
                extractionResults(
                    from: candidates,
                    run: runningRun,
                    outputKind: recipe.outputKind
                )
            )
            // 候选表保留策略（改造方案 #14）：已处理候选超龄/超量顺手裁剪
            await assetStore.pruneFinishedCandidates()

            var summary = buildSummary(for: candidates)
            if filterOutcome.truncatedCount > 0 {
                summary += L(
                    "；因输入上限丢弃 \(filterOutcome.truncatedCount) 条",
                    "; \(filterOutcome.truncatedCount) dropped over input limit"
                )
            }
            let finishedJob = AssetExtractionJob(
                id: runningJob.id,
                createdAt: runningJob.createdAt,
                startedAt: runningJob.startedAt,
                finishedAt: Date(),
                rangeType: runningJob.rangeType,
                rangePayload: runningJob.rangePayload,
                sourceRecordCount: runningJob.sourceRecordCount,
                status: .succeeded,
                summary: summary,
                errorMessage: nil
            )
            await assetStore.insert(job: finishedJob)
            await assetStore.insert(run: ExtractionRun(
                id: runningRun.id,
                recipeID: runningRun.recipeID,
                recipeName: runningRun.recipeName,
                createdAt: runningRun.createdAt,
                startedAt: runningRun.startedAt,
                finishedAt: finishedJob.finishedAt,
                rangeType: runningRun.rangeType,
                rangePayload: runningRun.rangePayload,
                sourceRecordCount: runningRun.sourceRecordCount,
                status: .succeeded,
                resultCount: candidates.count,
                summary: finishedJob.summary,
                errorMessage: nil
            ))
            await assetStore.logAction(
                actionType: .extractionSucceeded,
                detail: finishedJob.summary
            )
            logger.info("Asset extraction succeeded with \(candidates.count) candidates")
            return AssetExtractionRunResult(job: finishedJob, candidates: candidates)
        } catch {
            let message = error is CancellationError
                ? L("已取消", "Cancelled")
                : error.localizedDescription
            let failedJob = AssetExtractionJob(
                id: createdJob.id,
                createdAt: createdJob.createdAt,
                startedAt: Date(),
                finishedAt: Date(),
                rangeType: configuration.rangeType,
                rangePayload: configuration.rangePayload,
                sourceRecordCount: loadedSourceRecordCount,
                status: .failed,
                summary: nil,
                errorMessage: message
            )
            await assetStore.insert(job: failedJob)
            await assetStore.insert(run: ExtractionRun(
                id: createdJob.id,
                recipeID: recipe.id,
                recipeName: recipe.name,
                createdAt: createdJob.createdAt,
                startedAt: failedJob.startedAt,
                finishedAt: failedJob.finishedAt,
                rangeType: failedJob.rangeType,
                rangePayload: failedJob.rangePayload,
                sourceRecordCount: loadedSourceRecordCount,
                status: .failed,
                resultCount: 0,
                summary: nil,
                errorMessage: message
            ))
            await assetStore.logAction(
                actionType: .extractionFailed,
                detail: message
            )
            logger.error("Asset extraction failed: \(error.localizedDescription)")
            throw error
        }
    }

    func extractRecipeResults(
        configuration: AssetExtractionConfiguration,
        progress: (AssetExtractionProgressStage) async -> Void = { _ in }
    ) async throws -> RecipeExtractionRunResult {
        await progress(.preparing)
        let recipe = await assetStore.fetchRecipe(id: configuration.recipeID)
            ?? configuration.recipe
        // 2026-07 重构批二：金句/创作素材类配方也走统一两段式管线，不再拦截
        // （老 extractAssets 路径保留供旧界面过渡，批四清退）

        let createdRun = ExtractionRun(
            id: UUID().uuidString,
            recipeID: recipe.id,
            recipeName: recipe.name,
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil,
            rangeType: configuration.rangeType,
            rangePayload: configuration.rangePayload,
            sourceRecordCount: 0,
            status: .queued,
            resultCount: 0,
            summary: nil,
            errorMessage: nil
        )
        await assetStore.insert(run: createdRun)

        var loadedSourceRecordCount = 0
        do {
            await progress(.loadingRecords)
            let loadedRecords = await loadSourceRecords(configuration: configuration)
            // mapReduce(金句/素材类逐条淘金)全量不截断,片级再拆;whole(日报/待办整体阅读)维持单次上限
            let fullCoverage = recipe.processingStrategy == .mapReduce
            let inputOutcome = recipeInputRecords(
                from: loadedRecords,
                configuration: configuration,
                applyLimit: !fullCoverage
            )
            let sourceRecords = inputOutcome.records
            loadedSourceRecordCount = sourceRecords.count

            let runningRun = createdRun.advanced(
                startedAt: Date(),
                sourceRecordCount: sourceRecords.count,
                status: .running
            )
            await assetStore.insert(run: runningRun)
            await assetStore.logAction(
                actionType: .extractionStarted,
                detail: recipeExtractionStartedDetail(
                    recipe: recipe,
                    configuration: configuration,
                    sourceCount: loadedRecords.count,
                    inputCount: sourceRecords.count
                )
            )

            guard !sourceRecords.isEmpty else {
                let finishedRun = runningRun.advanced(
                    finishedAt: Date(),
                    status: .succeeded,
                    summary: L("本次范围内没有可用于提炼的语料", "No source material found in this range")
                )
                await assetStore.insert(run: finishedRun)
                return RecipeExtractionRunResult(run: finishedRun, results: [])
            }

            await progress(.callingModel)
            let output = try await widenedOutput(
                sourceRecords: sourceRecords,
                recipe: recipe,
                configuration: configuration,
                fullCoverage: fullCoverage
            )
            await progress(.normalizingResults)
            let widenedResults = normalizeRecipeResults(
                output: output,
                sourceRecords: sourceRecords,
                recipe: recipe,
                run: runningRun
            )

            // 两段式第二段（2026-07 重构批二）：独立严审按配方标准逐条判决，砍掉不达标候选
            await progress(.reviewingResults)
            let reviewOutcome = await reviewResults(widenedResults, recipe: recipe)
            let results = reviewOutcome.kept

            await progress(.savingCandidates)
            // 留的落待确认，砍的落 rejected——两边都有账可查
            try await assetStore.saveResultsOrThrow(results + reviewOutcome.dropped)
            let summary = recipeRunSummary(
                output: output,
                resultCount: results.count,
                truncatedCount: inputOutcome.truncatedCount,
                widenedCount: widenedResults.count,
                reviewDroppedCount: reviewOutcome.droppedCount,
                reviewSkipped: reviewOutcome.skipped
            )
            let finishedRun = runningRun.advanced(
                finishedAt: Date(),
                status: .succeeded,
                resultCount: results.count,
                summary: summary
            )
            await assetStore.insert(run: finishedRun)
            await assetStore.logAction(
                actionType: .extractionSucceeded,
                detail: summary
            )
            logger.info("Recipe extraction succeeded with \(results.count) results")
            return RecipeExtractionRunResult(run: finishedRun, results: results)
        } catch {
            let message = error is CancellationError
                ? L("已取消", "Cancelled")
                : error.localizedDescription
            let failedRun = createdRun.advanced(
                startedAt: Date(),
                finishedAt: Date(),
                sourceRecordCount: loadedSourceRecordCount,
                status: .failed,
                errorMessage: message
            )
            await assetStore.insert(run: failedRun)
            await assetStore.logAction(
                actionType: .extractionFailed,
                detail: message
            )
            logger.error("Recipe extraction failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// 提炼前预览：本地跑完取数+防重+过滤，零模型成本（改造方案 #7/#9）
    func previewExtraction(configuration: AssetExtractionConfiguration) async -> AssetExtractionPreview {
        let recipe = await assetStore.fetchRecipe(id: configuration.recipeID)
            ?? configuration.recipe
        // mapReduce 配方预览给全量(截断只在执行时的片级发生)——预览如实报告覆盖范围
        let fullCoverage = recipe.processingStrategy == .mapReduce
        guard recipe.outputKind == .assetCandidates else {
            let loadedRecords = await loadSourceRecords(configuration: configuration)
            let filtered = recipeInputRecords(
                from: loadedRecords,
                configuration: configuration,
                applyLimit: !fullCoverage
            )
            let totalCharacters = filtered.records.reduce(0) {
                $0 + min($1.finalText.count, configuration.maxCharactersPerRecord)
            }
            return AssetExtractionPreview(
                sourceCount: loadedRecords.count,
                excludedAsProcessedCount: 0,
                eligibleCount: filtered.records.count,
                truncatedCount: filtered.truncatedCount,
                totalCharacters: totalCharacters,
                records: filtered.records
            )
        }

        let loaded = await loadFreshSourceRecords(configuration: configuration)
        let filtered = candidateRecords(
            from: loaded.records,
            configuration: configuration,
            applyLimit: !fullCoverage
        )
        let totalCharacters = filtered.records.reduce(0) {
            $0 + min($1.finalText.count, configuration.maxCharactersPerRecord)
        }
        return AssetExtractionPreview(
            sourceCount: loaded.records.count + loaded.excludedAsProcessedCount,
            excludedAsProcessedCount: loaded.excludedAsProcessedCount,
            eligibleCount: filtered.records.count,
            truncatedCount: filtered.truncatedCount,
            totalCharacters: totalCharacters,
            records: filtered.records
        )
    }

    /// 取数 + 跨任务防重①：默认排除已被既有候选/资产引用过的记录；
    /// 手动点名或显式要求重新提炼时豁免——用户明确要重跑的记录不拦
    private func loadFreshSourceRecords(
        configuration: AssetExtractionConfiguration
    ) async -> (records: [HistoryRecord], excludedAsProcessedCount: Int) {
        let records = await loadSourceRecords(configuration: configuration)
        guard configuration.rangeType != .manualSelection,
              !configuration.includesProcessedRecords
        else {
            return (records, 0)
        }
        let referenced = await assetStore.referencedSourceRecordIDs()
        let fresh = records.filter { !referenced.contains($0.id) }
        return (fresh, records.count - fresh.count)
    }

    private func loadSourceRecords(configuration: AssetExtractionConfiguration) async -> [HistoryRecord] {
        switch configuration.rangeType {
        case .last1Day, .last7Days, .last30Days:
            guard let startDate = configuration.startDate,
                  let endDate = configuration.endDate
            else { return [] }
            return await historyStore.fetchBetween(start: startDate, end: endDate)
        case .lastNRecords:
            return await historyStore.fetchRecent(limit: configuration.maxRecordCount)
        case .manualSelection:
            return await historyStore.fetch(ids: configuration.selectedRecordIDs)
        }
    }

    /// 可进提炼的 history 状态：识别文本本身有效即可，注入结局（仅复制/没找到输入位置）不影响
    private static let extractableStatuses: Set<String> = ["completed", "copied_only", "no_input_target"]

    private func candidateRecords(
        from records: [HistoryRecord],
        configuration: AssetExtractionConfiguration,
        applyLimit: Bool = true
    ) -> (records: [HistoryRecord], truncatedCount: Int) {
        let filtered = records.filter { record in
            guard Self.extractableStatuses.contains(record.status) else { return false }
            let text = record.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            guard !configuration.enablesCandidateFiltering || text.count >= configuration.minimumCharacterCount else {
                return false
            }
            guard !configuration.enablesCandidateFiltering || !isLikelyLowValue(text) else {
                return false
            }
            return true
        }

        guard applyLimit else { return (filtered, 0) }

        let eligible = Array(filtered.prefix(configuration.maxRecordCount))
        var totalCharacters = 0
        var result: [HistoryRecord] = []
        for record in eligible {
            let charCount = min(record.finalText.count, configuration.maxCharactersPerRecord)
            guard totalCharacters + charCount <= configuration.maxTotalInputCharacters || result.isEmpty else {
                break
            }
            result.append(record)
            totalCharacters += charCount
        }
        // 因 1.2 万字输入上限被丢弃的条数——预览与 Job 摘要都要明示，不再静默截断
        return (result, eligible.count - result.count)
    }

    private func recipeInputRecords(
        from records: [HistoryRecord],
        configuration: AssetExtractionConfiguration,
        applyLimit: Bool = true
    ) -> (records: [HistoryRecord], truncatedCount: Int) {
        let filtered = records.filter { record in
            guard Self.extractableStatuses.contains(record.status) else { return false }
            return !record.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // mapReduce 全量分片时不做单次调用截断——「近 30 天」就该是 30 天全量,
        // 单次上限只在片级生效(2026-07 修:3932 条只吃 100 条的覆盖率漏洞)
        guard applyLimit else { return (filtered, 0) }

        let eligible = Array(filtered.prefix(configuration.maxRecordCount))
        var totalCharacters = 0
        var result: [HistoryRecord] = []
        for record in eligible {
            let charCount = min(record.finalText.count, configuration.maxCharactersPerRecord)
            guard totalCharacters + charCount <= configuration.maxTotalInputCharacters || result.isEmpty else {
                break
            }
            result.append(record)
            totalCharacters += charCount
        }
        return (result, eligible.count - result.count)
    }

    /// 全量语料按「单次调用装得下」的双限(条数+字符)切片
    private func chunkedForSingleCall(
        _ records: [HistoryRecord],
        configuration: AssetExtractionConfiguration
    ) -> [[HistoryRecord]] {
        var chunks: [[HistoryRecord]] = []
        var current: [HistoryRecord] = []
        var characters = 0
        for record in records {
            let charCount = min(record.finalText.count, configuration.maxCharactersPerRecord)
            if !current.isEmpty,
               current.count >= configuration.maxRecordCount
                || characters + charCount > configuration.maxTotalInputCharacters {
                chunks.append(current)
                current = []
                characters = 0
            }
            current.append(record)
            characters += charCount
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func extractionResults(
        from candidates: [LanguageAssetCandidateRecord],
        run: ExtractionRun,
        outputKind: ExtractionOutputKind
    ) -> [ExtractionResult] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let now = Date()

        return candidates.map { candidate in
            ExtractionResult(
                id: candidate.id,
                runID: run.id,
                recipeID: run.recipeID,
                createdAt: now,
                updatedAt: now,
                outputKind: outputKind,
                title: candidate.title,
                content: candidate.content,
                summary: candidate.summary,
                payloadJSON: encodePayload(candidate, encoder: encoder),
                sourceRecordIDs: candidate.sourceRecordIDs,
                sourceRecordCount: candidate.sourceRecordCount,
                status: .active
            )
        }
    }

    private func encodePayload<T: Encodable>(_ value: T, encoder: JSONEncoder) -> String {
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    private func normalizeRecipeResults(
        output: RecipeExtractionOutput,
        sourceRecords: [HistoryRecord],
        recipe: ExtractionRecipe,
        run: ExtractionRun
    ) -> [ExtractionResult] {
        let sourceMap = Dictionary(uniqueKeysWithValues: sourceRecords.map { ($0.id, $0) })
        let allowedIDs = Set(sourceMap.keys)
        let now = Date()
        var seenKeys = Set<String>()

        return output.results.compactMap { draft in
            let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }

            let sourceIDs = draft.sourceRecordIDs.filter { allowedIDs.contains($0) }
            guard !sourceIDs.isEmpty else { return nil }

            if recipe.sourcePolicy == .strictQuote {
                let sourceText = sourceIDs
                    .compactMap { sourceMap[$0]?.finalText }
                    .joined(separator: "\n")
                guard sourceText.contains(content) else { return nil }
            }

            let dedupeKey = "\(recipe.id)|\(content.lowercased())"
            guard !seenKeys.contains(dedupeKey) else { return nil }
            seenKeys.insert(dedupeKey)

            let title = nonEmpty(draft.title)
                ?? String(content.prefix(28))

            return ExtractionResult(
                id: UUID().uuidString,
                runID: run.id,
                recipeID: recipe.id,
                createdAt: now,
                updatedAt: now,
                outputKind: recipe.outputKind,
                title: title,
                content: content,
                summary: nonEmpty(draft.summary),
                payloadJSON: validPayloadJSON(draft.payloadJSON),
                sourceRecordIDs: sourceIDs,
                sourceRecordCount: sourceIDs.count,
                status: .pending
            )
        }
    }

    // MARK: - 宽提段（2026-07 全量分片：解决「近 30 天只吃 100 条」覆盖率漏洞）

    /// mapReduce 配方全量分片宽提(4 路并发,单片失败跳过不废全局)；whole 配方单次调用
    private func widenedOutput(
        sourceRecords: [HistoryRecord],
        recipe: ExtractionRecipe,
        configuration: AssetExtractionConfiguration,
        fullCoverage: Bool
    ) async throws -> RecipeExtractionOutput {
        let chunks = fullCoverage
            ? chunkedForSingleCall(sourceRecords, configuration: configuration)
            : [sourceRecords]

        guard chunks.count > 1 else {
            return try await recipeProvider.extractResults(
                from: chunks.first ?? sourceRecords,
                recipe: recipe,
                configuration: configuration
            )
        }

        logger.info("Full-coverage widening: \(sourceRecords.count) records in \(chunks.count) chunks")
        let provider = recipeProvider
        let outputs: [(Int, RecipeExtractionOutput?)] = await withTaskGroup(
            of: (Int, RecipeExtractionOutput?).self
        ) { group in
            var collected: [(Int, RecipeExtractionOutput?)] = []
            var nextIndex = 0
            let maxConcurrent = 4

            func addTask(_ index: Int) {
                group.addTask {
                    // 单片失败(网络抖动等)不废全局：fail-soft 跳过,覆盖率损失记账
                    let output = try? await provider.extractResults(
                        from: chunks[index],
                        recipe: recipe,
                        configuration: configuration
                    )
                    return (index, output)
                }
            }

            while nextIndex < min(maxConcurrent, chunks.count) {
                addTask(nextIndex)
                nextIndex += 1
            }
            while let item = await group.next() {
                collected.append(item)
                if nextIndex < chunks.count {
                    addTask(nextIndex)
                    nextIndex += 1
                }
            }
            return collected
        }

        let failedChunks = outputs.filter { $0.1 == nil }.count
        if failedChunks > 0 {
            DebugFileLogger.log("[提炼宽提] \(chunks.count) 片中 \(failedChunks) 片调用失败被跳过")
        }
        let drafts = outputs
            .sorted { $0.0 < $1.0 }
            .compactMap(\.1)
            .flatMap(\.results)
        let summary = failedChunks > 0
            ? L("全量扫描 \(chunks.count) 片(\(failedChunks) 片失败跳过)", "\(chunks.count) chunks scanned (\(failedChunks) failed)")
            : L("全量扫描 \(chunks.count) 片", "\(chunks.count) chunks scanned")
        return RecipeExtractionOutput(results: drafts, summary: summary)
    }

    // MARK: - 严审段（2026-07 重构批二）

    private struct ReviewOutcome {
        let kept: [ExtractionResult]
        /// 严审砍掉的产物（status=rejected 落库：UI 可翻砍单、可捞回，防错杀防黑箱）
        let dropped: [ExtractionResult]
        /// 配方没写标准或严审调用失败时为 true：产物直落待确认，不冒充「已过筛」
        let skipped: Bool

        var droppedCount: Int { dropped.count }
    }

    /// 两段式第二段：拿配方入库/忽略标准逐条判决。
    /// 失败兜底 fail-open：严审挂了全部保留进待确认（标注未过筛），绝不弄丢宽提产物
    private func reviewResults(
        _ results: [ExtractionResult],
        recipe: ExtractionRecipe
    ) async -> ReviewOutcome {
        guard !results.isEmpty else {
            return ReviewOutcome(kept: [], dropped: [], skipped: false)
        }

        // 2026-07 重设计：严审标准=配方统一 Prompt(用户可见即生效)；写了要求就有严审
        guard !recipe.unifiedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.info("Recipe \(recipe.id) has no prompt; skip review")
            return ReviewOutcome(kept: results, dropped: [], skipped: true)
        }

        do {
            let verdicts = try await reviewProvider.review(results: results, recipe: recipe)
            let verdictByIndex = Dictionary(
                uniqueKeysWithValues: verdicts.map { ($0.index, $0) }
            )

            var kept: [ExtractionResult] = []
            var dropped: [ExtractionResult] = []
            for (index, result) in results.enumerated() {
                guard let verdict = verdictByIndex[index] else {
                    // 评审漏判：保留待人工判断（fail-open 防错杀）
                    var unreviewed = result
                    unreviewed.reviewReason = L("评审未覆盖，保留待人工判断", "Not covered by review; kept for manual check")
                    kept.append(unreviewed)
                    continue
                }
                if verdict.keep {
                    var reviewed = result
                    reviewed.score = verdict.score
                    reviewed.reviewReason = nonEmpty(verdict.reason)
                    kept.append(reviewed)
                } else {
                    // 砍单也落库(rejected)：UI 可翻、可捞回——严审从黑箱变明账
                    var rejected = result
                    rejected.status = .rejected
                    rejected.score = verdict.score
                    rejected.reviewReason = nonEmpty(verdict.reason)
                    dropped.append(rejected)
                    DebugFileLogger.log(
                        "[提炼严审] 砍掉「\(result.title)」: \(verdict.reason ?? "未给理由") (score=\(verdict.score.map { String(Int($0)) } ?? "-"))"
                    )
                }
            }
            logger.info("Review kept \(kept.count)/\(results.count) results")
            return ReviewOutcome(kept: kept, dropped: dropped, skipped: false)
        } catch {
            logger.error("Review failed, fail-open: \(error.localizedDescription)")
            DebugFileLogger.log("[提炼严审] 严审调用失败，产物未过筛直落待确认: \(String(describing: error))")
            let unreviewed = results.map { result -> ExtractionResult in
                var copy = result
                copy.reviewReason = L("严审失败，未过筛", "Review failed; not screened")
                return copy
            }
            return ReviewOutcome(kept: unreviewed, dropped: [], skipped: true)
        }
    }

    private func validPayloadJSON(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            return "{}"
        }
        return trimmed
    }

    private func recipeRunSummary(
        output: RecipeExtractionOutput,
        resultCount: Int,
        truncatedCount: Int,
        widenedCount: Int = 0,
        reviewDroppedCount: Int = 0,
        reviewSkipped: Bool = false
    ) -> String {
        var base = nonEmpty(output.summary)
            ?? L("生成结果 \(resultCount) 条", "\(resultCount) results generated")
        if reviewSkipped, widenedCount > 0 {
            base += L("；严审未执行(\(widenedCount) 条未过筛)", "; review skipped (\(widenedCount) unscreened)")
        } else if widenedCount > 0 {
            base += L(
                "；宽提 \(widenedCount) 条、严审砍 \(reviewDroppedCount) 条、留 \(resultCount) 条待确认",
                "; widened \(widenedCount), review dropped \(reviewDroppedCount), \(resultCount) pending"
            )
        }
        guard truncatedCount > 0 else { return base }
        return base + L(
            "；因输入上限丢弃 \(truncatedCount) 条",
            "; \(truncatedCount) dropped over input limit"
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 低价值判定（改造方案 #10）：原实现是短语全等匹配（"好的好的"都漏过），
    /// 改为「去掉标点空白后很短、且全部由语气/应答字符构成」才过滤——
    /// 本地先剔掉纯寒暄，省一截 LLM token，真实内容绝不误伤
    func isLikelyLowValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("�") { return true }

        let meaningful = trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        if meaningful.isEmpty { return true }

        guard meaningful.count <= 8 else { return false }
        let fillerCharacters: Set<Character> = [
            "好", "的", "收", "到", "嗯", "啊", "哦", "噢", "喔", "哈", "呀", "呢",
            "吧", "哎", "唉", "额", "呃", "嘿", "诶", "对", "行", "是",
            "o", "k", "a", "y", "e", "s", "n"
        ]
        let stripped = String(String.UnicodeScalarView(meaningful)).lowercased()
        return stripped.allSatisfy { fillerCharacters.contains($0) }
    }

    private func buildSummary(for candidates: [LanguageAssetCandidateRecord]) -> String {
        let grouped = Dictionary(grouping: candidates, by: \.assetType)
        let questions = grouped[.question]?.count ?? 0
        let viewpoints = grouped[.viewpoint]?.count ?? 0
        let frameworks = grouped[.framework]?.count ?? 0
        let caseMaterials = grouped[.caseMaterial]?.count ?? 0
        let quotes = grouped[.quote]?.count ?? 0
        return L(
            "发现候选：问题 \(questions) 条，观点 \(viewpoints) 条，框架 \(frameworks) 条，案例 \(caseMaterials) 条，金句 \(quotes) 条",
            "Candidates found: \(questions) questions, \(viewpoints) viewpoints, \(frameworks) frameworks, \(caseMaterials) cases, \(quotes) quotes"
        )
    }

    private func extractionStartedDetail(
        configuration: AssetExtractionConfiguration,
        sourceCount: Int,
        candidateCount: Int
    ) -> String {
        let providerName = KeychainService.selectedAssetExtractionLLMProvider.displayName
        let rangeTitle: String
        switch configuration.rangeType {
        case .last1Day:
            rangeTitle = L("最近 1 天", "Last day")
        case .last7Days:
            rangeTitle = L("最近 7 天", "Last 7 days")
        case .last30Days:
            rangeTitle = L("最近 30 天", "Last 30 days")
        case .lastNRecords:
            rangeTitle = L("最近 \(configuration.maxRecordCount) 条", "Recent \(configuration.maxRecordCount)")
        case .manualSelection:
            rangeTitle = L("手动选择", "Manual selection")
        }

        return L(
            "开始提炼：范围 \(rangeTitle)，源记录 \(sourceCount) 条，候选 \(candidateCount) 条，模型 \(providerName)",
            "Extraction started: \(rangeTitle), \(sourceCount) source records, \(candidateCount) candidates, provider \(providerName)"
        )
    }

    private func recipeExtractionStartedDetail(
        recipe: ExtractionRecipe,
        configuration: AssetExtractionConfiguration,
        sourceCount: Int,
        inputCount: Int
    ) -> String {
        let providerName = KeychainService.selectedAssetExtractionLLMProvider.displayName
        let rangeTitle: String
        switch configuration.rangeType {
        case .last1Day:
            rangeTitle = L("最近 1 天", "Last day")
        case .last7Days:
            rangeTitle = L("最近 7 天", "Last 7 days")
        case .last30Days:
            rangeTitle = L("最近 30 天", "Last 30 days")
        case .lastNRecords:
            rangeTitle = L("最近 \(configuration.maxRecordCount) 条", "Recent \(configuration.maxRecordCount)")
        case .manualSelection:
            rangeTitle = L("手动选择", "Manual selection")
        }

        return L(
            "开始提炼：方案 \(recipe.name)，范围 \(rangeTitle)，源记录 \(sourceCount) 条，输入 \(inputCount) 条，模型 \(providerName)",
            "Extraction started: recipe \(recipe.name), \(rangeTitle), \(sourceCount) source records, \(inputCount) inputs, provider \(providerName)"
        )
    }
}

// MARK: - Run 状态推进（J15：五处全字段重建收敛，未给字段默认值即沿用当前值）

private extension ExtractionRun {
    func advanced(
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        sourceRecordCount: Int? = nil,
        status: ExtractionRunStatus,
        resultCount: Int = 0,
        summary: String? = nil,
        errorMessage: String? = nil
    ) -> ExtractionRun {
        ExtractionRun(
            id: id,
            recipeID: recipeID,
            recipeName: recipeName,
            createdAt: createdAt,
            startedAt: startedAt ?? self.startedAt,
            finishedAt: finishedAt,
            rangeType: rangeType,
            rangePayload: rangePayload,
            sourceRecordCount: sourceRecordCount ?? self.sourceRecordCount,
            status: status,
            resultCount: resultCount,
            summary: summary,
            errorMessage: errorMessage
        )
    }
}
