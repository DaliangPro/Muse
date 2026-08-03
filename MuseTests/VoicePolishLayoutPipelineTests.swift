import XCTest
@testable import Muse

final class VoicePolishLayoutPipelineTests: XCTestCase {
    private let config = LLMConfig(
        apiKey: "test",
        model: "mock-model",
        baseURL: "https://example.com/v1"
    )

    func testThreeSpokenItemsKeepFastPathWithLocalLayoutContract() {
        let request = makeRequest(
            "需要做三件事：确认需求、安排开发、完成回归测试。",
            scene: .workChat
        )

        let decision = VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: ProtectedFactExtractor.extract(from: request.input.segments)
        )

        XCTAssertEqual(VoicePolishLayoutExpectation.infer(from: request).kind, .numberedList)
        XCTAssertEqual(decision.route, .fast)
        XCTAssertTrue(decision.matchedSignalCategories.contains("layout_contract"))
    }

    func testProviderSegmentsAndParagraphPreferenceStillUseOneFastRequest() async {
        let source = "今天确认需求。明天安排开发。周五完成回归测试。"
        let request = makeRequest(
            source,
            requirements: "请按语义自然分段。",
            scene: .workChat,
            segments: [
                "今天确认需求。",
                "明天安排开发。",
                "周五完成回归测试。",
            ]
        )
        let output = """
        今天确认需求。

        明天安排开发。

        周五完成回归测试。
        """
        let client = LayoutPipelineScriptedLLM(responses: [output])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, output)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.task), [.voicePolishFast])
    }

    func testAIPromptFutureOutputCountDoesNotForceCurrentDraftIntoAList() async {
        let request = makeRequest(
            "帮我分析这个功能为什么慢，再给三个优化建议。",
            scene: .aiPrompt
        )
        let output = "分析这个功能变慢的原因，并给出 3 条优化建议。"
        let client = LayoutPipelineScriptedLLM(responses: [output])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(VoicePolishLayoutExpectation.infer(from: request).kind, .sentence)
        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, output)
    }

    func testMediumTopicSwitchUsesFastRequestAndLocallyCreatesParagraphs() async {
        let request = makeRequest(
            "我今天想跟团队同步一下项目进度目前核心功能已经开发完成但是测试还没跑完另外预算还需要再确认明天下午我们开会讨论上线时间",
            scene: .workChat
        )
        let client = LayoutPipelineScriptedLLM(responses: [
            "我今天想跟团队同步一下项目进度：核心功能已经开发完成，但测试还没跑完；另外预算还需要再确认。明天下午我们开会讨论上线时间。",
        ])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(VoicePolishLayoutExpectation.infer(from: request).kind, .paragraphs)
        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            "我今天想跟团队同步一下项目进度：核心功能已经开发完成，但测试还没跑完；另外预算还需要再确认。\n\n明天下午我们开会讨论上线时间。"
        )
    }

    func testLiveFourItemSampleUsesOneFastRequestAndKeepsTrailingAddition() async {
        let source = "今天我有三件事要做。第一个是我要给自己买一个沙发套。第二个是我希望 把我下一周的稿子都集中写完，至少也要把选题写完。第三个就是就是 就是把快递都拿了。哦，再补充一个事吧，就是 给自己选一身适合健身穿的衣服。"
        let request = makeRequest(source, scene: .workChat)
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertEqual(expectation.minimumListItemCount, 4)
        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            今天我有四件事要做。

            一、我要给自己买一个沙发套。
            二、我希望把我下一周的稿子都集中写完，至少也要把选题写完。
            三、就是就是把快递都拿了。
            四、哦，再补充一个事吧，就是给自己选一身适合健身穿的衣服。
            """
        )
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.task), [.voicePolishFast])
    }

    func testParallelThreeItemsPlusTrailingAdditionStayOneFastRequest() async {
        let source = "今天有三项：确认需求、安排开发、完成测试。再补充一项：通知团队。"
        let request = makeRequest(source, scene: .workChat)
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            今天有四项：

            1. 确认需求、
            2. 安排开发、
            3. 完成测试。
            4. 再补充一项：通知团队。
            """
        )
    }

    func testEquivalentTrailingAdditionPhraseUsesOneFastRequestAndUpdatesTotal() async {
        let source = "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。额外增加一项，就是通知团队。"
        let request = makeRequest(source, scene: .workChat)
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            今天有四件事。

            一、确认需求。
            二、安排开发。
            三、完成测试。
            四、额外增加一项，就是通知团队。
            """
        )
    }

    func testLiveFourItemSampleFallbackStillSynchronizesDeclaredCount() async {
        let source = "今天我有三件事要做。第一个是确认需求。第二个是安排开发。第三个就是完成测试。哦，再补充一个事吧，就是通知团队。"
        let request = makeRequest(source, scene: .workChat)
        let client = LayoutPipelineScriptedLLM(responses: [])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            今天我有四件事要做。

            一、确认需求。
            二、安排开发。
            三、完成测试。
            四、哦，再补充一个事吧，就是通知团队。
            """
        )
    }

    func testBulletFallbackSynchronizesDeclaredCountFromCanonicalProof() async {
        let source = "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。此外还有一项：通知团队。"
        let request = makeRequest(
            source,
            requirements: "请使用项目符号列表。",
            scene: .workChat
        )
        let client = LayoutPipelineScriptedLLM(responses: [])

        let result = await pipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            今天有四件事。

            - 确认需求。
            - 安排开发。
            - 完成测试。
            - 此外还有一项：通知团队。
            """
        )
    }

    func testModelHallucinatedFourthItemCannotTriggerCountSynchronization() async {
        let source = "今天有三件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。"
        let request = makeRequest(source, scene: .workChat)
        let hallucinated = """
        今天有三件事。

        一、确认需求。
        二、安排开发。
        三、完成测试。
        四、哦，再补充一个事吧，就是发布上线。
        """
        let client = LayoutPipelineScriptedLLM(responses: [hallucinated])

        let result = await pipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.layoutRequirementUnmet))
        XCTAssertFalse(result.text.contains("四件事"))
        XCTAssertFalse(result.text.contains("发布上线"))
    }

    func testBulletCountMismatchWithQuotedCommandAndFooterIsRejected() async {
        let source = "这里有三项：第一，保留引用“例如”的原话。第二，执行命令 `git status`。第三，完成发布。"
        let request = makeRequest(
            source,
            requirements: "请使用项目符号列表。",
            scene: .workChat
        )
        let inconsistent = """
        这里有两项：
        - 保留引用“例如”的原话。
        - 执行命令 `git status`。
        - 完成发布。

        以上是普通收束段落。
        """
        let client = LayoutPipelineScriptedLLM(responses: [inconsistent])

        let result = await pipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.layoutRequirementUnmet))
    }

    func testDeclaredCountMismatchIsRejectedAndFallsBackToConsistentList() async {
        let source = "今天有四件事。第一个是确认需求。第二个是安排开发。第三个是完成测试。第四个是通知团队。"
        let request = makeRequest(source, scene: .workChat)
        let inconsistentOutput = """
        今天有三件事。

        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        4. 通知团队。
        """
        let client = LayoutPipelineScriptedLLM(responses: [inconsistentOutput])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.layoutRequirementUnmet))
        XCTAssertEqual(
            result.text,
            """
            今天有四件事。

            一、确认需求。
            二、安排开发。
            三、完成测试。
            四、通知团队。
            """
        )
    }

    func testImplicitStepsUseOneFastRequestAndLocalListLayout() async {
        let cases = [
            (
                "先确认需求，然后安排开发，最后完成回归测试。",
                "1. 先确认需求，\n2. 然后安排开发，\n3. 最后完成回归测试。"
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
            let request = makeRequest(source, scene: .workChat)
            let client = LayoutPipelineScriptedLLM(responses: [source])
            let result = await pipeline(client).process(request)

            XCTAssertEqual(result.detectedRoute, .fast, source)
            XCTAssertEqual(result.executedRoute, .fast, source)
            XCTAssertEqual(result.llmAttemptCount, 1, source)
            XCTAssertFalse(result.usedFallback, source)
            XCTAssertEqual(result.text, expected, source)
        }
    }

    func testFormalChineseStepLeadInStillUsesOneFastRequest() async {
        let source = "我们首先确认需求，其次安排开发，最后完成测试。"
        let request = makeRequest(source, scene: .workChat)
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.detectedRoute, .fast)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            "一、我们首先确认需求，\n二、其次安排开发，\n三、最后完成测试。"
        )
    }

    func testBlobAndWrongPlanTriggerRepairThenArabicNumberedListSucceeds() async throws {
        let request = makeRequest(
            "Side note. First, confirm scope. Second, assign owners. Third, run regression tests.",
            requirements: "Use a numbered list.",
            scene: .workChat
        )
        let invalid = response(
            for: request,
            finalText: "Confirm scope, assign owners, and run regression tests.",
            kind: .sentence,
            expectedListCount: nil
        )
        let repairedText = """
        1. Confirm scope.
        2. Assign owners.
        3. Run regression tests.
        """
        let repaired = response(
            for: request,
            finalText: repairedText,
            kind: .numberedList,
            expectedListCount: 3
        )
        let client = LayoutPipelineScriptedLLM(responses: [
            try encoded(invalid),
            try encoded(repaired),
        ])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.detectedRoute, .structured)
        XCTAssertEqual(result.executedRoute, .structured)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repairedText)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.task), [.voicePolishStructured, .voicePolishRepair])
        XCTAssertTrue(requests[1].user.contains(VoicePolishValidationCode.layoutRequirementUnmet.rawValue))
    }

    func testStructuredMinimumOnlyContractDoesNotAdoptModelGuessedExactCount() async throws {
        let request = makeRequest(
            "顺便说一下，先确认需求，然后安排开发，最后完成测试。",
            scene: .workChat
        )
        let finalText = """
        1. 确认需求。
        2. 安排开发。
        3. 完成测试。
        """
        let guessedFive = response(
            for: request,
            finalText: finalText,
            kind: .numberedList,
            expectedListCount: 5
        )
        let client = LayoutPipelineScriptedLLM(responses: [try encoded(guessedFive)])

        let result = await pipeline(client).process(request)

        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(expectation.minimumListItemCount, 3)
        XCTAssertEqual(result.executedRoute, .structured)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, finalText)
    }

    func testThreeParagraphPreferenceRejectsBlobAndAcceptsThreeParagraphs() async throws {
        let request = makeRequest(
            "顺便说一下，先说明项目背景。接下来解释当前问题。最后给出下一步安排。",
            requirements: "请分成三段，每段只讲一个主题。",
            scene: .document,
            segments: [
                "顺便说一下，先说明项目背景。",
                "接下来解释当前问题。",
                "最后给出下一步安排。",
            ]
        )
        let blob = response(
            for: request,
            finalText: "顺便说一下，先说明项目背景，接着解释当前问题，最后给出下一步安排。",
            kind: .paragraphs,
            expectedListCount: nil
        )
        let paragraphText = """
        顺便说一下，先说明项目背景。

        接下来解释当前问题。

        最后给出下一步安排。
        """
        let repaired = response(
            for: request,
            finalText: paragraphText,
            kind: .paragraphs,
            expectedListCount: nil
        )
        let client = LayoutPipelineScriptedLLM(responses: [
            try encoded(blob),
            try encoded(repaired),
        ])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(VoicePolishLayoutExpectation.infer(from: request).minimumParagraphCount, 3)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, paragraphText)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.task), [.voicePolishStructured, .voicePolishRepair])
        guard requests.count > 1 else {
            XCTFail("缺少预期的排版修复请求")
            return
        }
        XCTAssertTrue(requests[1].user.contains(VoicePolishValidationCode.layoutRequirementUnmet.rawValue))
    }

    func testPayloadCarriesLayoutExpectationAndNonemptyUserPreferencesTogether() async throws {
        let requirements = "Use a numbered list and keep the wording concise."
        let request = makeRequest(
            "First, confirm scope. Second, assign owners. Third, run regression tests.",
            requirements: requirements,
            scene: .workChat
        )
        let finalText = """
        1. Confirm scope.
        2. Assign owners.
        3. Run regression tests.
        """
        let client = LayoutPipelineScriptedLLM(responses: [finalText])

        let result = await pipeline(client).process(request)
        let requests = await client.recordedRequests()
        let payload = try XCTUnwrap(jsonObject(requests[0].user))
        let layout = try XCTUnwrap(payload["layout_expectation"] as? [String: Any])

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(payload["user_preferences"] as? String, requirements)
        XCTAssertEqual(layout["kind"] as? String, OutputKind.numberedList.rawValue)
        XCTAssertEqual(layout["minimum_list_item_count"] as? Int, 3)
        XCTAssertEqual(layout["numbering_preference"] as? String, VoicePolishNumberingPreference.arabic.rawValue)
    }

    func testExplicitChineseOneTwoThreePreferenceAcceptsChineseNumbering() async throws {
        let request = makeRequest(
            "第一，确认需求。第二，安排开发。第三，完成回归测试。",
            requirements: "请按一二三使用中文编号。",
            scene: .workChat
        )
        let finalText = """
        一、确认需求。
        二、安排开发。
        三、完成回归测试。
        """
        let client = LayoutPipelineScriptedLLM(responses: [finalText])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(
            VoicePolishLayoutExpectation.infer(from: request).numberingPreference,
            .chinese
        )
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, finalText)
        XCTAssertTrue(
            VoicePolishNumbering.matchesNumberingPreference(
                in: result.text,
                preference: .chinese
            )
        )
    }

    func testWrongFastModelLayoutIsLocallyFormattedWithoutRepairOrFallback() async {
        let request = makeRequest(
            "这次有三点：识别慢；不会分段；提示词没有执行。",
            scene: .workChat,
            segments: [
                "这次有三点：识别慢；",
                "不会分段；",
                "提示词没有执行。",
            ]
        )
        let client = LayoutPipelineScriptedLLM(responses: [
            "这次有三点：识别慢，不会分段，提示词没有执行。",
        ])

        let result = await pipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertNil(result.failureReason)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.validationCodes.contains(.layoutRequirementUnmet))
        XCTAssertEqual(
            result.text,
            """
            这次有三点：

            1. 识别慢，
            2. 不会分段，
            3. 提示词没有执行。
            """
        )
    }

    func testStructuredBlobIsLocallyFormattedWithoutRepair() async throws {
        let request = makeRequest(
            "这次有三点：第一，确认需求。第二，安排开发。第三，完成测试。顺便说一下。",
            scene: .workChat
        )
        let blob = "这次有三点：确认需求，安排开发，完成测试。"
        let first = response(
            for: request,
            finalText: blob,
            kind: .sentence,
            expectedListCount: nil
        )
        let client = LayoutPipelineScriptedLLM(responses: [try encoded(first)])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .structured)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            这次有三点：

            一、确认需求，
            二、安排开发，
            三、完成测试。
            """
        )
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.task), [.voicePolishStructured])
    }

    func testDeepRendererBlobIsLocallyFormattedWithoutRepair() async throws {
        let request = makeRequest(
            "这次有三点：第一，确认需求。第二，先安排开发。第三，完成测试。前面那句改成第二，明天安排开发。",
            scene: .workChat
        )
        let blob = "这次有三点：确认需求，明天安排开发，完成测试。"
        let draft = response(
            for: request,
            finalText: blob,
            kind: .sentence,
            expectedListCount: nil
        )
        let client = LayoutPipelineScriptedLLM(responses: [
            try encoded(draft.plan),
            blob,
        ])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .deep)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            这次有三点：

            一、确认需求，
            二、明天安排开发，
            三、完成测试。
            """
        )
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.task), [.voicePolishAnalyze, .voicePolishRender])
    }

    func testUnsafeLocalSplitFallsBackWithoutChangingShellText() async {
        let source = "步骤包括：for i in a; do echo \"$i\"; done"
        let request = makeRequest(
            source,
            requirements: "请使用数字列表。",
            scene: .workChat
        )
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .structured)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.validationCodes.contains(.invalidStructuredResponse))
    }

    func testNewNumericFactAfterSafeFormattingIsRejectedAndCanonicalFallbackIsFormatted() async {
        let source = "这次有三点：识别慢，不会分段，提示词没有执行。"
        let request = makeRequest(
            source,
            requirements: "多个事项自动用 1. 2. 3. 排列。",
            scene: .workChat
        )
        let client = LayoutPipelineScriptedLLM(responses: [
            "这次有三点：识别慢，不会分段，提示词没有执行，另外预算 4.98 万元。",
        ])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.planIntegrityFailure))
        XCTAssertEqual(
            result.text,
            """
            这次有三点：

            1. 识别慢，
            2. 不会分段，
            3. 提示词没有执行。
            """
        )
    }

    func testMinimumOnlyChineseParallelContentIsLocallyNumberedInOneCall() async {
        let source = "这次主要有几个问题：识别慢，不会分段，提示词没执行。"
        let request = makeRequest(
            source,
            requirements: "多个事项自动用 1. 2. 3. 排列。",
            scene: .workChat
        )
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        XCTAssertEqual(expectation.kind, .numberedList)
        XCTAssertNil(expectation.expectedListItemCount)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(
            result.text,
            """
            这次主要有几个问题：

            1. 识别慢，
            2. 不会分段，
            3. 提示词没执行。
            """
        )
    }

    func testCodeFailureFallbackPreservesEveryCharacter() async {
        let source = "1) echo one ;;\n    2) echo two ;;"
        let request = makeRequest(source, scene: .code)
        let client = LayoutPipelineScriptedLLM(responses: [])

        let result = await pipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.text, source)
    }

    func testFastPathLocallyRemovesForbiddenListAndLineBreaks() async {
        let request = makeRequest(
            "先说明背景，然后解释问题。",
            requirements: "不要分段，不要列表，合并成一段。",
            scene: .workChat
        )
        let client = LayoutPipelineScriptedLLM(responses: [
            "1. 说明背景\n2. 解释问题",
        ])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "说明背景 解释问题")
        XCTAssertFalse(result.text.contains("\n"))
        XCTAssertEqual(VoicePolishNumbering.recognizedListItemCount(in: result.text), 0)
    }

    func testDefaultSentenceContractDoesNotBlockUsefulModelParagraphs() async {
        let request = makeRequest(
            "先说明项目背景。接下来解释当前问题。",
            scene: .workChat
        )
        let output = "先说明项目背景。\n\n接下来解释当前问题。"
        let client = LayoutPipelineScriptedLLM(responses: [output])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(VoicePolishLayoutExpectation.infer(from: request).kind, .sentence)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, output)
    }

    func testCodeSceneNeverRewritesShellCaseLabels() async {
        let source = "1) echo one ;;\n2) echo two ;;"
        let request = makeRequest(source, scene: .code)
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
    }

    func testFastTwelveItemListMarkersAreNotTreatedAsNewNumericFacts() async {
        let source = "这次共有12项：需求；设计；开发；测试；文档；培训；发布；监控；复盘；归档；备份；通知。"
        let request = makeRequest(source, scene: .workChat)
        let output = """
        这次共有12项：

        1. 需求
        2. 设计
        3. 开发
        4. 测试
        5. 文档
        6. 培训
        7. 发布
        8. 监控
        9. 复盘
        10. 归档
        11. 备份
        12. 通知。
        """
        let client = LayoutPipelineScriptedLLM(responses: [output])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(VoicePolishLayoutExpectation.infer(from: request).expectedListItemCount, 12)
        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, output)
        XCTAssertFalse(result.validationCodes.contains(.planIntegrityFailure))
    }

    func testTwelveItemSourceListMarkersAcrossSegmentsAreNotProtectedFacts() async {
        let items = [
            "需求", "设计", "开发", "测试", "文档", "培训",
            "发布", "监控", "复盘", "归档", "备份", "通知",
        ]
        let lines = items.enumerated().map { "\($0.offset + 1). \($0.element)" }
        let source = (["这次共有12项："] + lines).joined(separator: "\n")
        let request = makeRequest(
            source,
            scene: .workChat,
            segments: ["这次共有12项："] + lines
        )
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertFalse(result.validationCodes.contains(.missingProtectedFact))
        XCTAssertFalse(result.validationCodes.contains(.planIntegrityFailure))
    }

    func testUserReportedASRPunctuationIsRepairedWhenFastModelCopiesInput() async {
        let source = """
        如果是一段特别长的内容，它的 时间优化过程也会是这样的。因为。

        我看它提示这有多少秒，那有多少秒的，这一共好像花了很长时间。

        但是，Typeless 好像就没有这样的这个提示，同时它也。

        并没有花这么长时间。

        你看，我这段话就是用你的润色模式输入的。可是由于我的 ASR 识别标点符号不准，你的润色模式也不会针对这个句子重新优化标点，只是原样放上去，原样断句。
        """
        let request = makeRequest(source, scene: .workChat)
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertFalse(result.text.contains("它的 时间"))
        XCTAssertFalse(result.text.contains("因为。"))
        XCTAssertFalse(result.text.contains("同时它也。"))
        XCTAssertTrue(result.text.contains("因为我看"))
        XCTAssertTrue(result.text.contains("同时它也并没有"))
        XCTAssertEqual(
            VoicePolishPunctuationRepair.issues(in: result.text),
            []
        )

        let recorded = await client.recordedRequests()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].user.contains("punctuation_issues"))
        XCTAssertTrue(recorded[0].user.contains("cjk_inner_space"))
        XCTAssertTrue(recorded[0].user.contains("dangling_connector"))
        XCTAssertTrue(recorded[0].user.contains("broken_predicate_boundary"))
    }

    func testPunctuationRepairKeepsQuotedAndInlineCodeExamplesUntouched() {
        let source = """
        他说“因为。”，并要求保留 `同时它也。并没有`。正文结束。因为。

        下一句继续说明。
        """

        let result = VoicePolishPunctuationRepair.normalize(source)

        XCTAssertTrue(result.contains("“因为。”"))
        XCTAssertTrue(result.contains("`同时它也。并没有`"))
        XCTAssertTrue(result.contains("正文结束。因为下一句继续说明。"))
        XCTAssertEqual(
            VoicePolishPunctuationRepair.normalize("这是原话。因为。"),
            "这是原话。因为。"
        )
    }

    func testFallbackStillRepairsProvenBrokenASRPunctuation() async {
        let source = "前面先说明背景。因为。\n\n后面还有原因，而且它也。\n\n并没有结束。"
        let request = makeRequest(source, scene: .workChat)
        let client = LayoutPipelineScriptedLLM(responses: [])

        let result = await pipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.text.contains("因为后面"))
        XCTAssertTrue(result.text.contains("而且它也并没有"))
    }

    func testCodeSceneNeverAppliesNaturalLanguagePunctuationRepair() async {
        let source = "print(\"因为。\")\nlet value = \"同时它也。并没有\""
        let request = makeRequest(source, scene: .code)
        let client = LayoutPipelineScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.text, source)
    }

    private func pipeline(_ client: LayoutPipelineScriptedLLM) -> VoicePolishPipeline {
        VoicePolishPipeline(client: client, config: config)
    }

    private func makeRequest(
        _ text: String,
        requirements: String = "",
        scene: WritingScene,
        segments: [String]? = nil
    ) -> VoicePolishRequest {
        let segmentTexts = segments ?? [text]
        let recognitionSegments = segmentTexts.enumerated().map { index, value in
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
    }

    private func response(
        for request: VoicePolishRequest,
        finalText: String,
        kind: OutputKind,
        expectedListCount: Int?
    ) -> StructuredVoicePolishResponse {
        let sourceFactSegments = VoicePolishNumbering.removingContinuousNumberedLineMarkers(
            from: request.input.segments
        )
        let facts = ProtectedFactExtractor.extract(from: sourceFactSegments).map { candidate in
            ProtectedFact(
                sourceText: candidate.sourceText,
                canonicalValue: candidate.canonicalValue,
                kind: candidate.kind,
                disposition: .mustPreserve,
                exclusionReason: nil,
                sourceSegmentIDs: candidate.sourceSegmentIDs
            )
        }
        return StructuredVoicePolishResponse(
            plan: VoicePolishPlan(
                version: VoicePolishPrompts.version,
                language: request.input.detectedLanguage,
                scene: request.context.scene,
                finalIntent: "按原意整理成稿",
                orderedBlocks: [VoicePolishBlock(
                    id: "b1",
                    text: finalText,
                    sourceSegmentIDs: ["s1"],
                    kind: .content
                )],
                discardedFragments: [],
                corrections: [],
                sideNotes: [],
                facts: facts,
                uncertainEntities: [],
                outputFormat: VoiceOutputFormat(
                    kind: kind,
                    expectedListCount: expectedListCount
                ),
                confidence: 0.95
            ),
            finalText: finalText
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8)!
    }

    private func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private actor LayoutPipelineScriptedLLM: LLMClient {
    private var responses: [String]
    private var requests: [LLMRequest] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw LayoutPipelineMockError.missingResponse }
        return LLMResponse(text: responses.removeFirst(), model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        throw LayoutPipelineMockError.unsupportedProcess
    }

    func warmUp(baseURL: String) async {}

    func recordedRequests() -> [LLMRequest] { requests }
}

private enum LayoutPipelineMockError: Error {
    case missingResponse
    case unsupportedProcess
}
