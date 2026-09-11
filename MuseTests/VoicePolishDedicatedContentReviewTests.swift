import XCTest
@testable import Muse

final class VoicePolishDedicatedContentReviewTests: XCTestCase {
    func testRiskySourceReceivesContentOnlyReviewBeforeLayoutEvenWithoutRepair() async throws {
        let source = "先别发送，等我确认。材料已经备齐。"
        let contentReview = #"{"delivery":"direct_reply","editor_spans":[],"edits":[]}"#
        let layout = #"{"delivery":"direct_reply","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]},{"style":"paragraph","segment_ids":["c2"]}]}"#
        XCTAssertTrue(VoicePolishEditingReview.hasSourceReviewRisk(source))
        let (result, calls) = await run(source, [#"{"edits":[]}"#, contentReview, layout])
        assertSuccess(result, calls: calls, text: "先别发送，等我确认。\n\n材料已经备齐。", attempts: 3, repairs: 0)
        guard calls.count == 3 else { return }
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishAnalyze, .voicePolishAnalyze])
        let second = try payload(calls[1]), third = try payload(calls[2])
        XCTAssertNil(second["layout_segments"])
        XCTAssertEqual(second["canonical_text"] as? String, source)
        XCTAssertEqual(second["draft_text"] as? String, source)
        XCTAssertEqual(calls[1].system, VoicePolishEditingPrompts.standardContentReview)
        XCTAssertEqual(calls[2].system, VoicePolishEditingPrompts.review)
        XCTAssertEqual(third["layout_segments"] as? [[String: String]], [
            ["id": "c1", "text": "先别发送，等我确认。"], ["id": "c2", "text": "材料已经备齐。"]
        ])
    }

    func testDistantOwnerCorrectionKeepsValidReasonAndBindsRepairedDraft() async throws {
        let source = "阿文负责复查。共享材料使用带日期的文件。访问范围保持为项目成员，外部链接暂时不开放。设备报错先记录原话，尚未确认的原因不要自行补充。检查名单时先标记重复记录，再等我确认。阿文要出差，复查改由阿宁。"
        let repaired = "阿宁负责复查。共享材料使用带日期的文件。访问范围保持为项目成员，外部链接暂时不开放。设备报错先记录原话，尚未确认的原因不要自行补充。检查名单时先标记重复记录，再等我确认。阿文要出差。"
        let contentReview = #"{"delivery":"delegated_task","editor_spans":[],"edits":[{"before":"阿文负责复查。","after":"阿宁负责复查。","kind":"correction","evidence":"复查改由阿宁。"},{"before":"阿文要出差，复查改由阿宁。","after":"阿文要出差。","kind":"correction"}]}"#
        let layout = #"{"delivery":"delegated_task","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1","c6"]},{"style":"paragraph","segment_ids":["c2","c3","c4","c5"]}]}"#
        let (result, calls) = await run(source, [#"{"edits":[]}"#, contentReview, layout])
        assertSuccess(result, calls: calls, text: "阿宁负责复查。阿文要出差。\n\n共享材料使用带日期的文件。访问范围保持为项目成员，外部链接暂时不开放。设备报错先记录原话，尚未确认的原因不要自行补充。检查名单时先标记重复记录，再等我确认。", attempts: 3, repairs: 1)
        guard calls.count == 3 else { return }
        let second = try payload(calls[1]), third = try payload(calls[2])
        XCTAssertNil(second["layout_segments"])
        XCTAssertEqual(second["draft_text"] as? String, source)
        XCTAssertEqual(third["canonical_text"] as? String, source)
        XCTAssertEqual(third["draft_text"] as? String, repaired)
        XCTAssertEqual(third["layout_segments"] as? [[String: String]], [
            ["id": "c1", "text": "阿宁负责复查。"],
            ["id": "c2", "text": "共享材料使用带日期的文件。"],
            ["id": "c3", "text": "访问范围保持为项目成员，外部链接暂时不开放。"],
            ["id": "c4", "text": "设备报错先记录原话，尚未确认的原因不要自行补充。"],
            ["id": "c5", "text": "检查名单时先标记重复记录，再等我确认。"],
            ["id": "c6", "text": "阿文要出差。"]
        ])
    }

    func testClearingRiskCueInFirstDraftCannotSkipDedicatedReview() async throws {
        let source = "帮我整理一下：资料已备齐。"
        let initial = #"{"edits":[{"before":"帮我整理一下：","after":"","kind":"directive"}]}"#
        let contentReview = #"{"delivery":"direct_reply","editor_spans":["帮我整理一下："],"edits":[]}"#
        let layout = #"{"delivery":"direct_reply","editor_spans":["帮我整理一下："],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        XCTAssertTrue(VoicePolishEditingReview.hasSourceReviewRisk(source))
        XCTAssertFalse(VoicePolishEditingReview.hasSourceReviewRisk("资料已备齐。"))
        let (result, calls) = await run(source, [initial, contentReview, layout])
        assertSuccess(result, calls: calls, text: "资料已备齐。", attempts: 3, repairs: 0)
        guard calls.count == 3 else { return }
        let second = try payload(calls[1])
        XCTAssertNil(second["layout_segments"])
        XCTAssertEqual(second["canonical_text"] as? String, source)
        XCTAssertEqual(second["draft_text"] as? String, "资料已备齐。")
    }

    func testContentReviewCannotSmuggleLayoutField() async {
        let source = "先别发送，等我确认。"
        let wrongReview = #"{"delivery":"direct_reply","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        let (result, calls) = await run(source, [#"{"edits":[]}"#, wrongReview, wrongReview])
        assertFallback(result, calls: calls, source: source, attempts: 2, repairs: 0, code: .invalidStructuredResponse)
    }

    func testLayoutUsesActualRepairedSentenceBoundaries() async throws {
        let source = "帮我整理一下：先检查，再发送。"
        let initial = #"{"edits":[{"before":"帮我整理一下：","after":"","kind":"directive"}]}"#
        let contentReview = #"{"delivery":"other_or_uncertain","editor_spans":["帮我整理一下："],"edits":[{"before":"先检查，再发送。","after":"先检查。再发送。","kind":"punctuation"}]}"#
        let layout = #"{"delivery":"other_or_uncertain","editor_spans":["帮我整理一下："],"edits":[],"layout":[{"style":"numbered","segment_ids":["c1"]},{"style":"numbered","segment_ids":["c2"]}]}"#
        let (result, calls) = await run(source, [initial, contentReview, layout])
        assertSuccess(result, calls: calls, text: "1. 先检查。\n\n2. 再发送。", attempts: 3, repairs: 1)
        guard calls.count == 3 else { return }
        let second = try payload(calls[1]), third = try payload(calls[2])
        XCTAssertNil(second["layout_segments"])
        XCTAssertEqual(second["draft_text"] as? String, "先检查，再发送。")
        XCTAssertEqual(third["draft_text"] as? String, "先检查。再发送。")
        XCTAssertEqual(third["canonical_text"] as? String, source)
        XCTAssertEqual(third["layout_segments"] as? [[String: String]], [
            ["id": "c1", "text": "先检查。"], ["id": "c2", "text": "再发送。"]
        ])
    }

    func testThirdCallCannotRequestAnotherRepairOrStartFourthCall() async {
        let source = "先别发送，等我确认。"
        let contentReview = #"{"delivery":"direct_reply","editor_spans":[],"edits":[]}"#
        let furtherRepair = #"{"delivery":"direct_reply","editor_spans":[],"edits":[{"before":"确认","after":"回复","kind":"word"}],"layout":[]}"#
        let unusedFourth = #"{"delivery":"direct_reply","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        let (result, calls) = await run(source, [#"{"edits":[]}"#, contentReview, furtherRepair, unusedFourth])
        assertFallback(result, calls: calls, source: source, attempts: 3, repairs: 0, code: .planIntegrityFailure)
    }

    func testPublicCorrectionIsReviewedWithoutDeletingRecipientExplanation() async {
        let source = "公开更正：原通知时间说错了，请以本通知为准。"
        let contentReview = #"{"delivery":"direct_reply","editor_spans":[],"edits":[]}"#
        let layout = #"{"delivery":"direct_reply","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        XCTAssertTrue(VoicePolishEditingReview.hasSourceReviewRisk(source))
        let (result, calls) = await run(source, [#"{"edits":[]}"#, contentReview, layout])
        assertSuccess(result, calls: calls, text: source, attempts: 3, repairs: 0)
    }

    func testDownstreamProhibitionIsReviewedWithoutBecomingEditorDeletion() async {
        let source = "请转告同事：先别按旧安排发送，等我确认后再发。"
        let contentReview = #"{"delivery":"delegated_task","editor_spans":[],"edits":[]}"#
        let layout = #"{"delivery":"delegated_task","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        XCTAssertTrue(VoicePolishEditingReview.hasSourceReviewRisk(source))
        let (result, calls) = await run(source, [#"{"edits":[]}"#, contentReview, layout])
        assertSuccess(result, calls: calls, text: source, attempts: 3, repairs: 0)
    }

    func testOrdinaryShortSentenceKeepsTwoCallStandardRoute() async throws {
        let source = "材料已经备齐。"
        let layout = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        XCTAssertFalse(VoicePolishEditingReview.hasSourceReviewRisk(source))
        let (result, calls) = await run(source, [#"{"edits":[]}"#, layout])
        assertSuccess(result, calls: calls, text: source, attempts: 2, repairs: 0)
        guard calls.count == 2 else { return }
        XCTAssertNotNil(try payload(calls[1])["layout_segments"])
        XCTAssertEqual(calls[1].system, VoicePolishEditingPrompts.review)
    }

    func testOrdinaryWordCorrectionDoesNotAddDedicatedCall() async throws {
        let source = "请按装软件。"
        let initial = #"{"edits":[{"before":"按装","after":"安装","kind":"word"}]}"#
        let layout = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        XCTAssertFalse(VoicePolishEditingReview.hasSourceReviewRisk(source))
        let (result, calls) = await run(source, [initial, layout])
        assertSuccess(result, calls: calls, text: "请安装软件。", attempts: 2, repairs: 0)
        guard calls.count == 2 else { return }
        XCTAssertEqual(try payload(calls[1])["draft_text"] as? String, "请安装软件。")
        XCTAssertNotNil(try payload(calls[1])["layout_segments"])
    }

    func testInvalidContentRepairStopsBeforeLayoutAndRecordsAttempt() async {
        let source = "帮我整理一下：资料还没核对。"
        let invalidRepair = #"{"delivery":"direct_reply","editor_spans":[],"edits":[{"before":"资料还没核对。","after":"资料已经核对。","kind":"content","evidence":"资料还没核对。"}]}"#
        let unusedLayout = #"{"delivery":"direct_reply","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        let (result, calls) = await run(source, [#"{"edits":[]}"#, invalidRepair, unusedLayout])
        assertFallback(result, calls: calls, source: source, attempts: 2, repairs: 1, code: .planIntegrityFailure)
    }

    func testUnappliedEditorSpanStopsContentReviewBeforeLayout() async {
        let source = "帮我整理一下：资料已备齐。"
        let contentReview = #"{"delivery":"direct_reply","editor_spans":["帮我整理一下："],"edits":[]}"#
        let unusedLayout = #"{"delivery":"direct_reply","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        let (result, calls) = await run(source, [#"{"edits":[]}"#, contentReview, unusedLayout])
        assertFallback(result, calls: calls, source: source, attempts: 2, repairs: 0, code: .planIntegrityFailure)
    }

    func testLightPreservesProhibitionWithoutRoleReviewOrLayout() async throws {
        let source = "先别发送，等我确认。"
        let (result, calls) = await run(source, [#"{"edits":[]}"#], mode: .light)
        assertSuccess(result, calls: calls, text: source, attempts: 1, repairs: 0)
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast])
        for call in calls { XCTAssertNil(try payload(call)["layout_segments"]) }
    }

    private func run(_ source: String, _ responses: [String],
                     mode: VoicePolishQualityMode = .standard) async -> (VoicePolishResult, [LLMRequest]) {
        let client = DedicatedContentReviewClient(responses)
        let input = VoiceInputEnvelope(providerFinalText: source,
            segments: [RecognitionSegment(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                                           confidence: nil, isFinal: true)], durationMs: 1_000, provider: .volcano)
        let request = VoicePolishRequest(input: input, context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: mode)
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishPipeline(client: client, config: config).process(request)
        return (result, await client.requests)
    }

    private func payload(_ request: LLMRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any])
    }

    private func assertSuccess(_ result: VoicePolishResult, calls: [LLMRequest], text: String,
                               attempts: Int, repairs: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.usedFallback, file: file, line: line)
        XCTAssertNil(result.failureReason, file: file, line: line)
        XCTAssertTrue(result.validationCodes.isEmpty, "\(result.validationCodes)", file: file, line: line)
        XCTAssertEqual(result.text, text, file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, attempts, file: file, line: line)
        XCTAssertEqual(calls.count, attempts, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, repairs, file: file, line: line)
    }

    private func assertFallback(_ result: VoicePolishResult, calls: [LLMRequest], source: String,
                                attempts: Int, repairs: Int, code: VoicePolishValidationCode,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.usedFallback, file: file, line: line)
        XCTAssertEqual(result.failureReason, .validationFailed, file: file, line: line)
        XCTAssertEqual(result.text, source, file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, attempts, file: file, line: line)
        XCTAssertEqual(calls.count, attempts, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, repairs, file: file, line: line)
        XCTAssertTrue(result.validationCodes.contains(code), "\(result.validationCodes)", file: file, line: line)
    }
}

/// 固定脚本只按次序返回字面 JSON，不根据请求生成补丁、布局或通过答案。
private actor DedicatedContentReviewClient: LLMClient {
    private var responses: [String]
    private(set) var requests: [LLMRequest] = []
    init(_ responses: [String]) { self.responses = responses }
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw LLMError.emptyResponse(nil) }
        return LLMResponse(text: responses.removeFirst(), model: config.model)
    }
    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }
    func warmUp(baseURL: String) async {}
}
