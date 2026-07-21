import SwiftUI

/// 提炼编排 ViewModel（2026-07-09 J13 拆分段）：提炼状态机与配置组装从
/// AssetLibraryTab 抽出；sheet 呈现、页面跳转与数据刷新仍归 View，
/// 由 View 根据 RunOutcome 收尾。
@MainActor
@Observable
final class AssetLibraryExtractionViewModel {

    /// 一次提炼执行的结局，View 据此收尾（关弹窗 / 刷新 / 跳待确认 / 报错）
    enum RunOutcome {
        case completed
        case cancelled
        case failed(String)
        /// 范围内无新内容：emptyNotice 已就地设置，弹窗退回选择态
        case emptyRange
        /// 守卫拦下（已在提炼中 / 无 LLM 配置 / 空配方），无状态变化
        case notStarted
    }

    var isExtracting = false
    var progressPhase: AssetExtractionProgressStage = .preparing
    var recipeID: String = ExtractionRecipe.quoteAssetsID
    var recipeIDs: Set<String> = [ExtractionRecipe.quoteAssetsID]
    var range: AssetExtractionRangeOption = .loadSaved()
    /// 提炼范围无新内容时在弹窗内就地提示（2026-07-08：弹窗承载全部提炼状态）
    var emptyNotice: String?

    @ObservationIgnored private var runningTask: Task<RunOutcome, Never>?
    @ObservationIgnored private let extractionService = AssetExtractionService()

    var hasLLMConfig: Bool {
        KeychainService.loadAssetExtractionLLMConfig() != nil
    }

    func cancelExtraction() {
        runningTask?.cancel()
    }

    /// 多配方提炼（2026-07 重设计）：记住本次选择并持久化范围，
    /// 逐配方各自预览(防重/空范围)后并入一次执行
    func runRecipesExtraction(
        selectedRecipeIDs: Set<String>,
        range: AssetExtractionRangeOption,
        recipes: [ExtractionRecipe],
        ruleConfig: AssetExtractionRuleConfig
    ) async -> RunOutcome {
        let orderedIDs = orderedRecipeIDs(from: selectedRecipeIDs, recipes: recipes)
        recipeIDs = selectedRecipeIDs
        recipeID = orderedIDs.first ?? ExtractionRecipe.quoteAssetsID
        self.range = range
        emptyNotice = nil
        range.save()

        guard !isExtracting, hasLLMConfig, !orderedIDs.isEmpty else { return .notStarted }
        // 立即进提炼态：弹窗原地切「提炼中」（预览阶段也算准备中，同时防按钮连点重复发起）
        isExtracting = true
        progressPhase = .preparing

        var configurations: [AssetExtractionConfiguration] = []
        do {
            for recipeID in orderedIDs {
                guard let base = makeExtractionConfiguration(
                    recipeID: recipeID,
                    range: range,
                    includesProcessedRecords: false
                ) else { continue }

                let preview = try await extractionService.previewExtraction(
                    configuration: base.applying(ruleConfig: ruleConfig)
                )
                guard !preview.records.isEmpty else { continue }

                configurations.append(
                    AssetExtractionConfiguration
                        .manualSelection(ids: preview.records.map(\.id))
                        .applying(recipeID: recipeID)
                        .adaptedForAssetExtractionProvider(KeychainService.selectedAssetExtractionLLMProvider)
                )
            }
        } catch {
            isExtracting = false
            emptyNotice = nil
            return .failed(error.localizedDescription)
        }

        guard !configurations.isEmpty else {
            // 弹窗内就地提示并退回选择态，让用户直接换范围重试
            isExtracting = false
            emptyNotice = L("范围内没有可提炼的新内容，换个范围试试。", "No new records in this range — try another.")
            return .emptyRange
        }
        return await runExtractions(configurations: configurations, ruleConfig: ruleConfig)
    }

    /// 配方选中态归一（原 normalizeSelections 的配方段）：配方增删后清掉失效选中
    func normalizeRecipeSelection(recipes: [ExtractionRecipe]) {
        if !recipes.contains(where: { $0.id == recipeID }) {
            recipeID = ExtractionRecipe.quoteAssetsID
        }
        recipeIDs = recipeIDs.filter { id in
            recipes.contains(where: { $0.id == id })
        }
        if recipeIDs.isEmpty {
            recipeIDs = [recipeID]
        }
    }

    // MARK: - Private

    private func orderedRecipeIDs(from ids: Set<String>, recipes: [ExtractionRecipe]) -> [String] {
        recipes.map(\.id).filter { ids.contains($0) }
    }

    private func makeExtractionConfiguration(
        recipeID: String,
        range: AssetExtractionRangeOption,
        includesProcessedRecords: Bool
    ) -> AssetExtractionConfiguration? {
        range.makeConfiguration()?
            .includingProcessedRecords(includesProcessedRecords)
            .applying(recipeID: recipeID)
            .adaptedForAssetExtractionProvider(KeychainService.selectedAssetExtractionLLMProvider)
    }

    /// 执行提炼（调用前须已置 isExtracting = true）：进度在提炼弹窗内呈现，
    /// 结束（成功/取消/失败）一律由 View 收尾（关弹窗，成功跳待确认，2026-07-08 大梁老师）
    private func runExtractions(
        configurations: [AssetExtractionConfiguration],
        ruleConfig: AssetExtractionRuleConfig
    ) async -> RunOutcome {
        let task = Task { @MainActor () -> RunOutcome in
            do {
                // 2026-07 重构批三：所有配方统一走两段式管线（宽提+严审），产物落待确认
                for configuration in configurations {
                    try Task.checkCancellation()
                    let effectiveConfiguration = configuration.applying(ruleConfig: ruleConfig)
                    _ = try await extractionService.extractRecipeResults(
                        configuration: effectiveConfiguration
                    ) { stage in
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                self.progressPhase = stage
                            }
                        }
                    }
                }
                return .completed
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        runningTask = task
        let outcome = await task.value
        isExtracting = false
        runningTask = nil
        return outcome
    }
}
