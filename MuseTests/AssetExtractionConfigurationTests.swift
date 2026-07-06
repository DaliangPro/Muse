import XCTest
@testable import Muse

final class AssetExtractionConfigurationTests: XCTestCase {
    func testDefaultMinimumCharacterCountAllowsShortReusableQuotes() {
        let configuration = AssetExtractionConfiguration.recent()

        XCTAssertEqual(configuration.minimumCharacterCount, 1)
    }

    func testIncludingProcessedRecordsIsReflectedInRangePayload() {
        let configuration = AssetExtractionConfiguration
            .recent(limit: 20)
            .includingProcessedRecords(true)

        XCTAssertEqual(configuration.rangePayload, "limit=20;include_processed=true")
    }

    func testManualSelectionDoesNotAppendProcessedFlagToPayload() {
        let configuration = AssetExtractionConfiguration
            .manualSelection(ids: ["r1", "r2"])
            .includingProcessedRecords(true)

        XCTAssertEqual(configuration.rangePayload, "r1,r2")
    }

    func testLocalQwenAdapterConstrainsInputForSmallContextWindow() {
        var configuration = AssetExtractionConfiguration.last30Days(maxRecordCount: 100)
        configuration.maxTotalInputCharacters = 12_000
        configuration.maxCharactersPerRecord = 1_600

        let adapted = configuration.adaptedForAssetExtractionProvider(.localQwen)

        XCTAssertEqual(adapted.maxRecordCount, 12)
        XCTAssertEqual(adapted.maxTotalInputCharacters, 1_000)
        XCTAssertEqual(adapted.maxCharactersPerRecord, 420)
    }

    func testCloudProviderAdapterKeepsInputLimits() {
        var configuration = AssetExtractionConfiguration.last30Days(maxRecordCount: 100)
        configuration.maxTotalInputCharacters = 12_000
        configuration.maxCharactersPerRecord = 1_600

        let adapted = configuration.adaptedForAssetExtractionProvider(.doubao)

        XCTAssertEqual(adapted.maxRecordCount, 100)
        XCTAssertEqual(adapted.maxTotalInputCharacters, 12_000)
        XCTAssertEqual(adapted.maxCharactersPerRecord, 1_600)
    }
}
