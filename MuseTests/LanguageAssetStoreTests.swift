import XCTest
import SQLite3
@testable import Muse

final class LanguageAssetStoreTests: XCTestCase {

    private var store: LanguageAssetStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-assets-\(UUID().uuidString).db").path
        store = LanguageAssetStore(path: testPath)
    }

    override func tearDown() async throws {
        await store.deleteAll()
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testInsertJobAndFetchLatestJob() async {
        let job = AssetExtractionJob(
            id: UUID().uuidString,
            createdAt: Date(),
            startedAt: Date(),
            finishedAt: nil,
            rangeType: .lastNRecords,
            rangePayload: "limit=50",
            sourceRecordCount: 12,
            status: .running,
            summary: nil,
            errorMessage: nil
        )

        await store.insert(job: job)
        let latest = await store.latestJob()

        XCTAssertEqual(latest?.id, job.id)
        XCTAssertEqual(latest?.rangeType, .lastNRecords)
        XCTAssertEqual(latest?.sourceRecordCount, 12)
    }

    func testBuiltInRecipesAreSeeded() async {
        let recipes = await store.fetchRecipes()

        XCTAssertTrue(recipes.contains { $0.id == ExtractionRecipe.contentCreatorAssetsID })
        XCTAssertTrue(recipes.contains { $0.id == ExtractionRecipe.todayTodosID })
        XCTAssertTrue(recipes.contains { $0.id == ExtractionRecipe.dailyReportID })
        XCTAssertEqual(recipes.first?.isBuiltIn, true)
    }

    // MARK: - 2026-07 重构：配方标准 + 统一待确认状态机

    func testBuiltInRecipesCarrySaveAndIgnoreRules() async {
        let recipes = await store.fetchRecipes()

        for id in [
            ExtractionRecipe.quoteAssetsID,
            ExtractionRecipe.contentCreatorAssetsID,
            ExtractionRecipe.todayTodosID,
            ExtractionRecipe.dailyReportID,
        ] {
            let recipe = recipes.first { $0.id == id }
            XCTAssertNotNil(recipe, "内置配方 \(id) 应已 seed")
            XCTAssertFalse(recipe?.saveRule.isEmpty ?? true, "内置配方 \(id) 应带入库标准")
            XCTAssertFalse(recipe?.ignoreRule.isEmpty ?? true, "内置配方 \(id) 应带忽略标准")
        }
    }

    func testResultStatusLifecyclePendingToSavedAndDiscarded() async throws {
        let keep = makePendingResult(title: "留下的产物", score: 88, reviewReason: "对象明确，可独立复用")
        let drop = makePendingResult(title: "抛弃的产物", score: 55, reviewReason: "达标但用户不需要")
        try await store.saveResultsOrThrow([keep, drop])

        var pendingCount = await store.countResults(status: .pending)
        XCTAssertEqual(pendingCount, 2)

        await store.updateResultStatus(id: keep.id, to: .saved)
        await store.updateResultStatus(id: drop.id, to: .discarded)

        pendingCount = await store.countResults(status: .pending)
        let saved = await store.fetchResults(status: .saved)
        let discarded = await store.fetchResults(status: .discarded)

        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(saved.map(\.id), [keep.id])
        XCTAssertEqual(discarded.map(\.id), [drop.id])
    }

    func testResultReviewFieldsAndFavoriteRoundtrip() async throws {
        let result = makePendingResult(title: "带评审信息", score: 92.5, reviewReason: "原文连续片段，判断密度高")
        try await store.saveResultsOrThrow([result])

        let fetched = await store.fetchResults(status: .pending)
        XCTAssertEqual(fetched.first?.score, 92.5)
        XCTAssertEqual(fetched.first?.reviewReason, "原文连续片段，判断密度高")
        XCTAssertEqual(fetched.first?.isFavorite, false)

        await store.setResultFavorite(id: result.id, isFavorite: true)
        let favored = await store.fetchResults(status: .pending)
        XCTAssertEqual(favored.first?.isFavorite, true)
    }

    private func makePendingResult(
        title: String,
        score: Double?,
        reviewReason: String?
    ) -> ExtractionResult {
        ExtractionResult(
            id: UUID().uuidString,
            runID: "run-test",
            recipeID: ExtractionRecipe.quoteAssetsID,
            createdAt: Date(),
            updatedAt: Date(),
            outputKind: .assetCandidates,
            title: title,
            content: "测试内容：\(title)",
            summary: nil,
            payloadJSON: "{}",
            sourceRecordIDs: ["rec-1"],
            sourceRecordCount: 1,
            status: .pending,
            score: score,
            reviewReason: reviewReason
        )
    }

    func testSaveAndArchiveCustomRecipe() async throws {
        let recipe = ExtractionRecipe.custom(
            id: "custom.weekly-review",
            name: "周复盘",
            recipeDescription: "整理一周工作复盘",
            goalPrompt: "把语料整理成周复盘。",
            outputKind: .summary,
            processingStrategy: .whole,
            sourcePolicy: .citedSummary,
            outputSchema: "summary: {title, body, source_record_ids}",
            qualityRules: "必须基于原文。",
            destination: .resultArchive
        )

        try await store.saveRecipesOrThrow([recipe])
        let saved = await store.fetchRecipe(id: recipe.id)

        XCTAssertEqual(saved?.name, "周复盘")
        XCTAssertEqual(saved?.outputKind, .summary)
        XCTAssertFalse(saved?.isBuiltIn ?? true)
        let activeRecipes = await store.fetchRecipes()
        XCTAssertTrue(activeRecipes.contains { $0.id == recipe.id })

        await store.archiveRecipe(id: recipe.id)

        let activeRecipesAfterArchive = await store.fetchRecipes()
        let archivedRecipe = await store.fetchRecipe(id: recipe.id)
        XCTAssertFalse(activeRecipesAfterArchive.contains { $0.id == recipe.id })
        XCTAssertEqual(archivedRecipe?.status, .archived)
    }

    func testSaveFetchExtractionRunAndResults() async throws {
        let run = ExtractionRun(
            id: "run-1",
            recipeID: ExtractionRecipe.dailyReportID,
            recipeName: "工作日报",
            createdAt: Date(),
            startedAt: Date(),
            finishedAt: Date(),
            rangeType: .last1Day,
            rangePayload: "range",
            sourceRecordCount: 2,
            status: .succeeded,
            resultCount: 1,
            summary: "已生成日报",
            errorMessage: nil
        )
        let result = ExtractionResult(
            id: "result-1",
            runID: run.id,
            recipeID: run.recipeID,
            createdAt: Date(),
            updatedAt: Date(),
            outputKind: .dailyReport,
            title: "今日工作日报",
            content: "完成了语料提炼架构设计。",
            summary: "日报摘要",
            payloadJSON: #"{"sections":[]}"#,
            sourceRecordIDs: ["r1", "r2"],
            sourceRecordCount: 2,
            status: .active
        )

        await store.insert(run: run)
        try await store.saveResultsOrThrow([result])

        let latestRun = await store.latestRun()
        let results = await store.fetchResults(runID: run.id)

        XCTAssertEqual(latestRun?.recipeID, ExtractionRecipe.dailyReportID)
        XCTAssertEqual(latestRun?.resultCount, 1)
        XCTAssertEqual(results.map(\.id), ["result-1"])
        XCTAssertEqual(results.first?.sourceRecordIDs, ["r1", "r2"])
    }

    func testSaveFetchFavoriteAndSoftDeleteAsset() async {
        let asset = LanguageAsset(
            id: UUID().uuidString,
            createdAt: Date(),
            updatedAt: Date(),
            assetType: .question,
            grade: .a,
            title: "标题",
            content: "这是一个观点",
            summary: "一句话摘要",
            reason: "有明确痛点",
            scenes: ["标题选题"],
            audiences: ["内容创作者"],
            ruleHit: "好问题规则",
            keywords: ["观点", "方法"],
            sourceRecordIDs: ["r1", "r2"],
            sourceRecordCount: 2,
            extractionJobID: "job-1",
            isFavorite: false,
            status: .active
        )

        await store.saveAssets([asset])
        var assets = await store.fetchAll()
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?.content, "这是一个观点")
        XCTAssertEqual(assets.first?.assetType, .question)
        XCTAssertEqual(assets.first?.grade, .a)
        XCTAssertEqual(assets.first?.reason, "有明确痛点")
        XCTAssertEqual(assets.first?.scenes, ["标题选题"])
        XCTAssertEqual(assets.first?.audiences, ["内容创作者"])
        XCTAssertEqual(assets.first?.ruleHit, "好问题规则")

        await store.setFavorite(id: asset.id, isFavorite: true)
        assets = await store.fetchAll()
        XCTAssertEqual(assets.first?.isFavorite, true)

        await store.softDelete(id: asset.id)
        assets = await store.fetchAll()
        XCTAssertTrue(assets.isEmpty)
    }

    func testSaveCandidateAsAssetMarksCandidateSavedAndLogsAction() async {
        let candidate = makeCandidate(
            id: "candidate-1",
            scenes: ["标题选题", "内容结构"],
            audiences: ["内容创作者", "标题选题"]
        )
        await store.saveCandidates([candidate])

        let asset = await store.saveCandidateAsAsset(id: candidate.id)

        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.content, candidate.content)
        XCTAssertEqual(asset?.keywords, ["标题选题", "内容结构", "内容创作者"])
        let pendingCandidates = await store.fetchCandidates(status: .pending)
        let savedCandidateIDs = await store.fetchCandidates(status: .saved).map(\.id)
        XCTAssertEqual(pendingCandidates, [])
        XCTAssertEqual(savedCandidateIDs, [candidate.id])
        let assets = await store.fetchAll()
        XCTAssertEqual(assets.map(\.id), [asset?.id])
    }

    func testSaveEditedCandidateAsAssetUsesEditedFields() async {
        let candidate = makeCandidate(id: "candidate-edit")
        await store.saveCandidates([candidate])

        let edited = LanguageAssetCandidateRecord(
            id: candidate.id,
            createdAt: candidate.createdAt,
            updatedAt: Date(),
            assetType: .quote,
            grade: .b,
            title: "编辑后的金句",
            content: "真正能复用的表达，必须先经过人的判断。",
            summary: "人工判断优先",
            reason: "用户确认后才应该进入资产库",
            scenes: ["表达润色", "复盘"],
            audiences: ["内容创作者"],
            ruleHit: candidate.ruleHit,
            sourceRecordIDs: candidate.sourceRecordIDs,
            sourceRecordCount: candidate.sourceRecordCount,
            extractionJobID: candidate.extractionJobID,
            status: .pending
        )

        let asset = await store.saveEditedCandidateAsAsset(edited)

        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.assetType, .quote)
        XCTAssertEqual(asset?.grade, .b)
        XCTAssertEqual(asset?.title, "编辑后的金句")
        XCTAssertEqual(asset?.content, "真正能复用的表达，必须先经过人的判断。")
        XCTAssertEqual(asset?.summary, "人工判断优先")
        XCTAssertEqual(asset?.reason, "用户确认后才应该进入资产库")
        XCTAssertEqual(asset?.keywords, ["表达润色", "复盘", "内容创作者"])

        let savedCandidate = await store.fetchCandidates(status: .saved).first
        let pendingCandidates = await store.fetchCandidates(status: .pending)
        XCTAssertEqual(savedCandidate?.id, candidate.id)
        XCTAssertEqual(savedCandidate?.title, "编辑后的金句")
        XCTAssertEqual(pendingCandidates, [])
    }

    func testIgnoreCandidateMarksCandidateIgnoredAndLogsAction() async {
        let candidate = makeCandidate(id: "candidate-ignore")
        await store.saveCandidates([candidate])

        await store.ignoreCandidate(id: candidate.id)

        let pendingCandidates = await store.fetchCandidates(status: .pending)
        let ignoredCandidateIDs = await store.fetchCandidates(status: .ignored).map(\.id)
        XCTAssertEqual(pendingCandidates, [])
        XCTAssertEqual(ignoredCandidateIDs, [candidate.id])
    }

    func testClearPendingCandidatesKeepsIgnoredSavedAndAssets() async {
        let pendingOne = makeCandidate(id: "candidate-pending-1")
        let pendingTwo = makeCandidate(id: "candidate-pending-2")
        let ignored = makeCandidate(id: "candidate-ignored")
        let saved = makeCandidate(id: "candidate-saved")
        await store.saveCandidates([pendingOne, pendingTwo, ignored, saved])

        await store.ignoreCandidate(id: ignored.id)
        let asset = await store.saveCandidateAsAsset(id: saved.id)

        let deletedCount = await store.clearCandidates(status: .pending)
        let pendingCandidates = await store.fetchCandidates(status: .pending)
        let ignoredCandidateIDs = await store.fetchCandidates(status: .ignored).map(\.id)
        let savedCandidateIDs = await store.fetchCandidates(status: .saved).map(\.id)
        let assetIDs = await store.fetchAll().map(\.id)

        XCTAssertEqual(deletedCount, 2)
        XCTAssertEqual(pendingCandidates, [])
        XCTAssertEqual(ignoredCandidateIDs, [ignored.id])
        XCTAssertEqual(savedCandidateIDs, [saved.id])
        XCTAssertEqual(assetIDs, asset.map { [$0.id] } ?? [])
    }

    func testFetchAllSkipsRowsWithInvalidJSONPayloads() async throws {
        try insertInvalidJSONAssetRow(at: testPath)

        let assets = await store.fetchAll()

        XCTAssertTrue(assets.isEmpty)
    }

    func testAssetExtractionServiceMirrorsLegacyJobIntoDefaultRecipeRun() async throws {
        let historyStore = HistoryStore(path: testPath)
        let record = HistoryRecord(
            id: "history-1",
            createdAt: Date(),
            durationSeconds: 2,
            rawText: "原始文本",
            processingMode: nil,
            processedText: nil,
            finalText: "真正能复用的不是模板，而是你的判断路径。",
            status: "completed",
            characterCount: 20
        )
        await historyStore.insert(record)
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: MockAssetExtractionProvider()
        )

        let result = try await service.extractAssets(configuration: .recent(limit: 10))
        let latestRun = await store.latestRun()
        let extractionResults = await store.fetchResults(runID: latestRun?.id)

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(latestRun?.recipeID, ExtractionRecipe.contentCreatorAssetsID)
        XCTAssertEqual(latestRun?.recipeName, "内容创作素材")
        XCTAssertEqual(latestRun?.status, .succeeded)
        XCTAssertEqual(latestRun?.resultCount, 1)
        XCTAssertEqual(extractionResults.count, 1)
        XCTAssertEqual(extractionResults.first?.outputKind, .assetCandidates)
        XCTAssertEqual(extractionResults.first?.content, "真正能复用的不是模板，而是你的判断路径。")
    }

    func testLegacyAssetExtractionRejectsNonAssetRecipe() async throws {
        let historyStore = HistoryStore(path: testPath)
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: MockAssetExtractionProvider()
        )

        do {
            _ = try await service.extractAssets(
                configuration: AssetExtractionConfiguration
                    .recent(limit: 10)
                    .applying(recipeID: ExtractionRecipe.dailyReportID)
            )
            XCTFail("旧候选提炼执行器不应直接运行非资产 Recipe")
        } catch let error as AssetExtractionError {
            guard case .unsupportedRecipe(let recipeName) = error else {
                return XCTFail("应返回 unsupportedRecipe")
            }
            XCTAssertEqual(recipeName, "工作日报")
        }
    }

    func testRecipeExtractionSavesGenericResults() async throws {
        let historyStore = HistoryStore(path: testPath)
        let record = HistoryRecord(
            id: "todo-source-1",
            createdAt: Date(),
            durationSeconds: 2,
            rawText: "原始文本",
            processingMode: nil,
            processedText: nil,
            finalText: "明天要把语料资产的结果页做完，并验证提炼流程。",
            status: "completed",
            characterCount: 24
        )
        await historyStore.insert(record)
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: MockAssetExtractionProvider(),
            recipeProvider: MockRecipeExtractionProvider(),
            reviewProvider: MockExtractionReviewProvider(verdicts: [
                ExtractionReviewVerdict(index: 0, keep: true, score: 90, reason: "行动指向清晰，有原文依据")
            ])
        )

        let result = try await service.extractRecipeResults(
            configuration: AssetExtractionConfiguration
                .recent(limit: 10)
                .applying(recipeID: ExtractionRecipe.todayTodosID)
        )
        // 2026-07 重构批二：产物统一落待确认(pending)，由用户拍板入库/抛弃
        let savedResults = await store.fetchResults(runID: result.run.id, status: .pending)

        XCTAssertEqual(result.run.recipeID, ExtractionRecipe.todayTodosID)
        XCTAssertEqual(result.run.status, .succeeded)
        XCTAssertEqual(result.run.resultCount, 1)
        XCTAssertEqual(savedResults.count, 1)
        XCTAssertEqual(savedResults.first?.outputKind, .todoList)
        XCTAssertEqual(savedResults.first?.sourceRecordIDs, ["todo-source-1"])
        XCTAssertEqual(savedResults.first?.content, "把语料资产的结果页做完，并验证提炼流程。")
        XCTAssertEqual(savedResults.first?.score, 90)
        XCTAssertEqual(savedResults.first?.reviewReason, "行动指向清晰，有原文依据")
    }

    func testTwoStageReviewDropsFailingResults() async throws {
        let historyStore = HistoryStore(path: testPath)
        let record = HistoryRecord(
            id: "todo-source-2",
            createdAt: Date(),
            durationSeconds: 2,
            rawText: "原始文本",
            processingMode: nil,
            processedText: nil,
            finalText: "今天要做完结果页，还要验证提炼流程。对了今天天气不错。",
            status: "completed",
            characterCount: 28
        )
        await historyStore.insert(record)
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: MockAssetExtractionProvider(),
            recipeProvider: MockMultiDraftRecipeProvider(),
            reviewProvider: MockExtractionReviewProvider(verdicts: [
                ExtractionReviewVerdict(index: 0, keep: true, score: 88, reason: "明确待办"),
                ExtractionReviewVerdict(index: 1, keep: true, score: 82, reason: "明确待办"),
                ExtractionReviewVerdict(index: 2, keep: false, score: 20, reason: "命中忽略标准：闲聊无行动语义"),
            ])
        )

        let result = try await service.extractRecipeResults(
            configuration: AssetExtractionConfiguration
                .recent(limit: 10)
                .applying(recipeID: ExtractionRecipe.todayTodosID)
        )
        let pending = await store.fetchResults(runID: result.run.id, status: .pending)

        XCTAssertEqual(result.run.resultCount, 2, "严审应砍掉 1 条不达标产物")
        XCTAssertEqual(pending.count, 2)
        XCTAssertFalse(pending.contains { $0.title == "闲聊" }, "被严审砍掉的产物不应进待确认")
        XCTAssertTrue(result.run.summary?.contains("宽提 3") ?? false, "run 摘要应含两段统计: \(result.run.summary ?? "nil")")
        XCTAssertTrue(result.run.summary?.contains("砍 1") ?? false)

        // 砍单也落库(rejected)：可翻、可捞回，捞回后回到待确认
        let rejected = await store.fetchResults(runID: result.run.id, status: .rejected)
        XCTAssertEqual(rejected.map(\.title), ["闲聊"])
        XCTAssertEqual(rejected.first?.reviewReason, "命中忽略标准：闲聊无行动语义")
        if let rejectedID = rejected.first?.id {
            await store.updateResultStatus(id: rejectedID, to: .pending)
            let restored = await store.fetchResults(runID: result.run.id, status: .pending)
            XCTAssertEqual(restored.count, 3, "捞回后应回到待确认")
        }
    }

    func testReviewFailOpenKeepsAllResultsPending() async throws {
        let historyStore = HistoryStore(path: testPath)
        let record = HistoryRecord(
            id: "todo-source-3",
            createdAt: Date(),
            durationSeconds: 2,
            rawText: "原始文本",
            processingMode: nil,
            processedText: nil,
            finalText: "今天要做完结果页，还要验证提炼流程。对了今天天气不错。",
            status: "completed",
            characterCount: 28
        )
        await historyStore.insert(record)
        let service = AssetExtractionService(
            historyStore: historyStore,
            assetStore: store,
            provider: MockAssetExtractionProvider(),
            recipeProvider: MockMultiDraftRecipeProvider(),
            reviewProvider: MockExtractionReviewProvider(shouldThrow: true)
        )

        let result = try await service.extractRecipeResults(
            configuration: AssetExtractionConfiguration
                .recent(limit: 10)
                .applying(recipeID: ExtractionRecipe.todayTodosID)
        )
        let pending = await store.fetchResults(runID: result.run.id, status: .pending)

        XCTAssertEqual(pending.count, 3, "严审失败必须 fail-open：宽提产物一条不丢")
        XCTAssertTrue(
            pending.allSatisfy { $0.reviewReason?.contains(L("严审失败", "Review failed")) ?? false },
            "未过筛产物应标注严审失败"
        )
        XCTAssertTrue(result.run.summary?.contains(L("严审未执行", "review skipped")) ?? false)
    }

    private func makeCandidate(
        id: String,
        scenes: [String] = ["复盘"],
        audiences: [String] = ["创作者"]
    ) -> LanguageAssetCandidateRecord {
        LanguageAssetCandidateRecord(
            id: id,
            createdAt: Date(),
            updatedAt: Date(),
            assetType: .question,
            grade: .a,
            title: "一个好问题",
            content: "如何稳定地产出高质量内容？",
            summary: "内容生产问题",
            reason: "有明确痛点",
            scenes: scenes,
            audiences: audiences,
            ruleHit: "好问题规则",
            sourceRecordIDs: ["r1", "r2"],
            sourceRecordCount: 2,
            extractionJobID: "job-1",
            status: .pending
        )
    }

    private struct MockAssetExtractionProvider: AssetExtractionProvider {
        func extractAssets(
            from records: [HistoryRecord],
            configuration: AssetExtractionConfiguration
        ) async throws -> AssetExtractionResult {
            AssetExtractionResult(
                assets: [
                    AssetExtractionCandidate(
                        type: .quote,
                        grade: .a,
                        title: "判断路径",
                        content: "真正能复用的不是模板，而是你的判断路径。",
                        summary: nil,
                        reason: "原文短句有复用价值",
                        keywords: [],
                        sourceRecordIDs: [records.first?.id ?? ""]
                    )
                ]
            )
        }
    }

    private struct MockRecipeExtractionProvider: RecipeExtractionProvider {
        func extractResults(
            from records: [HistoryRecord],
            recipe: ExtractionRecipe,
            configuration: AssetExtractionConfiguration
        ) async throws -> RecipeExtractionOutput {
            RecipeExtractionOutput(
                results: [
                    RecipeExtractionDraft(
                        title: "完成结果页",
                        content: "把语料资产的结果页做完，并验证提炼流程。",
                        summary: "开发待办",
                        payloadJSON: #"{"priority":"P1"}"#,
                        sourceRecordIDs: [records.first?.id ?? "", "missing-source"]
                    )
                ],
                summary: "生成待办 1 条"
            )
        }
    }

    private struct MockExtractionReviewProvider: ExtractionReviewProvider {
        var verdicts: [ExtractionReviewVerdict] = []
        var shouldThrow = false

        func review(
            results: [ExtractionResult],
            recipe: ExtractionRecipe
        ) async throws -> [ExtractionReviewVerdict] {
            if shouldThrow {
                throw AssetExtractionError.invalidProviderResponse("mock review failure")
            }
            return verdicts
        }
    }

    /// 宽提段 mock：返回 2 条真待办 + 1 条闲聊，供严审段砍
    private struct MockMultiDraftRecipeProvider: RecipeExtractionProvider {
        func extractResults(
            from records: [HistoryRecord],
            recipe: ExtractionRecipe,
            configuration: AssetExtractionConfiguration
        ) async throws -> RecipeExtractionOutput {
            let sourceID = records.first?.id ?? ""
            return RecipeExtractionOutput(
                results: [
                    RecipeExtractionDraft(
                        title: "完成结果页",
                        content: "把语料资产的结果页做完。",
                        summary: nil,
                        payloadJSON: nil,
                        sourceRecordIDs: [sourceID]
                    ),
                    RecipeExtractionDraft(
                        title: "验证提炼流程",
                        content: "验证提炼流程可用。",
                        summary: nil,
                        payloadJSON: nil,
                        sourceRecordIDs: [sourceID]
                    ),
                    RecipeExtractionDraft(
                        title: "闲聊",
                        content: "今天天气不错。",
                        summary: nil,
                        payloadJSON: nil,
                        sourceRecordIDs: [sourceID]
                    ),
                ],
                summary: "宽提取生成 3 条候选"
            )
        }
    }

    private func insertInvalidJSONAssetRow(at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO language_asset
        (id, created_at, updated_at, asset_type, grade, title, content, summary, reason, scenes_json, audiences_json, rule_hit, keywords_json, source_record_ids_json, source_record_count, extraction_job_id, is_favorite, status)
        VALUES
        ('bad-json', '\(now)', '\(now)', 'question', 'A', '坏 JSON', '内容', NULL, '原因', 'not-json', '[]', NULL, '[]', '[]', 0, NULL, 0, 'active');
        """

        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}
