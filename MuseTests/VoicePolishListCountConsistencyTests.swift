import XCTest
@testable import Muse

final class VoicePolishListCountConsistencyTests: XCTestCase {
    func testSynchronizesOnlyChineseDeclaredCountForOneProvenTrailingAddition() {
        let candidate = """
        今天我有三件事要做。

        一、给自己买一个沙发套。
        二、把下一周的选题写完。
        三、把快递都拿了。
        四、哦，再补充一个事吧，就是选一身适合健身穿的衣服。
        """
        let canonicalSource = "今天我有三件事要做。第一个是给自己买一个沙发套。第二个是把下一周的选题写完。第三个就是把快递都拿了。哦，再补充一个事吧，就是选一身适合健身穿的衣服。"
        let expected = candidate.replacingOccurrences(of: "三件事", with: "四件事")

        let result = VoicePolishListCountConsistency
            .synchronizeDeclaredCountForProvenTrailingAddition(
                in: candidate,
                canonicalSource: canonicalSource
            )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(
            VoicePolishListCountConsistency.declaredCountMatchesList(in: result),
            true
        )
    }

    func testSynchronizesArabicDeclaredCountWithoutChangingOtherCharacters() {
        let source = """
        今天总共有3项待办：
        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 对了，再加一项：完成发布。
        """
        let expected = source.replacingOccurrences(of: "3项", with: "4项")

        XCTAssertEqual(
            VoicePolishListCountConsistency
                .synchronizeDeclaredCountForProvenTrailingAddition(
                    in: source,
                    canonicalSource: source
                ),
            expected
        )
    }

    func testCandidateOnlyHallucinatedAdditionCannotSynchronizeDeclaredCount() {
        let canonicalSource = "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。"
        let candidate = """
        今天有三件事。

        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 哦，再补充一个事吧，就是发布上线。
        """

        XCTAssertEqual(
            VoicePolishListCountConsistency
                .synchronizeDeclaredCountForProvenTrailingAddition(
                    in: candidate,
                    canonicalSource: canonicalSource
                ),
            candidate
        )
        XCTAssertEqual(
            VoicePolishListCountConsistency.declaredCountMatchesList(in: candidate),
            false
        )
    }

    func testSupportsAllExplicitPositiveSingleAdditionPhrases() {
        let phrases = [
            "还有一项",
            "另外还有一项",
            "此外还有一项",
            "另有一项",
            "另一个问题",
            "另外一项",
            "额外增加一项",
            "额外补充一项",
            "额外一个事项",
            "加上一项",
        ]

        for phrase in phrases {
            let canonicalSource = "今天有三项。第一，确认需求。第二，安排开发。第三，完成测试。\(phrase)：通知团队。"
            let candidate = """
            今天有三项。

            1. 确认需求。
            2. 安排开发。
            3. 完成测试。
            4. \(phrase)：通知团队。
            """
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: candidate,
                        canonicalSource: canonicalSource
                    ),
                candidate.replacingOccurrences(of: "三项", with: "四项"),
                phrase
            )
        }
    }

    func testSynchronizesBulletListWhenCanonicalSourceProvesAddition() {
        let canonicalSource = "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。此外还有一项：通知团队。"
        let candidate = """
        今天有三件事。

        - 确认需求。
        - 安排开发。
        - 完成测试。
        - 此外还有一项：通知团队。
        """

        XCTAssertEqual(
            VoicePolishListCountConsistency
                .synchronizeDeclaredCountForProvenTrailingAddition(
                    in: candidate,
                    canonicalSource: canonicalSource
                ),
            candidate.replacingOccurrences(of: "三件事", with: "四件事")
        )
    }

    func testSynchronizesWhenCanonicalSourceHasExactInlineParallelItems() {
        let canonicalSources = [
            "今天有三项：确认需求、安排开发、完成测试。再补充一项：通知团队。",
            "今天有三项：确认需求，安排开发，完成测试。再补充一项：通知团队。",
            "今天有三项：确认需求, 安排开发, 完成测试。再补充一项：通知团队。",
        ]
        let candidate = """
        今天有三项：
        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 再补充一项：通知团队。
        """
        let expected = candidate.replacingOccurrences(of: "三项", with: "四项")

        for canonicalSource in canonicalSources {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: candidate,
                        canonicalSource: canonicalSource
                    ),
                expected,
                canonicalSource
            )
        }
    }

    func testRejectsUnsafeOrInexactInlineParallelCanonicalEvidence() {
        let candidate = """
        今天有三项：
        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 再补充一项：通知团队。
        """
        let invalidCanonicalSources = [
            "今天有三项：确认需求、安排开发。再补充一项：通知团队。",
            "上周有三项旧任务已经归档：确认需求、安排开发、完成测试。再补充一项：通知团队。",
            "今天有三项：确认需求、安排开发、完成测试。再补充一项：通知团队，再加一项：复盘。",
            "今天有三项：确认需求、安排开发、完成测试。再补充一项：通知团队。算了，这项不用了。",
        ]

        for canonicalSource in invalidCanonicalSources {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: candidate,
                        canonicalSource: canonicalSource
                    ),
                candidate,
                canonicalSource
            )
        }
    }

    func testUnrelatedQuotedTermDoesNotBlockProvenCountSynchronization() {
        let canonicalSource = "今天有三件事。第一个是保留术语“Typeless”。第二个是安排开发。第三个是完成测试。再补充一个事，就是通知团队。"
        let candidate = """
        今天有三件事。

        1. 保留术语“Typeless”。
        2. 安排开发。
        3. 完成测试。
        4. 再补充一个事，就是通知团队。
        """

        XCTAssertEqual(
            VoicePolishListCountConsistency
                .synchronizeDeclaredCountForProvenTrailingAddition(
                    in: candidate,
                    canonicalSource: canonicalSource
                ),
            candidate.replacingOccurrences(of: "三件事", with: "四件事")
        )
    }

    func testReportsMatchingAndMismatchingUniqueDeclarations() {
        let matching = """
        这次有四项：
        1. 需求。
        2. 排期。
        3. 测试。
        4. 发布。
        """
        let mismatching = matching.replacingOccurrences(of: "四项", with: "三项")

        XCTAssertEqual(
            VoicePolishListCountConsistency.declaredCountMatchesList(in: matching),
            true
        )
        XCTAssertEqual(
            VoicePolishListCountConsistency.declaredCountMatchesList(in: mismatching),
            false
        )
        XCTAssertNil(
            VoicePolishListCountConsistency.declaredCountMatchesList(
                in: "1. 需求。\n2. 排期。"
            )
        )
    }

    func testConsistencyChecksNumberedAndBulletListsDespiteUnrelatedContent() {
        let numbered = """
        这里有三项：
        1. 保留引用“例如”的原话。
        2. 执行命令 `git status`。
        3. 完成发布。

        以上是普通收束段落。
        """
        let bullets = """
        这里有三项：
        - 保留引用“例如”的原话。
        - 执行命令 `git status`。
        - 完成发布。

        以上是普通收束段落。
        """

        for text in [numbered, bullets] {
            XCTAssertEqual(
                VoicePolishListCountConsistency.declaredCountMatchesList(in: text),
                true
            )
            XCTAssertEqual(
                VoicePolishListCountConsistency.declaredCountMatchesList(
                    in: text.replacingOccurrences(of: "三项", with: "两项")
                ),
                false
            )
        }
    }

    func testRecognizesCommonCountTitlesAndReportsFourItemsAsMismatch() {
        let titles = [
            "主要讲三点",
            "归纳为三点",
            "总结成三点：",
        ]

        for title in titles {
            let text = """
            \(title)
            1. 需求。
            2. 排期。
            3. 测试。
            4. 发布。
            """

            XCTAssertEqual(
                VoicePolishListCountConsistency.declaredCountMatchesList(in: text),
                false,
                title
            )
        }
    }

    func testDoesNotTreatEarlierBodyCountAsTheListDeclaration() {
        let text = """
        本周有三项旧任务已经归档。

        新的安排如下：
        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 发布上线。
        """

        XCTAssertNil(
            VoicePolishListCountConsistency.declaredCountMatchesList(in: text)
        )
    }

    func testRejectsNegatedOrCancelledTrailingAddition() {
        let sources = [
            """
            今天有三件事：
            1. 需求。
            2. 排期。
            3. 测试。
            4. 哦，不要再补充一个事了。
            """,
            """
            今天有三件事：
            1. 需求。
            2. 排期。
            3. 测试。
            4. 哦，再补充一个事吧，不对，取消这个补充。
            """,
        ]

        for source in sources {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: source,
                        canonicalSource: source
                    ),
                source
            )
        }
    }

    func testCancellationVerbsInsideNewItemRemainValidAdditions() {
        let itemBodies = [
            "取消周五会议",
            "删掉过期文件",
        ]

        for itemBody in itemBodies {
            let source = """
            今天有三项：
            1. 确认需求。
            2. 安排开发。
            3. 完成测试。
            4. 再补充一项：\(itemBody)。
            """

            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: source,
                        canonicalSource: source
                    ),
                source.replacingOccurrences(of: "三项", with: "四项"),
                itemBody
            )
        }
    }

    func testRejectsCrossSentenceCancellationOfTheNewItem() {
        let source = """
        今天有三项：
        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 再补充一项：发布。算了，这项不用了。
        """

        XCTAssertEqual(
            VoicePolishListCountConsistency
                .synchronizeDeclaredCountForProvenTrailingAddition(
                    in: source,
                    canonicalSource: source
                ),
            source
        )
    }

    func testRejectsQuotedOrExampleAddition() {
        let sources = [
            """
            今天有三件事：
            1. 需求。
            2. 排期。
            3. 测试。
            4. 他只是说“再补充一个事”，并没有真的新增。
            """,
            """
            示例：今天有三件事。
            1. 需求。
            2. 排期。
            3. 测试。
            4. 哦，再补充一个事吧，就是发布。
            """,
        ]

        for source in sources {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: source,
                        canonicalSource: source
                    ),
                source
            )
            XCTAssertEqual(
                VoicePolishListCountConsistency.declaredCountMatchesList(in: source),
                false
            )
        }
    }

    func testRejectsCodeOrCommandContent() {
        let source = """
        今天有三件事：
        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 哦，再补充一个事吧，就是运行 git status; npm test。
        """

        XCTAssertEqual(
            VoicePolishListCountConsistency
                .synchronizeDeclaredCountForProvenTrailingAddition(
                    in: source,
                    canonicalSource: source
                ),
            source
        )
        XCTAssertEqual(
            VoicePolishListCountConsistency.declaredCountMatchesList(in: source),
            false
        )
    }

    func testRejectsOrdinaryNewTopicAndMultipleAdditionMentions() {
        let sources = [
            """
            今天有三件事：
            1. 需求。
            2. 排期。
            3. 测试。
            4. 哦，再说一个话题吧，就是团队氛围。
            """,
            """
            今天有三件事：
            1. 需求。
            2. 排期。
            3. 测试。
            4. 哦，再补充一个事，再加一项发布检查。
            """,
        ]

        for source in sources {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: source,
                        canonicalSource: source
                    ),
                source
            )
        }
    }

    func testRejectsMultipleDeclarationsAndAddingTwoItems() {
        let multipleDeclarations = """
        今天有三件事，总共有三项待办：
        1. 需求。
        2. 排期。
        3. 测试。
        4. 哦，再补充一个事吧，就是发布。
        """
        let addingTwo = """
        今天有三件事：
        1. 需求。
        2. 排期。
        3. 测试。
        4. 哦，再补充两项发布检查。
        """

        for source in [multipleDeclarations, addingTwo] {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: source,
                        canonicalSource: source
                    ),
                source
            )
        }
        XCTAssertEqual(
            VoicePolishListCountConsistency.declaredCountMatchesList(
                in: multipleDeclarations
            ),
            false
        )
    }

    func testRejectsMissingOrOutOfOrderNumbering() {
        let sources = [
            """
            今天有三件事：
            1. 需求。
            2. 排期。
            4. 哦，再补充一个事吧，就是发布。
            """,
            """
            今天有三件事：
            1. 需求。
            3. 测试。
            2. 排期。
            4. 哦，再补充一个事吧，就是发布。
            """,
        ]

        for source in sources {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: source,
                        canonicalSource: source
                    ),
                source
            )
            XCTAssertNil(
                VoicePolishListCountConsistency.declaredCountMatchesList(in: source)
            )
        }
    }

    func testRejectsInterruptedListTrailingProseAndLineEndingDrift() {
        let interrupted = """
        今天有三件事：
        1. 需求。
        2. 排期。
        这里插入一段普通正文。
        3. 测试。
        4. 哦，再补充一个事吧，就是发布。
        """
        let trailingProse = """
        今天有三件事：
        1. 需求。
        2. 排期。
        3. 测试。
        4. 哦，再补充一个事吧，就是发布。

        以上内容仅供讨论。
        """
        let windowsLineEndings = "今天有三件事：\r\n1. 需求。\r\n2. 排期。\r\n3. 测试。\r\n4. 哦，再补充一个事吧，就是发布。"

        for source in [interrupted, trailingProse, windowsLineEndings] {
            XCTAssertEqual(
                VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: source,
                        canonicalSource: source
                    ),
                source
            )
        }
    }
}
