import AppKit
import SwiftUI

struct AssetLibraryTab: View, SettingsCardHelpers {
    @State private var latestJob: AssetExtractionJob?
    @State private var assets: [LanguageAsset] = []
    @State private var pendingCandidates: [LanguageAssetCandidateRecord] = []
    @State private var ignoredCandidates: [LanguageAssetCandidateRecord] = []
    @State private var candidateStatusFilter: AssetCandidateStatusFilter = .pending
    @State private var sourceRecordMap: [String: HistoryRecord] = [:]
    @State private var isExtracting = false
    @State private var extractionProgressPhase: AssetExtractionProgressStage = .preparing
    @State private var extractionRecipeID: String = ExtractionRecipe.quoteAssetsID
    @State private var extractionRecipeIDs: Set<String> = [ExtractionRecipe.quoteAssetsID]
    @State private var extractionRange: AssetExtractionRangeOption = .loadSaved()
    @State private var extractionIncludesProcessedRecords = false
    @State private var extractionTask: Task<Void, Never>?
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
    @State private var last1DayCount = 0
    @State private var last7DayCount = 0
    @State private var latestRun: ExtractionRun?
    @State private var recipes: [ExtractionRecipe] = ExtractionRecipe.builtInRecipes()
    @State private var archivedRecipes: [ExtractionRecipe] = []
    @State private var selectedRecipeListID: String?
    @State private var recipeQuery = ""
    @State private var selectedCandidateID: String?
    @State private var selectedCandidateType: LanguageAssetType?
    @State private var didInitializeCandidateGroupExpansion = false
    @State private var candidateQuery = ""
    @State private var selectedLibraryType: LanguageAssetType?
    @State private var selectedLibraryAssetID: String?
    @State private var didInitializeLibraryGroupExpansion = false
    @State private var libraryQuery = ""
    @State private var extractionResults: [ExtractionResult] = []
    @State private var selectedResultKind: ExtractionOutputKind?
    /// 资产库侧栏的分组选中态（按配方分类；提炼结果页仍按产物类型用 selectedResultKind）
    @State private var selectedResultRecipeID: String?
    @State private var selectedResultID: String?
    @State private var resultQuery = ""
    @State private var ruleConfig: AssetExtractionRuleConfig = AssetExtractionRuleConfigStore.load()
    @State private var selectedRuleType: LanguageAssetType?
    @State private var copiedAssetID: String?
    @State private var activeSheet: AssetLibrarySheet?
    /// 提炼范围无新内容时在弹窗内就地提示（2026-07-08：弹窗承载全部提炼状态）
    @State private var extractionEmptyNotice: String?
    @State private var isClearPendingConfirmationPresented = false

    private let assetStore = LanguageAssetStore()
    private let historyStore = HistoryStore()
    private let extractionService = AssetExtractionService()

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
                    selectedRecipeIDs: extractionRecipeIDs,
                    selectedRange: extractionRange,
                    isExtracting: isExtracting,
                    progressPhase: extractionProgressPhase,
                    emptyNotice: extractionEmptyNotice,
                    onConfirm: { recipeIDs, range in
                        extractionRecipeIDs = recipeIDs
                        extractionRecipeID = orderedRecipeIDs(from: recipeIDs).first ?? ExtractionRecipe.quoteAssetsID
                        extractionRange = range
                        extractionIncludesProcessedRecords = false
                        extractionEmptyNotice = nil
                        range.save()
                        Task { @MainActor in
                            await startRecipesExtraction(
                                recipeIDs: orderedRecipeIDs(from: recipeIDs),
                                range: range
                            )
                        }
                    },
                    onCancelExtraction: { extractionTask?.cancel() },
                    onCancel: { activeSheet = nil }
                )
            case .extractionPreview(let preview, let context):
                let provider = KeychainService.selectedAssetExtractionLLMProvider
                let promptMessages = promptPreviewMessages(
                    preview: preview,
                    context: context,
                    provider: provider
                )
                ExtractionPreviewSheet(
                    preview: preview,
                    context: context,
                    ruleConfig: ruleConfig,
                    provider: provider,
                    promptMessages: promptMessages,
                    onConfirm: {
                        activeSheet = nil
                        startExtractions(configurations: makeExtractionConfigurations(context: context, preview: preview))
                    },
                    onCancel: { activeSheet = nil }
                )
            case .manualRecordSelection(let records):
                ManualRecordSelectionSheet(
                    records: records,
                    onConfirm: { ids in
                        activeSheet = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(180))
                            await prepareManualExtractionPreview(ids: ids)
                        }
                    },
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
    var hasLLMConfig: Bool {
        return KeychainService.loadAssetExtractionLLMConfig() != nil
    }

    var selectedCandidate: LanguageAssetCandidateRecord? {
        if let selectedCandidateID,
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
        guard let selectedCandidateType else {
            return searchedCandidates
        }
        return searchedCandidates.filter { $0.assetType == selectedCandidateType }
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
        guard let selectedLibraryType else { return searchedLibraryAssets }
        return searchedLibraryAssets.filter { $0.assetType == selectedLibraryType }
    }

    var selectedLibraryAsset: LanguageAsset? {
        if let selectedLibraryAssetID,
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
        guard let selectedResultKind else { return searchedExtractionResults }
        return searchedExtractionResults.filter { $0.outputKind == selectedResultKind }
    }

    var selectedExtractionResult: ExtractionResult? {
        if let selectedResultID,
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
        if let selectedRecipeListID,
           let recipe = searchedRecipes.first(where: { $0.id == selectedRecipeListID }) {
            return recipe
        }
        return searchedRecipes.first
    }

    func extractionRecipe(for id: String) -> ExtractionRecipe {
        recipes.first(where: { $0.id == id }) ?? ExtractionRecipe.quoteAssets()
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

    func orderedRecipeIDs(from ids: Set<String>) -> [String] {
        recipes.map(\.id).filter { ids.contains($0) }
    }

    var purifierToolbar: some View {
        AssetLibraryToolbar(
            selectedView: $selectedView,
            isExtracting: isExtracting,
            canExtract: hasLLMConfig,
            onExtract: { beginExtractionFlow() },
            onCancelExtraction: { extractionTask?.cancel() }
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
            selectedLibraryType: $selectedLibraryType,
            selectedLibraryAssetID: $selectedLibraryAssetID,
            selectedResultRecipeID: $selectedResultRecipeID,
            selectedResultID: $selectedResultID,
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
        guard let selectedResultID else { return savedResults.first }
        return savedResults.first { $0.id == selectedResultID } ?? savedResults.first
    }
}

// MARK: - Results

private extension AssetLibraryTab {
    var resultsView: some View {
        AssetExtractionResultsView(
            resultQuery: $resultQuery,
            selectedResultKind: $selectedResultKind,
            selectedResultID: $selectedResultID,
            results: searchedExtractionResults,
            selectedResult: selectedExtractionResult,
            latestRun: latestRun,
            copiedResultID: copiedAssetID,
            formattedDate: { AssetLibraryDateFormatters.displayDateTime($0) },
            onShowSources: { activeSheet = .resultSources($0) },
            onCopyResult: copyResult
        )
    }
}

// MARK: - Recipes

private extension AssetLibraryTab {
    var recipesView: some View {
        ExtractionRecipesView(
            recipeQuery: $recipeQuery,
            selectedRecipeID: $selectedRecipeListID,
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

// MARK: - Rules

private extension AssetLibraryTab {
    var rulesView: some View {
        AssetLibraryRulesView(
            ruleConfig: $ruleConfig,
            selectedRuleType: $selectedRuleType
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
        let title = asset.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = !title.isEmpty && title != asset.content
            ? "\(title)\n\(asset.content)"
            : asset.content

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        copiedAssetID = asset.id
        logAction(
            assetID: asset.id,
            actionType: .copied,
            detail: L("复制了 1 条 \(asset.assetType.settingsDisplayTitle)", "Copied 1 \(asset.assetType.settingsDisplayTitle)")
        )

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedAssetID == asset.id {
                copiedAssetID = nil
            }
        }
    }

    func copyResult(_ result: ExtractionResult) {
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = !title.isEmpty && title != result.content
            ? "\(title)\n\(result.content)"
            : result.content

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        copiedAssetID = result.id
        logAction(
            assetID: nil,
            actionType: .copied,
            detail: L("复制了 1 条「\(recipeDisplayName(result.recipeID))」产物", "Copied 1 \(recipeDisplayName(result.recipeID)) result")
        )

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedAssetID == result.id {
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

        self.latestJob = snapshot.latestJob
        self.latestRun = snapshot.latestRun
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
        self.last1DayCount = snapshot.last1DayCount
        self.last7DayCount = snapshot.last7DayCount

        normalizeSelections()
    }

    func normalizeSelections() {
        if !didInitializeCandidateGroupExpansion {
            selectedCandidateType = searchedCandidates.first?.assetType
            didInitializeCandidateGroupExpansion = true
        } else if let expandedType = selectedCandidateType,
                  !searchedCandidates.contains(where: { $0.assetType == expandedType }) {
            selectedCandidateType = nil
        }

        let visibleCandidates = filteredCandidates
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

        let visibleLibraryAssets = filteredLibraryAssets
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

        let visibleResults = filteredExtractionResults
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

        if !recipes.contains(where: { $0.id == extractionRecipeID }) {
            extractionRecipeID = ExtractionRecipe.quoteAssetsID
        }
        extractionRecipeIDs = extractionRecipeIDs.filter { id in
            recipes.contains(where: { $0.id == id })
        }
        if extractionRecipeIDs.isEmpty {
            extractionRecipeIDs = [extractionRecipeID]
        }
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
            selectedCandidateID = nil
            selectedCandidateType = nil
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
                extractionRecipeID = recipe.id
                selectedRecipeListID = recipe.id
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
                    extractionRecipeID = firstSaved.id
                    extractionRecipeIDs = [firstSaved.id]
                    selectedRecipeListID = firstSaved.id
                } else if let firstTemplate = templates.first,
                          let existing = recipes.first(where: {
                              $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                  .caseInsensitiveCompare(firstTemplate.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                          }) {
                    extractionRecipeID = existing.id
                    extractionRecipeIDs = [existing.id]
                    selectedRecipeListID = existing.id
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
            if extractionRecipeID == recipe.id {
                extractionRecipeID = ExtractionRecipe.quoteAssetsID
            }
            extractionRecipeIDs.remove(recipe.id)
            if extractionRecipeIDs.isEmpty {
                extractionRecipeIDs = [extractionRecipeID]
            }
            await reloadData()
        }
    }


    @MainActor
    func beginExtractionFlow() {
        guard !isExtracting, hasLLMConfig else { return }
        activeSheet = .extractionRangeSelection
    }

    /// 多配方提炼（2026-07 重设计）：逐配方各自预览(防重/空范围)后并入一次执行
    @MainActor
    func startRecipesExtraction(recipeIDs: [String], range: AssetExtractionRangeOption) async {
        guard !isExtracting, hasLLMConfig, !recipeIDs.isEmpty else { return }
        // 立即进提炼态：弹窗原地切「提炼中」（预览阶段也算准备中，同时防按钮连点重复发起）
        isExtracting = true
        extractionProgressPhase = .preparing
        errorMessage = nil

        var configurations: [AssetExtractionConfiguration] = []
        for recipeID in recipeIDs {
            guard let base = makeExtractionConfiguration(
                recipeID: recipeID,
                range: range,
                includesProcessedRecords: false
            ) else { continue }

            let preview = await extractionService.previewExtraction(
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

        guard !configurations.isEmpty else {
            // 弹窗内就地提示并退回选择态，让用户直接换范围重试
            isExtracting = false
            extractionEmptyNotice = L("范围内没有可提炼的新内容，换个范围试试。", "No new records in this range — try another.")
            return
        }
        runExtractions(configurations: configurations)
    }

    /// 提炼入口（改造方案 #3/#7）：手动范围先弹记录勾选，
    /// 其余范围先本地预览（零模型成本）再确认
    @MainActor
    func prepareExtractionPreview(
        recipeIDs: [String],
        range: AssetExtractionRangeOption,
        includesProcessedRecords: Bool
    ) async {
        guard !isExtracting, hasLLMConfig else { return }
        let effectiveRecipeIDs = recipeIDs.isEmpty ? [extractionRecipeID] : recipeIDs

        if range == .manual {
            let records = await historyStore.fetchRecent(limit: 100)
                .filter { $0.status == "completed" && !$0.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            activeSheet = .manualRecordSelection(records)
            return
        }

        guard let configuration = makeExtractionConfiguration(
            recipeID: effectiveRecipeIDs.first ?? extractionRecipeID,
            range: range,
            includesProcessedRecords: includesProcessedRecords
        ) else { return }
        let preview = await extractionService.previewExtraction(
            configuration: configuration.applying(ruleConfig: ruleConfig)
        )
        let context = AssetExtractionPreviewContext(
            recipeIDs: effectiveRecipeIDs,
            recipeNames: effectiveRecipeIDs.map { extractionRecipe(for: $0).name },
            range: range,
            includesProcessedRecords: includesProcessedRecords
        )
        activeSheet = .extractionPreview(preview, context)
    }

    @MainActor
    func prepareManualExtractionPreview(ids: [String]) async {
        guard !isExtracting, hasLLMConfig, !ids.isEmpty else { return }

        let context = AssetExtractionPreviewContext(
            recipeIDs: orderedRecipeIDs(from: extractionRecipeIDs),
            recipeNames: orderedRecipeIDs(from: extractionRecipeIDs).map { extractionRecipe(for: $0).name },
            range: .manual,
            selectedRecordIDs: ids
        )
        guard let configuration = makeExtractionConfigurations(context: context).first else { return }
        let preview = await extractionService.previewExtraction(
            configuration: configuration.applying(ruleConfig: ruleConfig)
        )
        activeSheet = .extractionPreview(preview, context)
    }

    func makeExtractionConfiguration(
        recipeID: String,
        range: AssetExtractionRangeOption,
        includesProcessedRecords: Bool
    ) -> AssetExtractionConfiguration? {
        range.makeConfiguration()?
            .includingProcessedRecords(includesProcessedRecords)
            .applying(recipeID: recipeID)
            .adaptedForAssetExtractionProvider(KeychainService.selectedAssetExtractionLLMProvider)
    }

    func makeExtractionConfiguration(context: AssetExtractionPreviewContext) -> AssetExtractionConfiguration? {
        context.makeConfigurations().first?
            .adaptedForAssetExtractionProvider(KeychainService.selectedAssetExtractionLLMProvider)
    }

    func makeExtractionConfigurations(context: AssetExtractionPreviewContext) -> [AssetExtractionConfiguration] {
        context.makeConfigurations().map {
            $0.adaptedForAssetExtractionProvider(KeychainService.selectedAssetExtractionLLMProvider)
        }
    }

    func makeExtractionConfigurations(
        context: AssetExtractionPreviewContext,
        preview: AssetExtractionPreview
    ) -> [AssetExtractionConfiguration] {
        let recordIDs = preview.records.map(\.id)
        guard !recordIDs.isEmpty else { return [] }

        return context.recipeIDs.map { recipeID in
            AssetExtractionConfiguration
                .manualSelection(ids: recordIDs)
                .applying(recipeID: recipeID)
                .adaptedForAssetExtractionProvider(KeychainService.selectedAssetExtractionLLMProvider)
        }
    }

    func promptPreviewMessages(
        preview: AssetExtractionPreview,
        context: AssetExtractionPreviewContext,
        provider: LLMProvider
    ) -> AssetExtractionPromptMessages {
        guard let configuration = makeExtractionConfiguration(context: context) else {
            return AssetExtractionPromptMessages(system: nil, user: "")
        }
        let configurations = makeExtractionConfigurations(context: context)
        // 2026-07 重构批三：预览统一按新管线宽提段的 prompt 展示
        if configurations.count > 1 {
            let sections = configurations.map { configuration in
                let effectiveConfiguration = configuration.applying(ruleConfig: ruleConfig)
                let recipe = extractionRecipe(for: effectiveConfiguration.recipeID)
                let messages = RemoteRecipeExtractionProvider.promptMessages(
                    from: preview.records,
                    recipe: recipe,
                    configuration: effectiveConfiguration,
                    provider: provider
                )
                return """
                ===== \(recipe.name) =====
                \(messages.combinedForDisplay)
                """
            }
            return AssetExtractionPromptMessages(
                system: "本次会按所选资产定义分别调用模型，共 \(configurations.count) 次。",
                user: sections.joined(separator: "\n\n")
            )
        }
        let effectiveConfiguration = configuration.applying(ruleConfig: ruleConfig)
        let recipe = extractionRecipe(for: effectiveConfiguration.recipeID)
        return RemoteRecipeExtractionProvider.promptMessages(from: preview.records, recipe: recipe, configuration: effectiveConfiguration, provider: provider)
    }

    @MainActor
    func startExtraction(configuration: AssetExtractionConfiguration) {
        startExtractions(configurations: [configuration])
    }

    @MainActor
    func startExtractions(configurations: [AssetExtractionConfiguration]) {
        guard !isExtracting, hasLLMConfig else { return }
        let configurations = configurations.filter { configuration in
            recipes.contains(where: { $0.id == configuration.recipeID })
        }
        guard !configurations.isEmpty else { return }

        isExtracting = true
        extractionProgressPhase = .preparing
        errorMessage = nil
        runExtractions(configurations: configurations)
    }

    /// 执行提炼（调用前须已置 isExtracting = true）：进度在提炼弹窗内呈现，
    /// 结束（成功/取消/失败）一律关弹窗，成功跳待确认（2026-07-08 大梁老师）
    @MainActor
    private func runExtractions(configurations: [AssetExtractionConfiguration]) {
        extractionTask = Task { @MainActor in
            defer {
                isExtracting = false
                extractionTask = nil
            }
            do {
                var latestGenericRun: ExtractionRun?

                // 2026-07 重构批三：所有配方统一走两段式管线（宽提+严审），产物落待确认
                for configuration in configurations {
                    try Task.checkCancellation()
                    let effectiveConfiguration = configuration.applying(ruleConfig: ruleConfig)
                    let result = try await extractionService.extractRecipeResults(
                        configuration: effectiveConfiguration
                    ) { stage in
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                extractionProgressPhase = stage
                            }
                        }
                    }
                    latestGenericRun = result.run
                }

                latestRun = latestGenericRun ?? latestRun
                await reloadData()
                activeSheet = nil
                withAnimation(.easeInOut(duration: 0.16)) {
                    selectedView = .pending
                }
            } catch is CancellationError {
                activeSheet = nil
                await reloadData()
            } catch {
                errorMessage = error.localizedDescription
                activeSheet = nil
                await reloadData()
            }
        }
    }

    func logAction(assetID: String?, actionType: LanguageAssetActionType, detail: String? = nil) {
        Task {
            await assetStore.logAction(assetID: assetID, actionType: actionType, detail: detail)
        }
    }

}
