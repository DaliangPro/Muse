import XCTest
@testable import Muse

final class VoicePolishLayoutExpectationTests: XCTestCase {

    func testOrdinaryShortSentenceRemainsSentence() {
        let expectation = infer(
            "明天下午三点开会。",
            requirements: "表达清楚，自动优化排版。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertEqual(expectation.minimumParagraphCount, 1)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
        XCTAssertEqual(expectation.numberingPreference, .none)
    }

    func testListPreferenceDoesNotTurnSingleFactIntoList() {
        let expectation = infer(
            "明天下午三点开会。",
            requirements: "请用一二三编号排版。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
    }

    func testOrdinaryWordsContainingXianDoNotBecomeImplicitSteps() {
        let expectation = infer(
            "王先生介绍了祖先留下的资料，我们会预先确认会议时间。",
            requirements: "请在内容确实有多个步骤时使用编号列表。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testConditionalListRuleInLongPromptDoesNotCreateSourceListEvidence() {
        let requirements = """
        保留原意和事实，不要增加没有说过的信息。根据内容自然优化表达和标点。
        如果原文确实包含多个步骤或并列要点，请使用编号列表；如果只是普通叙述，保持自然段落。
        输出前检查专有名词、数字和时间，确保没有遗漏，也不要因为提示词里出现“编号”或“列表”就强制列点。
        """
        let expectation = infer(
            "今天和客户确认了会议时间。明天下午继续讨论预算。",
            requirements: requirements,
            scene: .workChat
        )

        XCTAssertNotEqual(expectation.kind, .numberedList)
        XCTAssertNotEqual(expectation.kind, .bulletList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testConditionalShortContentNoListDoesNotBlockNumberedItems() {
        let expectation = infer(
            "这次有三个事项：确认需求；明确负责人；完成回归测试。",
            requirements: "短内容不要列表；多个事项用 1.2.3 编号。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 3)
        XCTAssertEqual(expectation.numberingPreference, .arabic)
        XCTAssertFalse(expectation.forbidsLists)
        XCTAssertFalse(expectation.forbidsNumberedList)
    }

    func testConditionalNoTopicParagraphRuleDoesNotBecomeGlobalBan() {
        let source = String(
            repeating: "我们需要梳理产品背景用户反馈当前障碍解决方向以及后续验收方式",
            count: 3
        )
        let expectation = infer(
            source,
            requirements: "没有多主题时不分段；长内容按语义自然分段。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
        XCTAssertFalse(expectation.forbidsLineBreaks)
    }

    func testLongPromptSingleParagraphLengthRuleDoesNotForbidParagraphs() {
        let source = String(
            repeating: "这部分内容需要交代产品背景用户问题当前影响处理思路以及后续验收安排",
            count: 3
        )
        let requirements = """
        如果原文超过八十个汉字并包含多个语义层次，必须自然分段。
        背景、解释、核心问题和结论不要堆在一起，每段只承载一个主要意思。
        单段不要过长，如果一段同时包含多个主题就拆开。
        """
        let expectation = infer(source, requirements: requirements, scene: .document)

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
        XCTAssertFalse(expectation.forbidsLineBreaks)
    }

    func testDeclaredFortyEightItemLongListKeepsExactContract() {
        let expectation = infer(
            "下面共 48 项，请按原顺序逐项整理，每项都要完整保留。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 48)
        XCTAssertEqual(expectation.minimumListItemCount, 12)
        XCTAssertEqual(expectation.numberingPreference, .arabic)
    }

    func testMultipleRecognitionSegmentsAloneDoNotCreateListEvidence() {
        let expectation = infer(
            "今天和客户确认了会议时间。",
            requirements: "有多个要点时请用1. 2. 3.编号列表。",
            scene: .workChat,
            segments: ["今天", "和客户确认了", "会议时间"]
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testChineseExplicitEnumerationRequiresChineseNumberedList() {
        let expectation = infer(
            "第一，先确认需求。第二，安排开发。第三，完成回归测试。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 3)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
        XCTAssertEqual(expectation.numberingPreference, .chinese)
    }

    func testCompactUnpunctuatedChineseActionsProduceNumberedList() {
        let expectation = infer(
            "接下来主要做三件事第一检查第一次使用时的引导是不是足够清楚第二测试长内容能不能自动分段和整理标点第三记录每次润色的等待时间和失败情况最后把测试结果统一整理出来",
            scene: .unknown
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 3)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
        XCTAssertEqual(expectation.numberingPreference, .chinese)
    }

    func testAIPromptKeepsFiveIndependentDirectivesAsFiveListItems() {
        let sources = [
            "让AI帮我查这个Swift并发问题现象是偶发出现 MainActor isolated property cannot be referenced 然后不要直接改代码先解释原因列出可能的调用链最后给最小修改方案和需要补的测试",
            "让AI查这个 Swift 并发问题现象是 Main Actor isolated property cannot be refer enced。然后不要直接改代码先解释原因。列出调用链最后给最小修改方案和需要补的测试？",
        ]

        for source in sources {
            let expectation = infer(source, scene: .aiPrompt)
            XCTAssertEqual(expectation.kind, .numberedList, source)
            XCTAssertEqual(expectation.minimumListItemCount, 5, source)
        }
    }

    func testAIPromptDoesNotCountQuotedExampleAsIndependentDirectives() {
        let expectation = infer(
            "解释这段提示词为什么容易误导。原句是“不要修改代码，解释原因，列出调用链并给出方案和测试”。最后只给一段改写建议。",
            scene: .aiPrompt
        )

        XCTAssertNotEqual(expectation.minimumListItemCount, 5)
    }

    func testAIPromptOverlappingWordsDoNotBecomeThreeFakeDirectives() {
        let expectation = infer(
            "请不要直接输出测试方案，只需帮我把这句话润色顺。",
            scene: .aiPrompt
        )

        XCTAssertNotEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testAIPromptCountsRepeatedDirectiveKindsAtDifferentSpans() {
        let expectation = infer(
            "请解释原因，说明判断依据，说明影响范围，给出修复方案，给出回归计划。",
            scene: .aiPrompt
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.minimumListItemCount, 5)
    }

    func testAIPromptCountsRepeatedDirectiveKindsWithoutASRPunctuation() {
        let expectation = infer(
            "请解释原因说明判断依据说明影响范围给出修复方案给出回归计划",
            scene: .aiPrompt
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.minimumListItemCount, 5)
    }

    func testSingleOrdinalMentionDoesNotBecomeCompactEnumeration() {
        let expectation = infer(
            "现在除了第二项，其他内容都测试成功了。第二项在文字试跑中显示原文回退，但正式润色已经成功。",
            requirements: "如果确实有多个步骤或并列事项，请使用编号列表。",
            scene: .unknown
        )

        XCTAssertNotEqual(expectation.kind, .numberedList)
        XCTAssertNotEqual(expectation.kind, .bulletList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testSecondTestNarrativeDoesNotBecomeCompactEnumeration() {
        let expectation = infer(
            "这是第二次测试的结果，整体已经通过。",
            scene: .unknown
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testChineseDeclaredCountProducesExactNumberedListContract() {
        let expectation = infer(
            "这次主要有三点：需求要确认；负责人要明确；上线前要完成回归测试。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 3)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
    }

    func testCommonProblemUnitProducesExactCountLikeSystemExample() {
        let expectation = infer(
            "这次有三个问题，识别慢，不会分段，还有提示词没执行。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 3)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
    }

    func testLatestCorrectedDeclaredCountWins() {
        let expectation = infer(
            "这次主要有三点，不对，是四点：需求、负责人、排期、回归测试。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 4)
        XCTAssertEqual(expectation.minimumListItemCount, 4)
    }

    func testNegatedIntermediateCountUsesFinalPositiveCorrection() {
        let expectation = infer(
            "原来三点，不是四点，是五点：需求、负责人、排期、回归测试、上线确认。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 5)
        XCTAssertEqual(expectation.minimumListItemCount, 5)
    }

    func testCorrectionToSingleItemDoesNotKeepOldListContract() {
        let expectation = infer(
            "原来有三项，不对，最终改成一项：只保留回归测试。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testCorrectionToSingleItemSuppressesSupersededExplicitEnumeration() {
        let expectation = infer(
            "原来有三项：第一，确认需求。第二，明确负责人。第三，确定排期。不对，最终改成一项：只做回归测试。",
            scene: .workChat
        )

        XCTAssertNotEqual(expectation.kind, .numberedList)
        XCTAssertNotEqual(expectation.kind, .bulletList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testIndependentCountGroupsDoNotLockToLastGroup() {
        let expectation = infer(
            "先讲三个问题：速度、排版、术语。再给两个方案：短期修复、长期优化。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertGreaterThanOrEqual(expectation.minimumListItemCount ?? 0, 3)
    }

    func testAdditionalTwoItemsDoNotReplaceEarlierThreeWithExactTwo() {
        let expectation = infer(
            "先有三项：需求、排期、测试。另外还有两项：部署、复盘。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 5)
    }

    func testUnnumberedAdditionalProblemIncreasesDeclaredMinimum() {
        let expectation = infer(
            "这次有三项：需求、排期、测试。另一个问题是上线前还要完成演练。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 4)
    }

    func testContinuousExplicitEnumerationOverridesStaleDeclaredCount() {
        let expectation = infer(
            "这次有三点：第一，确认需求。第二，明确负责人。第三，确定排期。第四，完成回归测试。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 4)
        XCTAssertEqual(expectation.minimumListItemCount, 4)
    }

    func testPartialExplicitEnumerationDoesNotOverrideDeclaredExactCount() {
        let expectation = infer(
            "这次有三点：第一，确认需求。第二，明确负责人。最后，完成回归测试。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 3)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
    }

    func testPartialExplicitEnumerationFollowedByUnnumberedItemUsesMinimum() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。另外还要完成测试。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
    }

    func testOrdinaryAdditionalTopicDoesNotInventTrailingListItem() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。另外一个话题是团队氛围。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 2)
        XCTAssertEqual(expectation.minimumListItemCount, 2)
    }

    func testFinalDeclaredCorrectionOverridesEarlierContinuousEnumeration() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。第三，完成测试。不对，最后改成两项：只确认需求和完成测试。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 2)
        XCTAssertEqual(expectation.minimumListItemCount, 2)
    }

    func testIncrementalAdditionalItemCancelsUnsafeExactCount() {
        let expectation = infer(
            "这次主要有三点：确认需求、明确负责人、完成测试，另外还有一项需要确认上线时间。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 4)
    }

    func testChineseImplicitStepsProduceNumberedListWithoutInventingExactCount() {
        let samples = [
            "先确认需求，然后安排开发，最后完成回归测试。",
            "先确认需求，然后安排开发，接着完成回归测试。",
            "我们先确认需求，然后安排开发，最后完成回归测试。",
            "先确认需求，再安排开发，然后完成回归测试。",
            "Start by confirming scope, then assign owners, next run regression tests.",
        ]

        for sample in samples {
            let expectation = infer(sample, scene: .document)
            XCTAssertEqual(expectation.kind, .numberedList, sample)
            XCTAssertNil(expectation.expectedListItemCount, sample)
            XCTAssertEqual(expectation.minimumListItemCount, 3, sample)
            XCTAssertEqual(expectation.numberingPreference, .arabic, sample)
        }
    }

    func testMediumUnpunctuatedTopicSwitchRequestsNaturalParagraphs() {
        let expectation = infer(
            "我今天想跟团队同步一下项目进度目前核心功能已经开发完成但是测试还没跑完另外预算还需要再确认明天下午我们开会讨论上线时间",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertEqual(expectation.minimumParagraphCount, 2)
    }

    func testMediumBareAdditionalModifierDoesNotForceParagraphs() {
        let samples = [
            "请把另外三个文件也一起发给我，文件名保持不变，压缩后放到共享目录，完成后把下载链接发到工作群里，谢谢。",
            "这项服务需要另外收费，具体价格会在确认需求之后给出，请先把公司名称和联系人信息发给我。",
            "请再提供另外一种写法，保持原来的事实和语气，只需要调整几个词，让整句话读起来更自然一些。",
            "请把另外一个文件也一起发给我，文件名保持不变，压缩后放到共享目录，完成后把下载链接发到工作群里，谢谢。",
            "这次订单里另外一件商品需要单独包装，请保持原来的收货地址，并在发货以后把物流单号发给我。",
            "合同里另外一点费用需要重新核对，请先确认计费周期和服务范围，然后把更新后的报价发给客户。",
            "请把另外一个问题的答案也补充到同一份报告中，保持原有章节顺序和所有引用内容不变，完成后直接发给客户确认。",
        ]

        for sample in samples {
            XCTAssertEqual(infer(sample, scene: .workChat).kind, .sentence, sample)
        }
    }

    func testCodeSceneDoesNotInferAutomaticParagraphsFromTopicWords() {
        let source = "let message = \"另外预算还需要确认\"; // 接下来仍按原来的函数结构处理，变量名称和字符串内容都不能改变。"
        XCTAssertEqual(infer(source, scene: .code).kind, .sentence)
    }

    func testNegatedCancelledOrQuotedIncrementDoesNotIncreaseListMinimum() {
        let samples = [
            "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。不要再补充一个事情，三项就够了。",
            "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。本来想再补充一个事情，但算了。",
            "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。示例里可以说“再补充一个事情”。",
            "今天有三件事。第一，确认需求。第二，安排开发。第三，完成验收。另外还要完成测试，但算了。",
            "今天有三件事。第一，确认需求。第二，安排开发。第三，完成验收。再补充一项：发布。算了，这项不用了。",
        ]

        for sample in samples {
            let expectation = infer(sample, scene: .workChat)
            XCTAssertEqual(expectation.kind, .numberedList, sample)
            XCTAssertEqual(expectation.minimumListItemCount, 3, sample)
        }
    }

    func testAffirmativeIncrementKeepsNegativeFactInsideNewItem() {
        let samples = [
            "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。哦，再补充一个事情，就是预算还没有确认。",
            "今天有三件事。第一，确认需求。第二，安排开发。第三，完成测试。虽然没有新增预算，另外还有一项需要确认，就是通知团队。",
            "今天有三件事。第一，确认需求。第二，安排开发。第三，完成测试。再补充一项：取消周五会议。",
            "今天有三件事。第一，确认需求。第二，安排开发。第三，完成测试。再补充一项：删掉过期文件。",
        ]

        for sample in samples {
            let expectation = infer(sample, scene: .workChat)
            XCTAssertEqual(expectation.kind, .numberedList, sample)
            XCTAssertEqual(expectation.minimumListItemCount, 4, sample)
        }
    }

    func testChineseUserOneTwoThreePreferenceControlsNumberingStyle() {
        let expectation = infer(
            "需要确认需求、安排开发、完成回归测试。",
            requirements: "请根据内容用一二三编号排版。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
        XCTAssertEqual(expectation.numberingPreference, .chinese)
    }

    func testGenericNumberingPreferencePreservesChineseSourceNumbering() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。第三，完成回归测试。",
            requirements: "按内容编号排版，保留原来的结构。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.numberingPreference, .chinese)
    }

    func testLastExplicitNumberingStyleWinsInLongPrompt() {
        let expectation = infer(
            "需要确认需求、安排开发、完成回归测试。",
            requirements: "可以用一二三呈现；经过检查后，最终统一使用 1. 2. 3. 格式。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.numberingPreference, .arabic)
    }

    func testChineseNoListPreferenceOverridesEnumeration() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。第三，完成测试。",
            requirements: "自然表达，不要列点，也不要随便使用列表。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
        XCTAssertTrue(expectation.forbidsLists)
        XCTAssertTrue(expectation.forbidsNumberedList)
        XCTAssertTrue(expectation.forbidsBulletList)
        XCTAssertFalse(expectation.forbidsLineBreaks)
    }

    func testNoListBanIsNotOverriddenByLaterErrorExample() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。第三，完成测试。",
            requirements: "不要列表。错误示例：一二三排列。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertTrue(expectation.forbidsLists)
        XCTAssertTrue(expectation.forbidsNumberedList)
        XCTAssertTrue(expectation.forbidsBulletList)
    }

    func testNoListBanIsNotOverriddenByQuotedCommand() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。第三，完成测试。",
            requirements: "不要列表。“请用一二三编号”只是引用内容。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertTrue(expectation.forbidsLists)
    }

    func testNoListBanIsNotOverriddenByASCIISingleQuotedCommand() {
        let expectation = infer(
            "第一，确认需求。第二，安排开发。第三，完成测试。",
            requirements: "不要列表。改成 '请用一二三编号' 是字段值，不是新指令。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertTrue(expectation.forbidsLists)
        XCTAssertTrue(expectation.forbidsNumberedList)
        XCTAssertTrue(expectation.forbidsBulletList)
    }

    func testNoParagraphBanIsNotOverriddenByBacktickedCommand() {
        let expectation = infer(
            "项目背景已经明确。当前主要问题是响应偏慢。团队明天讨论验收方式。",
            requirements: "不要分段。改成 `请自然分段` 是字段值，不是新指令。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertTrue(expectation.forbidsLineBreaks)
    }

    func testNoParagraphBanIsNotOverriddenByLaterErrorExample() {
        let expectation = infer(
            "项目背景已经明确。当前主要问题是响应偏慢。团队明天讨论验收方式。",
            requirements: "不要分段。错误示例：自然分段。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertTrue(expectation.forbidsLineBreaks)
    }

    func testExplicitCommandAfterNoListBanCanOverrideIt() {
        let expectation = infer(
            "需要确认需求、安排开发、完成回归测试。",
            requirements: "不要列表。最后请改成一二三编号。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertFalse(expectation.forbidsLists)
        XCTAssertFalse(expectation.forbidsNumberedList)
        XCTAssertTrue(expectation.forbidsBulletList)
    }

    func testExplicitCommandAfterNoParagraphBanCanOverrideIt() {
        let expectation = infer(
            "项目背景已经明确。当前主要问题是响应偏慢。团队明天讨论验收方式。",
            requirements: "不要分段。最后请改成自然分段。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertFalse(expectation.forbidsLineBreaks)
    }

    func testNoBulletsStillAllowsRequestedNumberedList() {
        let expectation = infer(
            "需要确认需求、安排开发、完成回归测试。",
            requirements: "不要项目符号，请用1. 2. 3.编号排版。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertFalse(expectation.forbidsLists)
        XCTAssertFalse(expectation.forbidsNumberedList)
        XCTAssertTrue(expectation.forbidsBulletList)
        XCTAssertEqual(expectation.numberingPreference, .arabic)
    }

    func testNoNumberingStillAllowsRequestedBulletList() {
        let expectation = infer(
            "需要确认需求、安排开发、完成回归测试。",
            requirements: "不要数字编号，请用项目符号列表。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .bulletList)
        XCTAssertFalse(expectation.forbidsLists)
        XCTAssertTrue(expectation.forbidsNumberedList)
        XCTAssertFalse(expectation.forbidsBulletList)
        XCTAssertEqual(expectation.numberingPreference, .none)
    }

    func testChineseParagraphPreferenceUsesRequestedMinimum() {
        let expectation = infer(
            "先说明项目背景。接下来讲当前问题。最后给出下一步安排。",
            requirements: "请分成三段，每段只讲一个主题。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertEqual(expectation.minimumParagraphCount, 3)
    }

    func testNoParagraphPreferenceOverridesLongMultiTopicLayout() {
        let source = String(repeating: "先说明项目背景和目前进展。接下来讨论风险和资源安排。", count: 6)
        let expectation = infer(
            source,
            requirements: "合并成一段，不要换行。",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertEqual(expectation.minimumParagraphCount, 1)
        XCTAssertTrue(expectation.forbidsLineBreaks)
        XCTAssertFalse(expectation.forbidsLists)
    }

    func testLongMultiTopicDocumentRequiresParagraphs() {
        let source = """
        关于产品方向，我们先说明这次调整希望解决的核心问题，并补充用户当前最明显的使用感受。
        另外一个问题是现有流程等待时间偏长，需要把关键路径和非关键路径分开处理。
        接下来还要讨论验收方式，确保术语、事实、排版和响应时间都有真实样本验证。
        """ + String(repeating: "这些内容都需要保留原意并整理清楚。", count: 4)
        let expectation = infer(source, scene: .document)

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 3)
    }

    func testDefaultEightyCharacterMultiTopicContentRequiresParagraphs() {
        let source = "先说明项目背景和用户当前的真实反馈，确保团队理解这次调整的原因。"
            + "另外一个问题是识别和润色等待较长，需要把关键路径重新梳理清楚。"
            + "接下来明确验收方式，检查术语与事实是否准确，并检查排版和响应速度。"
        let expectation = infer(source, scene: .document)

        XCTAssertGreaterThanOrEqual(source.filter { !$0.isWhitespace }.count, 80)
        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
    }

    func testLongUnpunctuatedContentUsesAutomaticParagraphContract() {
        let source = String(
            repeating: "这是一段连续说明并且没有可验证的主题切换或句子边界",
            count: 4
        )
        let expectation = infer(source, scene: .workChat)

        XCTAssertGreaterThanOrEqual(source.filter { !$0.isWhitespace }.count, 80)
        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
    }

    func testRequestedNaturalParagraphsHandleLongUnpunctuatedSingleSegment() {
        let source = String(
            repeating: "我们需要梳理产品背景用户反馈当前问题处理思路资源安排以及后续验收方式",
            count: 3
        )
        let expectation = infer(
            source,
            requirements: "请按语义自然分段。",
            scene: .workChat,
            segments: [source]
        )

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
    }

    func testAIPromptFutureOutputCountDoesNotCreateCurrentListContract() {
        let expectation = infer(
            "帮我分析这个功能为什么慢，再给三个优化建议。",
            scene: .aiPrompt
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testAIPromptCorrectedFutureOutputCountStillDoesNotCreateCurrentListContract() {
        let expectation = infer(
            "帮我分析这个功能为什么慢，给三个优化建议，不对，最后改成两个建议。",
            scene: .aiPrompt
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testAIPromptStillRecognizesItemsAlreadyEnumeratedInBody() {
        let expectation = infer(
            "第一，分析这个功能为什么慢。第二，给出三个优化建议。",
            scene: .aiPrompt
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 2)
        XCTAssertEqual(expectation.minimumListItemCount, 2)
    }

    func testEnglishExplicitEnumerationUsesArabicNumbering() {
        let expectation = infer(
            "First, confirm the scope. Second, assign an owner. Third, run the regression tests.",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.expectedListItemCount, 3)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
        XCTAssertEqual(expectation.numberingPreference, .arabic)
    }

    func testEnglishNarrativeFirstAndFinallyDoNotBecomeEnumeration() {
        let expectation = infer(
            "My first job taught me a lot about product work. Years later I finally moved to a new team.",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .sentence)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testEnglishBulletPreferenceRecognizesParallelItems() {
        let expectation = infer(
            "We need to confirm the scope; assign an owner; run the regression tests.",
            requirements: "Format the result as a bulleted list.",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .bulletList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
        XCTAssertEqual(expectation.numberingPreference, .none)
    }

    func testSafeChineseHeadingAndCommaParallelItemsHonorNumberedPreference() {
        let expectation = infer(
            "这次主要有几个问题：识别慢，不会分段，提示词没执行。",
            requirements: "多个事项自动用 1. 2. 3. 排列。",
            scene: .workChat
        )

        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
        XCTAssertEqual(expectation.numberingPreference, .arabic)
    }

    func testEnglishNoBulletsAllowsNaturalParagraphsForLongContent() {
        let source = Array(repeating: [
            "Regarding the product direction, explain the user problem and the current impact.",
            "In addition, describe the latency issue and the proposed response strategy.",
            "Moving on, define how terminology, facts, layout, and speed will be validated.",
        ], count: 2).flatMap { $0 }.joined(separator: " ")
        let expectation = infer(
            source,
            requirements: "Use natural paragraphs and no bullets.",
            scene: .document
        )

        XCTAssertEqual(expectation.kind, .paragraphs)
        XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
        XCTAssertNil(expectation.minimumListItemCount)
    }

    func testLongDocumentLayoutDoesNotDependOnProviderSegmentCount() {
        let source = """
        这次复盘先交代背景。最近两周用户反馈主要集中在等待时间、术语识别和长文完整性，我们需要分别核对原因，不能因为其中某一项容易修就忽略其他问题。

        中间有一个局部检查清单，只有三项：确认日志、核对模型版本、记录发生时间。这个清单只是排查过程的一部分，不代表整篇复盘都要改成列表。

        接下来还要说明处理方案。短期先修复原文回退和错误校验，长期再补真实语料回归，并且每次发布前都要由独立验收确认结果。

        最后保留结论和下一步安排。负责人需要根据失败样本逐条复查，确认事实、语气和段落都完整，再决定是否发布。
        """
        let segmentVariants = [
            [source],
            source.components(separatedBy: "\n\n"),
            source.split(separator: "，").map(String.init),
        ]

        let expectations = segmentVariants.map {
            infer(source, scene: .document, segments: $0)
        }

        for expectation in expectations {
            XCTAssertEqual(expectation.kind, .paragraphs)
            XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
            XCTAssertNil(expectation.minimumListItemCount)
        }
        XCTAssertEqual(Set(expectations.map(\.kind)).count, 1)
        XCTAssertEqual(Set(expectations.map(\.minimumParagraphCount)).count, 1)
    }

    func testMediumTwoSentenceDocumentWithLocalChecklistIgnoresProviderSegments() {
        let first = "这次复盘先说明最近用户反馈的背景和影响，中间的排查清单只有三项：确认日志、核对模型版本、记录发生时间。"
        let second = "随后还要单独说明修复方案、发布条件和负责人安排，不能把整篇复盘误排成三条清单。"
        let source = first + second
        XCTAssertGreaterThanOrEqual(source.filter { !$0.isWhitespace }.count, 80)
        XCTAssertLessThan(source.filter { !$0.isWhitespace }.count, 180)

        let expectations = [
            infer(source, scene: .document, segments: [source]),
            infer(source, scene: .document, segments: [first, second]),
        ]

        for expectation in expectations {
            XCTAssertEqual(expectation.kind, .paragraphs)
            XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
            XCTAssertNil(expectation.minimumListItemCount)
        }
        XCTAssertEqual(expectations[0], expectations[1])
    }

    func testLocalExplicitChapterListDoesNotTurnLongNarrativeIntoWholeDocumentList() {
        let localChapters = [
            "第一部分讲账号与环境。",
            "第二部分讲如何提出好问题。",
            "第三部分讲资料研究。",
            "第四部分讲语音输入。",
            "第五部分讲内容生产。",
            "第六部分讲表格和文档。",
            "第七部分讲知识库。",
            "第八部分讲自动化和 Agent。",
        ].joined()
        let background = Array(
            repeating: "课程还需要说明真实截图、隐私边界、作业验收、素材授权、版本更新和售后范围，每一项都要保留原始事实并让普通学员能够复现。",
            count: 14
        ).joined(separator: "\n\n")
        let source = "这是完整课程计划的背景和目标。\n\n\(localChapters)\n\n\(background)"

        for segments in [[source], source.components(separatedBy: "\n\n")] {
            let expectation = infer(source, scene: .document, segments: segments)
            XCTAssertEqual(expectation.kind, .paragraphs)
            XCTAssertGreaterThanOrEqual(expectation.minimumParagraphCount, 2)
            XCTAssertNil(expectation.minimumListItemCount)
        }
    }

    private func infer(
        _ text: String,
        requirements: String = "",
        scene: WritingScene,
        segments: [String]? = nil
    ) -> VoicePolishLayoutExpectation {
        let segmentTexts = segments ?? [text]
        let recognitionSegments = segmentTexts.enumerated().map { index, segmentText in
            RecognitionSegment(
                id: "s\(index + 1)",
                text: segmentText,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )
        }
        let request = VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: recognitionSegments,
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(
                scene: scene,
                level: .metadataOnly,
                safety: .unknown
            ),
            preferences: UserPolishPreferences(additionalRequirements: requirements),
            qualityMode: .balanced
        )
        return VoicePolishLayoutExpectation.infer(from: request)
    }
}
