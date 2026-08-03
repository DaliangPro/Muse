import XCTest
@testable import Muse

final class VoicePolishNumberingTests: XCTestCase {
    func testCountsCommonArabicNumberMarkersByLine() {
        let text = """
        1. 第一项
        2) 第二项
        3、第三项
        (4) 第四项
        （5）第五项
        """

        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: text, kind: .numberedList),
            5
        )
        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: text, kind: .bulletList),
            0
        )
    }

    func testCountsChineseNumberMarkersByLine() {
        let text = """
        第一，确认需求
        （二）补齐测试
        三是发布前演练
        """

        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: text, kind: .numberedList),
            3
        )
    }

    func testCountsCommonBulletMarkersByLine() {
        let text = """
        - 第一项
        * 第二项
        • 第三项
        ·第四项
        ▪ 第五项
        """

        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: text, kind: .bulletList),
            5
        )
        XCTAssertEqual(VoicePolishNumbering.recognizedListItemCount(in: text), 5)
    }

    func testNormalizationConvertsExistingMixedMarkersWithoutChangingContent() {
        let text = """
        今天要完成这些事项：

        一、确认需求
        2) 补齐测试
        • 发布前演练
        """

        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: text, as: .numberedList),
            """
            今天要完成这些事项：

            1. 确认需求
            2. 补齐测试
            3. 发布前演练
            """
        )
    }

    func testNormalizationPreservesIndentationAndCanNormalizeBullets() {
        let text = """
          （1）第一项
          二是第二项
        """

        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: text, as: .bulletList),
            """
              - 第一项
              - 第二项
            """
        )
    }

    func testOrdinaryParagraphAndInlineEnumerationAreNeverSplit() {
        let paragraph = "我先确认需求，然后补齐测试，最后发布前演练。"
        let inline = "第一，确认需求；第二，补齐测试；第三，发布前演练。"

        XCTAssertEqual(VoicePolishNumbering.recognizedListItemCount(in: paragraph), 0)
        // 行首“第一，”虽像编号，但单项不足以证明为逐行列表。
        XCTAssertEqual(VoicePolishNumbering.recognizedListItemCount(in: inline), 0)
        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: inline, as: .numberedList),
            inline
        )
    }

    func testSingleMarkerIsNotNormalizedAndDecimalIsNotAListItem() {
        let single = "1. 只有一个显式项目"
        let decimal = "1.5 倍是本次目标。"

        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: single, as: .numberedList),
            single
        )
        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: single, kind: .numberedList),
            0
        )
        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: decimal, kind: .numberedList),
            0
        )
    }

    func testYearsLargeNumbersAndZeroAreNotTreatedAsListMarkers() {
        let facts = """
        2026. 项目启动
        2027. 项目交付
        (2028) 年度预算
        100. 百分比事实
        0. 零值事实
        一百、预算单位
        """

        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: facts, kind: .numberedList),
            0
        )
        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: facts, as: .numberedList),
            facts
        )
    }

    func testSentenceAndParagraphKindsNeverNormalize() {
        let text = "1. 第一项\n2. 第二项"

        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: text, as: .sentence),
            text
        )
        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: text, as: .paragraphs),
            text
        )
    }

    func testNumberingPreferenceDistinguishesChineseArabicAndMixedLists() {
        XCTAssertTrue(VoicePolishNumbering.matchesNumberingPreference(
            in: "一、确认需求\n二、补齐测试\n三、发布演练",
            preference: .chinese
        ))
        XCTAssertTrue(VoicePolishNumbering.matchesNumberingPreference(
            in: "1. Confirm scope\n2. Add tests\n3. Ship",
            preference: .arabic
        ))
        XCTAssertFalse(VoicePolishNumbering.matchesNumberingPreference(
            in: "一、确认需求\n2. 补齐测试\n三、发布演练",
            preference: .chinese
        ))
    }

    func testNumberingPreferenceRejectsOutOfOrderAndDuplicateOrdinals() {
        XCTAssertFalse(VoicePolishNumbering.matchesNumberingPreference(
            in: "1. 确认需求\n3. 补齐测试\n2. 发布演练",
            preference: .arabic
        ))
        XCTAssertFalse(VoicePolishNumbering.matchesNumberingPreference(
            in: "一、确认需求\n一、补齐测试\n三、发布演练",
            preference: .chinese
        ))
    }

    func testNormalizationRejectsErrorCodeLikeAndOutOfOrderSequences() {
        let errorCodes = "42. 请求失败\n43. 权限不足"
        let outOfOrder = "1. 确认需求\n3. 发布演练\n2. 补齐测试"

        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: errorCodes, as: .numberedList),
            errorCodes
        )
        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: outOfOrder, as: .numberedList),
            outOfOrder
        )
        XCTAssertEqual(
            VoicePolishNumbering.listItemCount(in: errorCodes, kind: .numberedList),
            0
        )
        XCTAssertEqual(VoicePolishNumbering.recognizedListItemCount(in: errorCodes), 0)
        XCTAssertTrue(VoicePolishNumbering.containsPotentialListMarker(in: errorCodes))
    }

    func testSpacedNegativeFactsAreNotBulletMarkersOrRemoved() {
        let facts = "- 5元\n- $10\n- 12.5%\n- 3℃\n- 8 kg\n- 21 km"

        XCTAssertEqual(VoicePolishNumbering.listItemCount(in: facts, kind: .bulletList), 0)
        XCTAssertEqual(VoicePolishNumbering.recognizedListItemCount(in: facts), 0)
        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: facts, as: .numberedList),
            facts
        )
        XCTAssertEqual(
            VoicePolishNumbering.removingProvenBulletLineMarkers(in: facts),
            facts
        )
    }

    func testProvenListMarkerRemovalKeepsNegativeSignsDirectional() {
        let bullets = "- 确认需求\n- 补齐测试"
        let negatives = "- 5 kg\n- 10 km"

        XCTAssertEqual(
            VoicePolishNumbering.removingProvenListLineMarkers(in: bullets),
            "确认需求\n补齐测试"
        )
        XCTAssertEqual(
            VoicePolishNumbering.removingProvenListLineMarkers(in: negatives),
            negatives
        )
    }

    func testBareNumericDomainsAreNotNumberedMarkers() {
        let domains = "1.example.com\n2.example.com"

        XCTAssertEqual(VoicePolishNumbering.listItemCount(in: domains, kind: .numberedList), 0)
        XCTAssertEqual(VoicePolishNumbering.recognizedListItemCount(in: domains), 0)
        XCTAssertEqual(
            VoicePolishNumbering.normalizeExistingList(in: domains, as: .numberedList),
            domains
        )
    }

    func testRemovingContinuousNumberedLineMarkersPreservesTwelveItemBodies() {
        let source = (1...12)
            .map { "\($0). 第\($0)项保留错误码 E\(100 + $0)" }
            .joined(separator: "\n")
        let expected = (1...12)
            .map { "第\($0)项保留错误码 E\(100 + $0)" }
            .joined(separator: "\n")

        XCTAssertEqual(
            VoicePolishNumbering.removingContinuousNumberedLineMarkers(in: source),
            expected
        )
    }

    func testRemovingNumberedMarkersLeavesYearsErrorsAndInvalidSequencesUntouched() {
        let years = "2026. 项目启动\n2027. 项目交付"
        let errors = "42. 请求失败\n43. 权限不足"
        let repeated = "1. 请求失败\n1. 权限不足"
        let outOfOrder = "2. 权限不足\n1. 请求失败"

        for facts in [years, errors, repeated, outOfOrder] {
            XCTAssertEqual(
                VoicePolishNumbering.removingContinuousNumberedLineMarkers(in: facts),
                facts
            )
        }
    }

    func testRemovingContinuousMarkersAcrossSegmentsKeepsSegmentIdentity() {
        let segments = (1...12).map { ordinal in
            RecognitionSegment(
                id: "s\(ordinal)",
                text: "\(ordinal). 第\(ordinal)项，错误码 E\(100 + ordinal)",
                startTimeMs: ordinal * 100,
                endTimeMs: ordinal * 100 + 50,
                confidence: 0.9,
                isFinal: true
            )
        }

        let cleaned = VoicePolishNumbering.removingContinuousNumberedLineMarkers(
            from: segments
        )

        XCTAssertEqual(cleaned.map(\.id), segments.map(\.id))
        XCTAssertEqual(cleaned.map(\.startTimeMs), segments.map(\.startTimeMs))
        XCTAssertEqual(cleaned.first?.text, "第1项，错误码 E101")
        XCTAssertEqual(cleaned.last?.text, "第12项，错误码 E112")
    }
}
