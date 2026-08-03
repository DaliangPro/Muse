import XCTest
@testable import Muse

final class VoicePolishFallbackFormatterTests: XCTestCase {
    func testParagraphFallbackPrefersCanonicalSegments() {
        let request = makeRequest(
            "第一段保留预算 49,800 元。第二段保留版本 v2.1.0。",
            segments: [
                "第一段保留预算 49,800 元。",
                "第二段保留版本 v2.1.0。",
            ]
        )

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: paragraphs(minimum: 2)
            ),
            "第一段保留预算 49,800 元。\n\n第二段保留版本 v2.1.0。"
        )
    }

    func testParagraphFallbackPreservesProvenASCIISeparatorBetweenSegments() {
        let source = "请保存到 /Users/alice/My Project/config.json。然后重启。"
        let request = makeRequest(
            source,
            segments: [
                "请保存到 /Users/alice/My",
                "Project/config.json。",
                "然后重启。",
            ]
        )

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: paragraphs(minimum: 2)
            ),
            "请保存到 /Users/alice/My Project/config.json。\n\n然后重启。"
        )
    }

    func testParagraphFallbackGroupsSentenceBoundariesToMinimumCount() {
        let source = "第一句话。第二句话。第三句话。第四句话。"
        let request = makeRequest(source)

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: paragraphs(minimum: 2)
            ),
            "第一句话。第二句话。\n\n第三句话。第四句话。"
        )
    }

    func testChineseExplicitEnumerationBecomesChineseNumberedList() {
        let source = "今天有三件事：第一，确认需求。第二，补齐测试。第三，发布前演练。"
        let request = makeRequest(source)

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: numbered(expected: 3, preference: .chinese)
            ),
            """
            今天有三件事：

            一、确认需求。
            二、补齐测试。
            三、发布前演练。
            """
        )
    }

    func testSpokenOrdinalListAppendsExplicitTrailingAdditionAsFourthItem() {
        let source = "今天我有三件事要做。第一个是我要给自己买一个沙发套。第二个是我希望 把我下一周的稿子都集中写完，至少也要把选题写完。第三个就是就是 就是把快递都拿了。哦，再补充一个事吧，就是 给自己选一身适合健身穿的衣服。"
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 4,
            numberingPreference: .arabic
        )
        let expected = """
        今天我有三件事要做。

        1. 我要给自己买一个沙发套。
        2. 我希望 把我下一周的稿子都集中写完，至少也要把选题写完。
        3. 就是 就是把快递都拿了。
        4. 哦，再补充一个事吧，就是 给自己选一身适合健身穿的衣服。
        """

        let formatted = VoicePolishFallbackFormatter.format(
            request: makeRequest(source),
            expectation: expectation
        )
        XCTAssertEqual(formatted, expected)
        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: expectation
            ),
            expected
        )
        XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: source,
            candidate: formatted,
            expectation: expectation
        ))
    }

    func testEquivalentExplicitTrailingAdditionPhrasesBecomeFourthItem() {
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 4,
            numberingPreference: .arabic
        )
        let additions = [
            "还有一项，就是通知团队。",
            "另外还有一项，就是通知团队。",
            "此外还有一项，就是通知团队。",
            "另有一项，就是通知团队。",
            "另一个问题，就是通知团队。",
            "另外一项，就是通知团队。",
            "额外增加一项，就是通知团队。",
            "额外一个事项，就是通知团队。",
            "加上一项，就是通知团队。",
        ]

        for addition in additions {
            let source = "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。\(addition)"
            let expected = """
            今天有三件事。

            1. 确认需求。
            2. 安排开发。
            3. 完成测试。
            4. \(addition)
            """
            XCTAssertEqual(
                VoicePolishFallbackFormatter.formatCandidate(
                    source,
                    expectation: expectation
                ),
                expected,
                addition
            )
        }
    }

    func testSpokenOrdinalListDoesNotInventFourthItemFromOrdinaryNewTopic() {
        let source = "今天我有三件事要做。第一个是确认需求。第二个是安排开发。第三个就是完成测试。哦，再说一个话题吧，就是团队氛围。"
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 4,
            numberingPreference: .arabic
        )

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: expectation
            ),
            source
        )
    }

    func testSpokenOrdinalListDoesNotSplitTrailingCommandAsFourthItem() {
        let source = "今天有三件事。第一个是确认需求。第二个是安排开发。第三个就是完成测试。哦，再补充一个事吧，就是运行 git status; npm test。"
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 4,
            numberingPreference: .arabic
        )

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: expectation
            ),
            source
        )
    }

    func testChineseImplicitStepsKeepConnectorsAndBecomeNumberedList() {
        let source = "先确认需求，然后安排开发，最后完成回归测试。"
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 3,
            numberingPreference: .arabic
        )
        let expected = """
        1. 先确认需求，
        2. 然后安排开发，
        3. 最后完成回归测试。
        """

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: expectation
            ),
            expected
        )
        XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: source,
            candidate: expected,
            expectation: expectation
        ))
    }

    func testFormalChineseAndEnglishImplicitStepsBecomeNumberedLists() {
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 3,
            numberingPreference: .arabic
        )
        let cases = [
            (
                "首先确认需求，其次安排开发，最后完成测试。",
                "1. 首先确认需求，\n2. 其次安排开发，\n3. 最后完成测试。"
            ),
            (
                "First, confirm scope. Then assign owners. Finally run regression tests.",
                "1. First, confirm scope.\n2. Then assign owners.\n3. Finally run regression tests."
            ),
            (
                "好的，先确认需求，然后安排开发，最后完成测试。",
                "1. 好的，先确认需求，\n2. 然后安排开发，\n3. 最后完成测试。"
            ),
            (
                "我们首先确认需求，其次安排开发，最后完成测试。",
                "1. 我们首先确认需求，\n2. 其次安排开发，\n3. 最后完成测试。"
            ),
            (
                "We first confirm scope. Then assign owners. Finally run regression tests.",
                "1. We first confirm scope.\n2. Then assign owners.\n3. Finally run regression tests."
            ),
            (
                "先确认需求，然后安排开发，接着完成测试。",
                "1. 先确认需求，\n2. 然后安排开发，\n3. 接着完成测试。"
            ),
            (
                "Start by confirming scope, then assign owners, next run regression tests.",
                "1. Start by confirming scope,\n2. then assign owners,\n3. next run regression tests."
            ),
            (
                "我们先确认需求，然后安排开发，最后完成测试。",
                "1. 我们先确认需求，\n2. 然后安排开发，\n3. 最后完成测试。"
            ),
            (
                "先确认需求，再安排开发，然后完成测试。",
                "1. 先确认需求，\n2. 再安排开发，\n3. 然后完成测试。"
            ),
        ]

        for (source, expected) in cases {
            XCTAssertEqual(
                VoicePolishFallbackFormatter.formatCandidate(
                    source,
                    expectation: expectation
                ),
                expected,
                source
            )
            XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
                source: source,
                candidate: expected,
                expectation: expectation
            ))
        }
    }

    func testParallelItemsCanAppendOneProvenTrailingAddition() {
        let source = "今天有三项：确认需求、安排开发、完成测试。再补充一项：通知团队。"
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 4,
            numberingPreference: .arabic
        )
        let expected = """
        今天有三项：

        1. 确认需求、
        2. 安排开发、
        3. 完成测试。
        4. 再补充一项：通知团队。
        """

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: expectation
            ),
            expected
        )
        XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: source,
            candidate: expected,
            expectation: expectation
        ))
    }

    func testTrailingAdditionKeepsRealCancelActionButRejectsLaterRetraction() {
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 4,
            numberingPreference: .arabic
        )
        let valid = "今天有三件事。第一，确认需求。第二，安排开发。第三，完成测试。再补充一项：取消周五会议。"
        let expected = """
        今天有三件事。

        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 再补充一项：取消周五会议。
        """
        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                valid,
                expectation: expectation
            ),
            expected
        )

        let cancelled = "今天有三件事。第一，确认需求。第二，安排开发。第三，完成测试。再补充一项：发布。算了，这项不用了。"
        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                cancelled,
                expectation: expectation
            ),
            cancelled
        )
    }

    func testEnglishExplicitEnumerationBecomesArabicNumberedList() {
        let source = "Three tasks: first, confirm requirements; second, add tests; third, rehearse release."
        let request = makeRequest(source)

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: numbered(expected: 3, preference: .arabic)
            ),
            """
            Three tasks:

            1. confirm requirements;
            2. add tests;
            3. rehearse release.
            """
        )
    }

    func testSemicolonSeparatedFactsBecomeBulletListOnlyWhenContractMatches() {
        let source = "问题包括：识别慢；不会分段；提示词没执行。"
        let request = makeRequest(source)

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: bullets(expected: 3)
            ),
            """
            问题包括：

            - 识别慢；
            - 不会分段；
            - 提示词没执行。
            """
        )
        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: bullets(expected: 4)
            ),
            source
        )
    }

    func testSemicolonSplitUsesIntroductoryColonInsteadOfTimeColon() {
        let source = "时间包括：10:30；11:00；12:00"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(source),
                expectation: numbered(expected: 3, preference: .arabic)
            ),
            """
            时间包括：

            1. 10:30；
            2. 11:00；
            3. 12:00
            """
        )
    }

    func testSemicolonSplitPreservesURLsAndDoesNotTreatSchemeColonAsHeading() {
        let source = "链接包括：https://example.com/a；https://example.com/b；https://example.com/c"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(source),
                expectation: bullets(expected: 3)
            ),
            """
            链接包括：

            - https://example.com/a；
            - https://example.com/b；
            - https://example.com/c
            """
        )
    }

    func testASCIISemicolonsInsideURLAndDataURIRemainUntouched() {
        let url = "链接包括：https://example.com/a;b;c"
        let dataURI = "内容包括：data:text/plain;charset=utf-8;base64,SGVsbG8=;tail"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(url),
                expectation: bullets(expected: 3)
            ),
            url
        )
        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                dataURI,
                expectation: bullets(expected: 3)
            ),
            dataURI
        )
    }

    func testCodeSceneDoesNotSplitSemicolonDelimitedText() {
        let source = "代码包括：let a = 1; let b = 2; return a + b"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(source, scene: .code),
                expectation: bullets(expected: 3)
            ),
            source
        )
    }

    func testShellAndPathSemicolonsDoNotSplitOutsideCodeScene() {
        let shell = "步骤包括：for i in a; do echo \"$i\"; done"
        let path = "路径包括：/tmp/a;b;c"
        let expectation = numbered(expected: 3, preference: .arabic)

        for source in [shell, path] {
            XCTAssertEqual(
                VoicePolishFallbackFormatter.format(
                    request: makeRequest(source, scene: .workChat),
                    expectation: expectation
                ),
                source
            )
            XCTAssertEqual(
                VoicePolishFallbackFormatter.formatCandidate(
                    source,
                    expectation: expectation
                ),
                source
            )
        }
    }

    func testCodeAndCommandHeadingsDoNotSplitOutsideCodeScene() {
        let sources = [
            "代码包括：alpha；beta；gamma",
            "命令包括：echo one; echo two; echo three",
            "Shell steps: echo one; echo two; echo three",
        ]
        let expectation = numbered(expected: 3, preference: .arabic)

        for source in sources {
            XCTAssertEqual(
                VoicePolishFallbackFormatter.format(
                    request: makeRequest(source, scene: .workChat),
                    expectation: expectation
                ),
                source
            )
            XCTAssertEqual(
                VoicePolishFallbackFormatter.formatCandidate(
                    source,
                    expectation: expectation
                ),
                source
            )
        }
    }

    func testFunctionCallsAndCommonShellCommandsDoNotSplitOutsideCodeScene() {
        let sources = [
            "步骤包括：fetch(); transform(); save()",
            "步骤包括：git status; npm test; swift build",
        ]
        let expectation = bullets(expected: 3)

        for source in sources {
            XCTAssertEqual(
                VoicePolishFallbackFormatter.format(
                    request: makeRequest(source, scene: .workChat),
                    expectation: expectation
                ),
                source
            )
            XCTAssertEqual(
                VoicePolishFallbackFormatter.formatCandidate(
                    source,
                    expectation: expectation
                ),
                source
            )
        }
    }

    func testCodeSceneCanonicalFallbackPreservesAllLayoutExactly() {
        let source = "1) echo one ;;\n    2) echo two ;;"
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: 2,
            minimumListItemCount: 2,
            numberingPreference: .arabic,
            forbidsLists: true,
            forbidsLineBreaks: true
        )

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(source, scene: .code),
                expectation: expectation
            ),
            source
        )
    }

    func testExistingUnmarkedLinesCanBeSafelyNumbered() {
        let source = "确认需求\n补齐测试\n发布前演练"
        let request = makeRequest(source)

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: request,
                expectation: numbered(expected: 3, preference: .arabic)
            ),
            "1. 确认需求\n2. 补齐测试\n3. 发布前演练"
        )
    }

    func testExistingChineseParenthesizedNumbersCanBeNormalizedSafely() {
        let source = "（一）确认需求\n（二）补齐测试\n（三）发布前演练"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(source),
                expectation: numbered(expected: 3, preference: .chinese)
            ),
            "一、确认需求\n二、补齐测试\n三、发布前演练"
        )
    }

    func testOutOfOrderAndDuplicateNumberedLinesRemainUntouched() {
        let outOfOrder = "1. 确认需求\n3. 发布演练\n2. 补齐测试"
        let repeated = "1. 确认需求\n1. 补齐测试\n3. 发布演练"

        for source in [outOfOrder, repeated] {
            XCTAssertEqual(
                VoicePolishFallbackFormatter.format(
                    request: makeRequest(source),
                    expectation: numbered(expected: 3, preference: .arabic)
                ),
                source
            )
        }
    }

    func testCandidateBlobCanBeGroupedIntoParagraphsWithoutOriginalSegments() {
        let source = "第一句话。第二句话。第三句话。"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: paragraphs(minimum: 2)
            ),
            "第一句话。第二句话。\n\n第三句话。"
        )
    }

    func testCommonAbbreviationsAreNotUsedAsParagraphBoundaries() {
        let source = "Dr. Smith reviewed the U.S. market. We used e.g. a benchmark. Then shipped."

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: paragraphs(minimum: 3)
            ),
            "Dr. Smith reviewed the U.S. market.\n\nWe used e.g. a benchmark.\n\nThen shipped."
        )
    }

    func testExactIdeographicEnumerationWithSafeHeadingBecomesList() {
        let source = "这次有三点：需求、负责人、排期"
        let expectation = numbered(expected: 3, preference: .arabic)
        let expected = """
        这次有三点：

        1. 需求、
        2. 负责人、
        3. 排期
        """

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(source),
                expectation: expectation
            ),
            expected
        )
        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: expectation
            ),
            expected
        )
    }

    func testExactChineseCommaEnumerationBecomesListWithOrWithoutColon() {
        let sources = [
            "这次有三个问题：识别慢，不会分段，提示词没执行。",
            "这次有三个问题，识别慢，不会分段，提示词没执行。",
        ]
        let expectedPrefixes = ["这次有三个问题：", "这次有三个问题，"]

        for (source, prefix) in zip(sources, expectedPrefixes) {
            let expected = """
            \(prefix)

            1. 识别慢，
            2. 不会分段，
            3. 提示词没执行。
            """
            XCTAssertEqual(
                VoicePolishFallbackFormatter.format(
                    request: makeRequest(source),
                    expectation: numbered(expected: 3, preference: .arabic)
                ),
                expected
            )
            XCTAssertEqual(
                VoicePolishFallbackFormatter.formatCandidate(
                    source,
                    expectation: numbered(expected: 3, preference: .arabic)
                ),
                expected
            )
        }
    }

    func testMinimumOnlyChineseCommaEnumerationWithSafeHeadingStillBecomesList() {
        let source = "这次主要有几个问题：识别慢，不会分段，提示词没执行。"
        let expectation = VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: 3,
            numberingPreference: .arabic
        )
        let expected = """
        这次主要有几个问题：

        1. 识别慢，
        2. 不会分段，
        3. 提示词没执行。
        """

        let formatted = VoicePolishFallbackFormatter.formatCandidate(
            source,
            expectation: expectation
        )
        XCTAssertEqual(formatted, expected)
        XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: source,
            candidate: formatted,
            expectation: expectation
        ))
    }

    func testIdeographicEnumerationRequiresSafeHeadingAndExactCount() {
        let ordinary = "参与人是张三、李四、王五"
        let wrongCount = "这次有三点：需求、负责人"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                ordinary,
                expectation: numbered(expected: 3, preference: .arabic)
            ),
            ordinary
        )
        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                wrongCount,
                expectation: numbered(expected: 3, preference: .arabic)
            ),
            wrongCount
        )
    }

    func testForbiddenListIsSafelyStrippedBeforeSingleLineNormalization() {
        let source = "1. 确认需求\n2. 补齐测试\n3. 发布前演练"
        let expectation = VoicePolishLayoutExpectation(
            kind: .sentence,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: nil,
            numberingPreference: .none,
            forbidsLists: true,
            forbidsLineBreaks: true
        )

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(source, expectation: expectation),
            "确认需求 补齐测试 发布前演练"
        )
    }

    func testUnsafeErrorCodeLinesRemainVisibleWhenSingleLineListsAreForbidden() {
        let source = "42. 请求失败\n43. 权限不足"
        let expectation = VoicePolishLayoutExpectation(
            kind: .sentence,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: nil,
            numberingPreference: .none,
            forbidsLists: true,
            forbidsLineBreaks: true
        )

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(source, expectation: expectation),
            "42. 请求失败 43. 权限不足"
        )
    }

    func testSpacedNegativeFactsKeepMinusWhenListLayoutChanges() {
        let source = "- 5 kg\n- 10 km"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(
                source,
                expectation: numbered(expected: 2, preference: .arabic)
            ),
            "1. - 5 kg\n2. - 10 km"
        )

        let singleLine = VoicePolishLayoutExpectation(
            kind: .sentence,
            minimumParagraphCount: 1,
            expectedListItemCount: nil,
            minimumListItemCount: nil,
            numberingPreference: .none,
            forbidsLists: true,
            forbidsLineBreaks: true
        )
        XCTAssertEqual(
            VoicePolishFallbackFormatter.formatCandidate(source, expectation: singleLine),
            "- 5 kg - 10 km"
        )
    }

    func testStrictSafetyAllowsOnlyWhitespaceAndProvenListMarkers() {
        let semicolonSource = "问题包括：识别慢；不会分段；提示词没执行。"
        let semicolonExpectation = bullets(expected: 3)
        let semicolonCandidate = VoicePolishFallbackFormatter.formatCandidate(
            semicolonSource,
            expectation: semicolonExpectation
        )
        XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: semicolonSource,
            candidate: semicolonCandidate,
            expectation: semicolonExpectation
        ))

        let ideographicSource = "这次有三点：需求、负责人、排期"
        let numberedExpectation = numbered(expected: 3, preference: .arabic)
        let ideographicCandidate = VoicePolishFallbackFormatter.formatCandidate(
            ideographicSource,
            expectation: numberedExpectation
        )
        XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: ideographicSource,
            candidate: ideographicCandidate,
            expectation: numberedExpectation
        ))

        XCTAssertFalse(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: semicolonSource,
            candidate: semicolonCandidate.replacingOccurrences(of: "；", with: ""),
            expectation: semicolonExpectation
        ))
        XCTAssertFalse(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: "- 5 kg\n- 10 kg",
            candidate: "5 kg 10 kg",
            expectation: VoicePolishLayoutExpectation(
                kind: .sentence,
                minimumParagraphCount: 1,
                expectedListItemCount: nil,
                minimumListItemCount: nil,
                numberingPreference: .none,
                forbidsLists: true,
                forbidsLineBreaks: true
            )
        ))
    }

    func testOrdinarySentenceAndInsufficientEnumerationRemainUntouched() {
        let ordinary = "这是一个完整的普通句子，没有可以安全拆分的结构。"
        let insufficient = "第一，确认需求。第二，补齐测试。"

        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(ordinary),
                expectation: paragraphs(minimum: 2)
            ),
            ordinary
        )
        XCTAssertEqual(
            VoicePolishFallbackFormatter.format(
                request: makeRequest(insufficient),
                expectation: numbered(expected: 3, preference: .chinese)
            ),
            insufficient
        )
    }

    func testFactCharactersDoNotDriftAfterRemovingLayoutCharacters() {
        let source = "信息如下：预算 49,800 元；版本 v2.1.0；日期 2026-08-03。"
        let result = VoicePolishFallbackFormatter.format(
            request: makeRequest(source),
            expectation: bullets(expected: 3)
        )

        XCTAssertTrue(VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: source,
            candidate: result,
            expectation: bullets(expected: 3)
        ))
        XCTAssertLessThan(result.range(of: "49,800")!.lowerBound, result.range(of: "v2.1.0")!.lowerBound)
        XCTAssertLessThan(result.range(of: "v2.1.0")!.lowerBound, result.range(of: "2026-08-03")!.lowerBound)
    }
}

private extension VoicePolishFallbackFormatterTests {
    func makeRequest(
        _ text: String,
        segments: [String]? = nil,
        scene: WritingScene = .unknown
    ) -> VoicePolishRequest {
        let values = segments ?? [text]
        let recognitionSegments = values.enumerated().map { index, value in
            RecognitionSegment(
                id: "s\(index + 1)",
                text: value,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
        }
        return VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                canonicalText: text,
                segments: recognitionSegments,
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(scene: scene),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .balanced
        )
    }

    func paragraphs(minimum: Int) -> VoicePolishLayoutExpectation {
        VoicePolishLayoutExpectation(
            kind: .paragraphs,
            minimumParagraphCount: minimum,
            expectedListItemCount: nil,
            minimumListItemCount: nil,
            numberingPreference: .none
        )
    }

    func numbered(
        expected: Int,
        preference: VoicePolishNumberingPreference
    ) -> VoicePolishLayoutExpectation {
        VoicePolishLayoutExpectation(
            kind: .numberedList,
            minimumParagraphCount: 1,
            expectedListItemCount: expected,
            minimumListItemCount: expected,
            numberingPreference: preference
        )
    }

    func bullets(expected: Int) -> VoicePolishLayoutExpectation {
        VoicePolishLayoutExpectation(
            kind: .bulletList,
            minimumParagraphCount: 1,
            expectedListItemCount: expected,
            minimumListItemCount: expected,
            numberingPreference: .none
        )
    }

}
