import AppKit
import SwiftUI

struct AssetLibraryTab: View, SettingsCardHelpers {
    @State private var assets: [LanguageAsset] = []
    @State private var pendingCandidates: [LanguageAssetCandidateRecord] = []
    @State private var ignoredCandidates: [LanguageAssetCandidateRecord] = []
    @State private var candidateStatusFilter: AssetCandidateStatusFilter = .pending
    @State private var sourceRecordMap: [String: HistoryRecord] = [:]
    // 2026-07-09 J13 拆分段：提炼编排状态机在 ViewModel，侧栏选中态在值结构
    @State private var extraction = AssetLibraryExtractionViewModel()
    @State private var selection = AssetLibrarySelectionState()
    @State private var errorMessage: String?
    @State private var selectedView: PurifierView = .extract
    // 2026-07 重构批三：四区数据
    @State private var pendingResults: [ExtractionResult] = []
    @State private var savedResults: [ExtractionResult] = []
    @State private var rejectedResults: [ExtractionResult] = []
    @State private var recentRuns: [ExtractionRun] = []
    @State private var pendingQuery = ""
    @State private var selectedPendingResultID: String?
    @State private var totalRecordCount = 0
    @State private var recipes: [ExtractionRecipe] = ExtractionRecipe.builtInRecipes()
    @State private var archivedRecipes: [ExtractionRecipe] = []
    @State private var recipeQuery = ""
    @State private var candidateQuery = ""
    @State private var libraryQuery = ""
    @State private var extractionResults: [ExtractionResult] = []
    @State private var resultQuery = ""
    @State private var ruleConfig: AssetExtractionRuleConfig = AssetExtractionRuleConfigStore.load()
    @State private var copiedAssetID: String?
    @State private var activeSheet: AssetLibrarySheet?
    @State private var isClearPendingConfirmationPresented = false

    private let assetStore = LanguageAssetStore()
    private let historyStore = HistoryStore()

    var body: some View {
        GeometryReader { geometry in
            let maximumPanelHeight = max(
                geometry.size.height - AssetLibraryStyle.toolbarHeight - AssetLibraryStyle.sectionSpacing,
                0
            )

            VStack(alignment: .leading, spacing: AssetLibraryStyle.sectionSpacing) {
                purifierToolbar
                    .frame(height: AssetLibraryStyle.toolbarHeight)

                switch selectedView {
                case .extract:
                    extractView
                        .frame(height: maximumPanelHeight, alignment: .topLeading)
                case .pending:
                    pendingReviewView
                        .frame(height: maximumPanelHeight, alignment: .topLeading)
                case .library:
                    libraryView
                        .frame(height: maximumPanelHeight, alignment: .topLeading)
                case .recipes:
                    recipesView
                        .frame(height: maximumPanelHeight, alignment: .topLeading)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await reloadData()
        }
        .onChange(of: ruleConfig) { _, newValue in
            AssetExtractionRuleConfigStore.save(newValue)
        }
        .onChange(of: candidateQuery) { _, _ in
            normalizeSelections()
        }
        .onChange(of: libraryQuery) { _, _ in
            normalizeSelections()
        }
        .onChange(of: resultQuery) { _, _ in
            normalizeSelections()
        }
        .onChange(of: recipeQuery) { _, _ in
            normalizeSelections()
        }
        .onReceive(NotificationCenter.default.publisher(for: .languageAssetStoreDidChange)) { _ in
            Task { await reloadData() }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .candidateSources(let candidate):
                CandidateSourceRecordsSheet(
                    candidate: candidate,
                    records: sourceRecords(for: candidate)
                )
            case .resultSources(let result):
                ExtractionResultSourceRecordsSheet(
                    result: result,
                    records: sourceRecords(for: result)
                )
            case .candidateEditor(let candidate):
                CandidateEditSheet(
                    candidate: candidate,
                    onCancel: { activeSheet = nil },
                    onSave: { editedCandidate in
                        activeSheet = nil
                        saveEditedCandidate(editedCandidate)
                    }
                )
            case .recipeEditor(let recipe):
                ExtractionRecipeEditorSheet(
                    recipe: recipe,
                    onCancel: { activeSheet = nil },
                    onSave: { recipe in
                        activeSheet = nil
                        saveRecipe(recipe)
                    }
                )
            case .extractionRangeSelection:
                // 2026-07 重设计：任意配方多选提炼，不再金句专属。
                // 2026-07-08 大梁老师：开始后弹窗不关、原地显示提炼中；完成后关窗跳待确认
                AssetExtractionRangeSelectionSheet(
                    recipes: recipes,
                    selectedRecipeIDs: extraction.recipeIDs,
                    selectedRange: extraction.range,
                    isExtracting: extraction.isExtracting,
                    progressPhase: extraction.progressPhase,
                    emptyNotice: extraction.emptyNotice,
                    onConfirm: { recipeIDs, range in
                        Task { @MainActor in
                            await runRecipesExtraction(recipeIDs: recipeIDs, range: range)
                        }
                    },
                    onCancelExtraction: { extraction.cancelExtraction() },
                    onCancel: { activeSheet = nil }
                )
            }
        }
        .alert(L("清空待确认候选", "Clear pending candidates"), isPresented: $isClearPendingConfirmationPresented) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("清空", "Clear"), role: .destructive) {
                clearPendingCandidates()
            }
        } message: {
            Text(L(
                "将删除当前待确认里的 \(pendingCandidates.count) 条候选，不影响已入库资产和已忽略候选。",
                "This will delete \(pendingCandidates.count) pending candidates without touching saved assets or ignored candidates."
            ))
        }
    }
}

private extension AssetLibraryTab {
    var selectedCandidate: LanguageAssetCandidateRecord? {
        if let selectedCandidateID = selection.selectedCandidateID,
           let candidate = searchedCandidates.first(where: { $0.id == selectedCandidateID }) {
            return candidate
        }
        return filteredCandidates.first ?? searchedCandidates.first
    }

    /// 当前状态筛选下的候选源（改造方案 #5：待审 / 已忽略 两池切换）
    var statusFilteredCandidates: [LanguageAssetCandidateRecord] {
        candidateStatusFilter == .pending ? pendingCandidates : ignoredCandidates
    }

    var searchedCandidates: [LanguageAssetCandidateRecord] {
        let trimmedQuery = candidateQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteCandidates = statusFilteredCandidates.filter { $0.assetType == .quote }
        guard !trimmedQuery.isEmpty else { return quoteCandidates }

        return quoteCandidates.filter { candidate in
            searchableText(for: candidate).localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var filteredCandidates: [LanguageAssetCandidateRecord] {
        selection.filteredCandidates(from: searchedCandidates)
    }

    var creatorAssets: [LanguageAsset] {
        // 收藏置顶（改造方案 #4），组内保持时间倒序
        AssetLibraryAssetFilters.creatorAssets(from: assets)
            .filter { $0.assetType == .quote }
            .sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                return lhs.createdAt > rhs.createdAt
            }
    }

    var searchedLibraryAssets: [LanguageAsset] {
        AssetLibraryAssetFilters.filteredLibraryAssets(
            from: creatorAssets,
            selectedType: nil,
            query: libraryQuery
        )
    }

    var filteredLibraryAssets: [LanguageAsset] {
        selection.filteredLibraryAssets(from: searchedLibraryAssets)
    }

    var selectedLibraryAsset: LanguageAsset? {
        if let selectedLibraryAssetID = selection.selectedLibraryAssetID,
           let asset = filteredLibraryAssets.first(where: { $0.id == selectedLibraryAssetID }) {
            return asset
        }
        return filteredLibraryAssets.first
    }

    var searchedExtractionResults: [ExtractionResult] {
        let trimmedQuery = resultQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleResults = extractionResults.filter { $0.outputKind != .assetCandidates }
        guard !trimmedQuery.isEmpty else { return visibleResults }

        return visibleResults.filter { result in
            [
                result.outputKind.settingsDisplayTitle,
                result.title,
                result.content,
                result.summary ?? "",
            ].joined(separator: " ").localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var filteredExtractionResults: [ExtractionResult] {
        selection.filteredExtractionResults(from: searchedExtractionResults)
    }

    var selectedExtractionResult: ExtractionResult? {
        if let selectedResultID = selection.selectedResultID,
           let result = filteredExtractionResults.first(where: { $0.id == selectedResultID }) {
            return result
        }
        return filteredExtractionResults.first ?? searchedExtractionResults.first
    }

    var searchedRecipes: [ExtractionRecipe] {
        let trimmedQuery = recipeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return recipes }

        return recipes.filter { recipe in
            [
                recipe.name,
                recipe.recipeDescription,
                recipe.goalPrompt,
                recipe.outputKind.settingsDisplayTitle,
                recipe.qualityRules,
            ].joined(separator: " ").localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var selectedRecipeInList: ExtractionRecipe? {
        if let selectedRecipeListID = selection.selectedRecipeListID,
           let recipe = searchedRecipes.first(where: { $0.id == selectedRecipeListID }) {
            return recipe
        }
        return searchedRecipes.first
    }

    /// 配方展示名（含已删除配方兜底）：资产库分组/详情按配方分类展示
    /// （2026-07-08 大梁老师：「候选资产」只是待确认阶段的叫法，入库后不再出现）
    func recipeDisplayName(_ recipeID: String) -> String {
        if let recipe = recipes.first(where: { $0.id == recipeID })
            ?? archivedRecipes.first(where: { $0.id == recipeID }) {
            return recipe.name
        }
        return L("已删除配方", "Deleted recipe")
    }

    func recipeAccentColor(_ recipeID: String) -> Color {
        let recipe = recipes.first(where: { $0.id == recipeID })
            ?? archivedRecipes.first(where: { $0.id == recipeID })
        return recipe?.outputKind.settingsAccentColor ?? TF.settingsTextTertiary
    }

    var purifierToolbar: some View {
        AssetLibraryToolbar(
            selectedView: $selectedView,
            isExtracting: extraction.isExtracting,
            canExtract: extraction.hasLLMConfig,
            onExtract: { beginExtractionFlow() },
            onCancelExtraction: { extraction.cancelExtraction() }
        )
    }
}

// MARK: - Extract（2026-07 重构批三：提炼页）

private extension AssetLibraryTab {
    var extractView: some View {
        AssetExtractView(
            totalRecordCount: totalRecordCount,
            savedCount: savedResults.count,
            pendingCount: pendingResults.count,
            recentRuns: recentRuns,
            formattedDate: { AssetLibraryDateFormatters.displayDateTime($0) },
            onOpenPending: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    selectedView = .pending
                }
            },
            onDeleteRun: { run in
                Task {
                    await assetStore.deleteRun(id: run.id)
                    await reloadData()
                }
            }
        )
    }
}

// MARK: - Pending Review（2026-07 重构批三：统一待确认）

private extension AssetLibraryTab {
    var pendingReviewView: some View {
        AssetPendingReviewView(
            query: $pendingQuery,
            selectedResultID: $selectedPendingResultID,
            pendingResults: pendingResults,
            rejectedResults: rejectedResults,
            formattedDate: { AssetLibraryDateFormatters.displayDateTime($0) },
            recipeName: { recipeDisplayName($0) },
            recipeAccent: { recipeAccentColor($0) },
            onShowSources: { activeSheet = .resultSources($0) },
            onSave: { savePendingResult($0) },
            onDiscard: { discardPendingResult($0) },
            onSaveAll: { saveAllPendingResults($0) },
            onRestore: { restoreRejectedResult($0) },
            onDiscardAll: { results in
                Task {
                    for result in results {
                        await assetStore.updateResultStatus(id: result.id, to: .discarded)
                    }
                    await reloadData()
                }
            }
        )
    }

    /// 捞回被严审砍掉的产物 → 回到待确认由用户拍板
    func restoreRejectedResult(_ result: ExtractionResult) {
        Task {
            await assetStore.updateResultStatus(id: result.id, to: .pending)
            await reloadData()
        }
    }

    func savePendingResult(_ result: ExtractionResult) {
        Task {
            await assetStore.updateResultStatus(id: result.id, to: .saved)
            await reloadData()
        }
    }

    func discardPendingResult(_ result: ExtractionResult) {
        Task {
            await assetStore.updateResultStatus(id: result.id, to: .discarded)
            await reloadData()
        }
    }

    func saveAllPendingResults(_ results: [ExtractionResult]) {
        Task {
            for result in results {
                await assetStore.updateResultStatus(id: result.id, to: .saved)
            }
            await reloadData()
        }
    }
}

// MARK: - Library

private extension AssetLibraryTab {
    var libraryView: some View {
        // 2026-07 重构批三：资产库 = 已入库(saved)产物；老 creatorAssets 体系下线(库内 0 条)
        AssetLibrarySavedAssetsView(
            libraryQuery: $libraryQuery,
            selectedLibraryType: $selection.selectedLibraryType,
            selectedLibraryAssetID: $selection.selectedLibraryAssetID,
            selectedResultRecipeID: $selection.selectedResultRecipeID,
            selectedResultID: $selection.selectedResultID,
            creatorAssets: [],
            extractionResults: savedResults,
            recipeName: { recipeDisplayName($0) },
            recipeAccent: { recipeAccentColor($0) },
            selectedLibraryAsset: nil,
            selectedExtractionResult: selectedSavedResult,
            copiedAssetID: copiedAssetID,
            formattedDate: { AssetLibraryDateFormatters.displayDateTime($0) },
            onCopyAsset: copyAsset,
            onShowResultSources: { activeSheet = .resultSources($0) },
            onCopyResult: copyResult,
            onToggleFavorite: toggleFavorite,
            onDeleteAsset: deleteAsset,
            onDeleteResult: { result in
                Task {
                    await assetStore.updateResultStatus(id: result.id, to: .discarded)
                    await reloadData()
                }
            }
        )
    }

    /// 资产库当前选中的已入库产物
    var selectedSavedResult: ExtractionResult? {
        guard let selectedResultID = selection.selectedResultID else { return savedResults.first }
        return savedResults.first { $0.id == selectedResultID } ?? savedResults.first
    }
}

// MARK: - Results

// MARK: - Recipes

private extension AssetLibraryTab {
    var recipesView: some View {
        ExtractionRecipesView(
            recipeQuery: $recipeQuery,
            selectedRecipeID: $selection.selectedRecipeListID,
            recipes: searchedRecipes,
            archivedRecipes: archivedRecipes,
            selectedRecipe: selectedRecipeInList,
            onCreate: { activeSheet = .recipeEditor(nil) },
            onEdit: { activeSheet = .recipeEditor($0) },
            onUseTemplates: saveRecipeTemplates,
            onArchive: archiveRecipe,
            onRestore: { recipe in
                Task {
                    await assetStore.restoreRecipe(id: recipe.id)
                    await reloadData()
                }
            }
        )
    }
}

// MARK: - Actions and Data

private extension AssetLibraryTab {
    func sourceRecords(for candidate: LanguageAssetCandidateRecord) -> [HistoryRecord] {
        candidate.sourceRecordIDs
            .compactMap { sourceRecordMap[$0] }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func sourceRecords(for result: ExtractionResult) -> [HistoryRecord] {
        result.sourceRecordIDs
            .compactMap { sourceRecordMap[$0] }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func displayDate(for candidate: LanguageAssetCandidateRecord) -> String {
        guard let date = sourceRecords(for: candidate).first?.createdAt else {
            return AssetLibraryDateFormatters.displayDateTime(candidate.createdAt)
        }
        return AssetLibraryDateFormatters.displayDateTime(date)
    }

    func searchableText(for candidate: LanguageAssetCandidateRecord) -> String {
        [
            candidate.assetType.settingsDisplayTitle,
            candidate.grade.rawValue,
            candidate.title,
            candidate.content,
            candidate.summary ?? "",
            candidate.reason,
            candidate.scenes.joined(separator: " "),
            candidate.audiences.joined(separator: " "),
            candidate.ruleHit ?? "",
        ].joined(separator: " ")
    }

    func copyAsset(_ asset: LanguageAsset) {
        copyToPasteboard(
            id: asset.id,
            title: asset.title,
            content: asset.content,
            logAssetID: asset.id,
            logDetail: L("复制了 1 条 \(asset.assetType.settingsDisplayTitle)", "Copied 1 \(asset.assetType.settingsDisplayTitle)")
        )
    }

    func copyResult(_ result: ExtractionResult) {
        copyToPasteboard(
            id: result.id,
            title: result.title,
            content: result.content,
            logAssetID: nil,
            logDetail: L("复制了 1 条「\(recipeDisplayName(result.recipeID))」产物", "Copied 1 \(recipeDisplayName(result.recipeID)) result")
        )
    }

    /// 资产与产物复制共用：标题非空且异于正文时带标题行；1.2s 后清「已复制」态
    private func copyToPasteboard(
        id: String,
        title: String?,
        content: String,
        logAssetID: String?,
        logDetail: String
    ) {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = !trimmedTitle.isEmpty && trimmedTitle != content
            ? "\(trimmedTitle)\n\(content)"
            : content

        ClipboardLeaseCoordinator.shared.writeTextPermanently(payload)
        copiedAssetID = id
        logAction(assetID: logAssetID, actionType: .copied, detail: logDetail)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedAssetID == id {
                copiedAssetID = nil
            }
        }
    }
}

private extension AssetLibraryTab {
    @MainActor
    func reloadData() async {
        let snapshot = await AssetLibraryDataSnapshot.load(
            assetStore: assetStore,
            historyStore: historyStore
        )

        self.recipes = snapshot.recipes
        self.archivedRecipes = snapshot.archivedRecipes
        self.assets = snapshot.assets
        self.extractionResults = snapshot.extractionResults
        self.pendingCandidates = snapshot.pendingCandidates
        self.ignoredCandidates = snapshot.ignoredCandidates
        self.sourceRecordMap = snapshot.sourceRecordMap
        self.pendingResults = snapshot.pendingResults
        self.savedResults = snapshot.savedResults
        self.rejectedResults = snapshot.rejectedResults
        self.recentRuns = snapshot.recentRuns
        self.totalRecordCount = snapshot.totalRecordCount

        normalizeSelections()
    }

    func normalizeSelections() {
        selection.normalize(
            searchedCandidates: searchedCandidates,
            searchedLibraryAssets: searchedLibraryAssets,
            searchedExtractionResults: searchedExtractionResults,
            savedResults: savedResults,
            searchedRecipes: searchedRecipes
        )
        extraction.normalizeRecipeSelection(recipes: recipes)
    }

    func saveCandidate(_ candidate: LanguageAssetCandidateRecord) {
        Task {
            _ = await assetStore.saveEditedCandidateAsAsset(candidate)
            await reloadData()
        }
    }

    func saveEditedCandidate(_ candidate: LanguageAssetCandidateRecord) {
        Task {
            do {
                try await assetStore.saveCandidatesOrThrow([candidate])
            } catch {
                errorMessage = error.localizedDescription
            }
            await reloadData()
        }
    }

    func ignoreCandidate(_ candidate: LanguageAssetCandidateRecord) {
        Task {
            await assetStore.ignoreCandidate(id: candidate.id)
            await reloadData()
        }
    }

    /// 已忽略候选恢复待审（改造方案 #5）
    func restoreCandidate(_ candidate: LanguageAssetCandidateRecord) {
        Task {
            await assetStore.restoreCandidate(id: candidate.id)
            await reloadData()
        }
    }

    func clearPendingCandidates() {
        Task {
            _ = await assetStore.clearCandidates(status: .pending)
            selection.selectedCandidateID = nil
            selection.selectedCandidateType = nil
            await reloadData()
        }
    }

    // MARK: - 资产生命周期（改造方案 #4/#15）

    func toggleFavorite(_ asset: LanguageAsset) {
        Task {
            await assetStore.setFavorite(id: asset.id, isFavorite: !asset.isFavorite)
            await assetStore.logAction(
                assetID: asset.id,
                actionType: asset.isFavorite ? .unfavorited : .favorited
            )
            await reloadData()
        }
    }

    func deleteAsset(_ asset: LanguageAsset) {
        Task {
            await assetStore.softDelete(id: asset.id)
            await assetStore.logAction(
                assetID: asset.id,
                actionType: .deleted,
                detail: L("删除了 1 条 \(asset.assetType.settingsDisplayTitle)", "Deleted 1 \(asset.assetType.settingsDisplayTitle)")
            )
            await reloadData()
        }
    }

    func saveRecipe(_ recipe: ExtractionRecipe) {
        Task {
            do {
                try await assetStore.saveRecipesOrThrow([recipe])
                extraction.recipeID = recipe.id
                selection.selectedRecipeListID = recipe.id
                await reloadData()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func saveRecipeTemplates(_ templates: [ExtractionRecipe]) {
        let existingNames = Set(recipes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let newDefinitions = templates
            .filter { template in
                let normalizedName = template.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !existingNames.contains(normalizedName)
            }
            .map { $0.asUserDefinition() }

        Task {
            do {
                if !newDefinitions.isEmpty {
                    try await assetStore.saveRecipesOrThrow(newDefinitions)
                }
                if let firstSaved = newDefinitions.first {
                    extraction.recipeID = firstSaved.id
                    extraction.recipeIDs = [firstSaved.id]
                    selection.selectedRecipeListID = firstSaved.id
                } else if let firstTemplate = templates.first,
                          let existing = recipes.first(where: {
                              $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                  .caseInsensitiveCompare(firstTemplate.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                          }) {
                    extraction.recipeID = existing.id
                    extraction.recipeIDs = [existing.id]
                    selection.selectedRecipeListID = existing.id
                }
                await reloadData()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func archiveRecipe(_ recipe: ExtractionRecipe) {
        guard !recipe.isBuiltIn else { return }
        Task {
            await assetStore.archiveRecipe(id: recipe.id)
            if extraction.recipeID == recipe.id {
                extraction.recipeID = ExtractionRecipe.quoteAssetsID
            }
            extraction.recipeIDs.remove(recipe.id)
            if extraction.recipeIDs.isEmpty {
                extraction.recipeIDs = [extraction.recipeID]
            }
            await reloadData()
        }
    }

    @MainActor
    func beginExtractionFlow() {
        guard !extraction.isExtracting, extraction.hasLLMConfig else { return }
        activeSheet = .extractionRangeSelection
    }

    /// 提炼执行（编排在 ViewModel）+ View 收尾：
    /// 结束（成功/取消/失败）一律关弹窗，成功跳待确认（2026-07-08 大梁老师）
    @MainActor
    func runRecipesExtraction(recipeIDs: Set<String>, range: AssetExtractionRangeOption) async {
        errorMessage = nil
        let outcome = await extraction.runRecipesExtraction(
            selectedRecipeIDs: recipeIDs,
            range: range,
            recipes: recipes,
            ruleConfig: ruleConfig
        )
        switch outcome {
        case .notStarted, .emptyRange:
            // emptyRange 的就地提示已由 ViewModel 设置，弹窗保持打开等用户换范围
            break
        case .completed:
            await reloadData()
            activeSheet = nil
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedView = .pending
            }
        case .cancelled:
            activeSheet = nil
            await reloadData()
        case .failed(let message):
            errorMessage = message
            activeSheet = nil
            await reloadData()
        }
    }

    func logAction(assetID: String?, actionType: LanguageAssetActionType, detail: String? = nil) {
        Task {
            await assetStore.logAction(assetID: assetID, actionType: actionType, detail: detail)
        }
    }

}
