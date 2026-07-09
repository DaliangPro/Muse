import XCTest
@testable import Muse

/// AssetLibrarySelectionState 归一化（2026-07-09 J13 拆分段随行测试）：
/// 覆盖首次初始化、失效回落、有效保持三类行为
final class AssetLibrarySelectionStateTests: XCTestCase {

    func testFirstNormalizeInitializesGroupExpansionAndSelectsFirstItem() {
        var state = AssetLibrarySelectionState()

        state.normalize(
            searchedCandidates: [makeCandidate(id: "c1", type: .quote), makeCandidate(id: "c2", type: .quote)],
            searchedLibraryAssets: [makeAsset(id: "a1", type: .viewpoint)],
            searchedExtractionResults: [makeResult(id: "r1", recipeID: "recipe-1")],
            savedResults: [],
            searchedRecipes: ExtractionRecipe.builtInRecipes()
        )

        XCTAssertTrue(state.didInitializeCandidateGroupExpansion)
        XCTAssertEqual(state.selectedCandidateType, .quote)
        XCTAssertEqual(state.selectedCandidateID, "c1")
        XCTAssertTrue(state.didInitializeLibraryGroupExpansion)
        XCTAssertEqual(state.selectedLibraryType, .viewpoint)
        XCTAssertEqual(state.selectedLibraryAssetID, "a1")
        XCTAssertEqual(state.selectedResultID, "r1")
        XCTAssertEqual(state.selectedRecipeListID, ExtractionRecipe.builtInRecipes().first?.id)
    }

    func testNormalizeKeepsSelectionsThatAreStillVisible() {
        var state = AssetLibrarySelectionState()
        state.didInitializeCandidateGroupExpansion = true
        state.didInitializeLibraryGroupExpansion = true
        state.selectedCandidateID = "c2"
        state.selectedLibraryAssetID = "a2"
        state.selectedResultID = "r2"

        state.normalize(
            searchedCandidates: [makeCandidate(id: "c1", type: .quote), makeCandidate(id: "c2", type: .quote)],
            searchedLibraryAssets: [makeAsset(id: "a1", type: .quote), makeAsset(id: "a2", type: .quote)],
            searchedExtractionResults: [makeResult(id: "r1", recipeID: "x"), makeResult(id: "r2", recipeID: "x")],
            savedResults: [],
            searchedRecipes: []
        )

        XCTAssertEqual(state.selectedCandidateID, "c2")
        XCTAssertEqual(state.selectedLibraryAssetID, "a2")
        XCTAssertEqual(state.selectedResultID, "r2")
    }

    func testNormalizeFallsBackToFirstWhenSelectionDisappears() {
        var state = AssetLibrarySelectionState()
        state.didInitializeCandidateGroupExpansion = true
        state.didInitializeLibraryGroupExpansion = true
        state.selectedCandidateID = "gone"
        state.selectedLibraryAssetID = "gone"
        state.selectedResultID = "gone"
        state.selectedRecipeListID = "gone"

        state.normalize(
            searchedCandidates: [makeCandidate(id: "c1", type: .quote)],
            searchedLibraryAssets: [makeAsset(id: "a1", type: .quote)],
            searchedExtractionResults: [makeResult(id: "r1", recipeID: "x")],
            savedResults: [],
            searchedRecipes: ExtractionRecipe.builtInRecipes()
        )

        XCTAssertEqual(state.selectedCandidateID, "c1")
        XCTAssertEqual(state.selectedLibraryAssetID, "a1")
        XCTAssertEqual(state.selectedResultID, "r1")
        XCTAssertEqual(state.selectedRecipeListID, ExtractionRecipe.builtInRecipes().first?.id)
    }

    func testNormalizeClearsStaleTypeAndRecipeGroupSelections() {
        var state = AssetLibrarySelectionState()
        state.didInitializeCandidateGroupExpansion = true
        state.didInitializeLibraryGroupExpansion = true
        state.selectedCandidateType = .question
        state.selectedLibraryType = .framework
        state.selectedResultKind = .todoList
        state.selectedResultRecipeID = "archived-recipe"

        state.normalize(
            searchedCandidates: [makeCandidate(id: "c1", type: .quote)],
            searchedLibraryAssets: [makeAsset(id: "a1", type: .quote)],
            searchedExtractionResults: [makeResult(id: "r1", recipeID: "live", outputKind: .summary)],
            savedResults: [makeResult(id: "s1", recipeID: "live", status: .saved)],
            searchedRecipes: []
        )

        XCTAssertNil(state.selectedCandidateType)
        XCTAssertNil(state.selectedLibraryType)
        XCTAssertNil(state.selectedResultKind)
        XCTAssertNil(state.selectedResultRecipeID)
        // 分组清空后选中项回落到全量首条
        XCTAssertEqual(state.selectedCandidateID, "c1")
        XCTAssertEqual(state.selectedLibraryAssetID, "a1")
        XCTAssertEqual(state.selectedResultID, "r1")
    }

    func testTypeFilterRulesMatchNormalizeSemantics() {
        var state = AssetLibrarySelectionState()
        state.selectedCandidateType = .quote
        state.selectedResultKind = .summary

        let candidates = [makeCandidate(id: "c1", type: .quote), makeCandidate(id: "c2", type: .question)]
        XCTAssertEqual(state.filteredCandidates(from: candidates).map(\.id), ["c1"])

        let results = [
            makeResult(id: "r1", recipeID: "x", outputKind: .summary),
            makeResult(id: "r2", recipeID: "x", outputKind: .todoList),
        ]
        XCTAssertEqual(state.filteredExtractionResults(from: results).map(\.id), ["r1"])

        state.selectedCandidateType = nil
        XCTAssertEqual(state.filteredCandidates(from: candidates).count, 2)
    }

    // MARK: - Fixtures

    private func makeCandidate(id: String, type: LanguageAssetType) -> LanguageAssetCandidateRecord {
        LanguageAssetCandidateRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            assetType: type,
            grade: .a,
            title: "Title",
            content: "Content",
            summary: nil,
            reason: "Reason",
            scenes: [],
            audiences: [],
            ruleHit: nil,
            sourceRecordIDs: [],
            sourceRecordCount: 0,
            extractionJobID: nil,
            status: .pending
        )
    }

    private func makeAsset(id: String, type: LanguageAssetType) -> LanguageAsset {
        LanguageAsset(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            assetType: type,
            grade: .a,
            title: "Title",
            content: "Content",
            summary: nil,
            reason: nil,
            scenes: [],
            audiences: [],
            ruleHit: nil,
            keywords: [],
            sourceRecordIDs: [],
            sourceRecordCount: 0,
            extractionJobID: nil,
            isFavorite: false,
            status: .active
        )
    }

    private func makeResult(
        id: String,
        recipeID: String,
        outputKind: ExtractionOutputKind = .summary,
        status: ExtractionResultStatus = .pending
    ) -> ExtractionResult {
        ExtractionResult(
            id: id,
            runID: "run-1",
            recipeID: recipeID,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            outputKind: outputKind,
            title: "Title",
            content: "Content",
            summary: nil,
            payloadJSON: "{}",
            sourceRecordIDs: [],
            sourceRecordCount: 0,
            status: status,
            score: nil,
            reviewReason: nil
        )
    }
}
