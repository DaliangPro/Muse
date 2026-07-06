import XCTest
@testable import Muse

final class VocabularySnippetGroupingTests: XCTestCase {
    func testGroupsSnippetsByReplacementPreservingFirstReplacementOrder() {
        let groups = VocabularySnippetGrouping.groups(for: [
            (trigger: "ty", value: "thank you"),
            (trigger: "brb", value: "be right back"),
            (trigger: "thx", value: "thank you"),
            (trigger: "omw", value: "on my way")
        ])

        XCTAssertEqual(groups, [
            VocabularySnippetGroup(replacement: "thank you", triggers: ["ty", "thx"]),
            VocabularySnippetGroup(replacement: "be right back", triggers: ["brb"]),
            VocabularySnippetGroup(replacement: "on my way", triggers: ["omw"])
        ])
    }

    func testEmptySnippetsReturnNoGroups() {
        XCTAssertEqual(VocabularySnippetGrouping.groups(for: []), [])
    }
}
