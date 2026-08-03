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

    func testBlobAndWrongPlanTriggerRepairThenArabicNumberedListSucceeds() async throws {
        let request = makeRequest(
            "First, confirm scope. Second, assign owners. Third, run regression tests.",
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
            "先确认需求，然后安排开发，最后完成测试。",
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
            "先说明项目背景。接下来解释当前问题。最后给出下一步安排。",
            requirements: "请分成三段，每段只讲一个主题。",
            scene: .document,
            segments: [
                "先说明项目背景。",
                "接下来解释当前问题。",
                "最后给出下一步安排。",
            ]
        )
        let blob = response(
            for: request,
            finalText: "先说明项目背景，接着解释当前问题，最后给出下一步安排。",
            kind: .paragraphs,
            expectedListCount: nil
        )
        let paragraphText = """
        先说明项目背景。

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
        let valid = response(
            for: request,
            finalText: finalText,
            kind: .numberedList,
            expectedListCount: 3
        )
        let client = LayoutPipelineScriptedLLM(responses: [try encoded(valid)])

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
        let valid = response(
            for: request,
            finalText: finalText,
            kind: .numberedList,
            expectedListCount: 3
        )
        let client = LayoutPipelineScriptedLLM(responses: [try encoded(valid)])

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
            "这次有三点：第一，确认需求。第二，安排开发。第三，完成测试。",
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

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.validationCodes.contains(.layoutRequirementUnmet))
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
