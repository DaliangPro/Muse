import XCTest
@testable import Muse

final class AssetLibraryTagSortingTests: XCTestCase {
    func testCombinedTagsSortScenesBeforeAudiencesWithStablePriorities() {
        let result = AssetLibraryTagSorting.sortedCombinedTags(
            scenes: ["口播稿", "观点输出", "核心段落", "IP定位"],
            audiences: ["个人 IP", "内容创作者"]
        )

        XCTAssertEqual(
            result,
            ["IP定位", "观点输出", "核心段落", "口播稿", "内容创作者", "个人 IP"]
        )
    }

    func testTagsTrimAndDeduplicateBeforeSorting() {
        let result = AssetLibraryTagSorting.sortedTags(
            [" 个人 IP ", "个人IP", "内容创作者", ""],
            kind: .audience
        )

        XCTAssertEqual(result, ["内容创作者", "个人 IP"])
    }
}
