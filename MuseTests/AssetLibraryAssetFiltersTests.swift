import XCTest
@testable import Muse

final class AssetLibraryAssetFiltersTests: XCTestCase {
    func testCreatorAssetsExcludeLegacyVocabularyTypes() {
        let assets = [
            makeAsset(id: "question", type: .question),
            makeAsset(id: "term", type: .term),
            makeAsset(id: "snippet", type: .snippet),
            makeAsset(id: "quote", type: .quote),
        ]

        let result = AssetLibraryAssetFilters.creatorAssets(from: assets)

        XCTAssertEqual(result.map(\.id), ["question", "quote"])
    }

    func testFilteredLibraryAssetsFilterByTypeAndQueryThenSortNewestFirst() {
        let oldQuestion = makeAsset(
            id: "old-question",
            type: .question,
            createdAt: Date(timeIntervalSince1970: 10),
            title: "Pricing objection",
            content: "How should I answer price concerns?"
        )
        let newQuestion = makeAsset(
            id: "new-question",
            type: .question,
            createdAt: Date(timeIntervalSince1970: 30),
            title: "Sales call",
            content: "A better way to handle pricing concerns"
        )
        let viewpoint = makeAsset(
            id: "viewpoint",
            type: .viewpoint,
            createdAt: Date(timeIntervalSince1970: 40),
            title: "Pricing viewpoint",
            content: "A point of view"
        )

        let result = AssetLibraryAssetFilters.filteredLibraryAssets(
            from: [oldQuestion, newQuestion, viewpoint],
            selectedType: .question,
            query: "pricing"
        )

        XCTAssertEqual(result.map(\.id), ["new-question", "old-question"])
    }

    func testFilteredLibraryAssetsSearchesMetadataFieldsCaseInsensitively() {
        let matchingAsset = makeAsset(
            id: "matching",
            type: .framework,
            createdAt: Date(timeIntervalSince1970: 10),
            keywords: ["Creator Funnel"]
        )
        let otherAsset = makeAsset(
            id: "other",
            type: .framework,
            createdAt: Date(timeIntervalSince1970: 20),
            keywords: ["Operations"]
        )

        let result = AssetLibraryAssetFilters.filteredLibraryAssets(
            from: [matchingAsset, otherAsset],
            selectedType: nil,
            query: "creator funnel"
        )

        XCTAssertEqual(result.map(\.id), ["matching"])
    }

    private func makeAsset(
        id: String,
        type: LanguageAssetType,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        title: String = "Title",
        content: String = "Content",
        keywords: [String] = []
    ) -> LanguageAsset {
        LanguageAsset(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            assetType: type,
            grade: .a,
            title: title,
            content: content,
            summary: nil,
            reason: nil,
            scenes: [],
            audiences: [],
            ruleHit: nil,
            keywords: keywords,
            sourceRecordIDs: [],
            sourceRecordCount: 0,
            extractionJobID: nil,
            isFavorite: false,
            status: .active
        )
    }
}
