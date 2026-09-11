import XCTest
@testable import Muse

/// 固定模型响应只验证轻度职责、权限和调用流程，不替代真实语义质量验收。
final class VoicePolishLightScopeTests: XCTestCase {
    func testTaskSpeechOnlyNeedsPunctuationAndOneCall() async {
        let cases = [
            ("帮我整理Prompt先别执行", "帮我整理 Prompt，先别执行。"),
            ("给客户回一下材料还没核对不要承诺日期", "给客户回一下，材料还没核对，不要承诺日期。"),
            ("跟他说我晚十分钟到", "跟他说，我晚十分钟到。")
        ]
        for (source, expected) in cases {
            let (result, calls) = await run(source, [text(expected)])
            XCTAssertFalse(result.usedFallback, source)
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.llmAttemptCount, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertEqual(calls.map(\.task), [.voicePolishFast])
        }
    }

    func testSameDraftKeepsTaskPrefixAndBothLevelsOfProhibition() async {
        let source = "帮我整理成 Prompt。先别执行，给同事写清楚：先别发布，等确认。"
        let (result, calls) = await run(source, [text(source)])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(calls.count, 1)
    }

    func testLightHardRejectsDirectiveAndContentEvenWithReviewFlagsOrMechanicalDifference() {
        let source = "给客户回一下：请按装软件"
        for kind in [VoicePolishTextEdit.Kind.directive, .content] {
            for flags in [false, true] {
                for edit in [VoicePolishTextEdit(before: "给客户回一下：", after: "", kind: kind),
                             .init(before: "请按装软件", after: "请按装软件。", kind: kind)] {
                    XCTAssertThrowsError(try VoicePolishTextEditor.apply(
                        [.init(before: "按装", after: "安装", kind: .word), edit],
                        to: source, source: source, mode: .light,
                        allowsReviewedInlineDirectives: flags, allowsReviewedSourceCorrections: flags
                    )) { XCTAssertEqual($0 as? VoicePolishTextEditError, .editOutsideMode) }
                }
            }
        }
    }

    func testOldFirstEditsProtocolCannotBeDeliveredOrPartiallyApplied() async {
        let source = "给客户回一下：请按装软件。"
        let response = #"{"edits":[{"before":"按装","after":"安装","kind":"word"},{"before":"给客户回一下：","after":"","kind":"directive"}]}"#
        let (result, calls) = await run(source, [response, #"{"edits":[]}"#])
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertTrue(result.validationCodes.contains(.invalidStructuredResponse))
    }

    func testWordCorrectionStillReviewsActualDraftAndKeepsTaskSpeech() async throws {
        let source = "帮我整理 Prompt：请按装软件，先别执行。"
        let patch = #"{"edits":[{"before":"按装","after":"安装","kind":"word"}]}"#
        let target = "帮我整理 Prompt：请安装软件，先别执行。"
        let (result, calls) = await run(source, [text(target), reviewJSON(target, edits: patch)])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "帮我整理 Prompt：请安装软件，先别执行。")
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze])
        XCTAssertEqual(result.repairAttemptCount, 0)
        let review = try payload(calls[1])
        XCTAssertEqual(review["canonical_text"] as? String, source)
        XCTAssertEqual(review["draft_text"] as? String, result.text)
        XCTAssertEqual(review["mode"] as? String, "light")
        XCTAssertEqual(review["schema_version"] as? Int, 10)
        XCTAssertNil(review["layout_segments"])
    }

    func testUnchangedFirstCandidateStillRepairsLateCorrectionAndConfirmsActualDraft() async throws {
        let source = "帮我整理 Prompt：阿文负责复查。\n其余资料先保留。\n复查改由阿宁，阿文要出差。"
        let repair = #"{"edits":[{"before":"阿文负责复查。","after":"阿宁负责复查。","kind":"correction","evidence":"复查改由阿宁，阿文要出差。"},{"before":"复查改由阿宁，","after":"","kind":"correction"}]}"#
        let target = "帮我整理 Prompt：阿宁负责复查。\n其余资料先保留。\n阿文要出差。"
        let (result, calls) = await run(source, [text(source), reviewJSON(target, edits: repair), #"{"approved":true}"#])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "帮我整理 Prompt：阿宁负责复查。\n其余资料先保留。\n阿文要出差。")
        XCTAssertEqual(result.llmAttemptCount, 3)
        XCTAssertEqual(result.repairAttemptCount, 1)
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze, .voicePolishAnalyze])
        XCTAssertEqual(try payload(calls[1])["draft_text"] as? String, source)
        XCTAssertEqual(try payload(calls[2])["draft_text"] as? String, result.text)
        for call in calls {
            XCTAssertEqual(try payload(call)["canonical_text"] as? String, source)
            XCTAssertNil(try payload(call)["layout_segments"])
        }
    }

    func testReviewCannotDeleteTaskSpeechOrUseStandardContentRewrite() async {
        let source = "帮我整理 Prompt：等一下，请保留原因。"
        for response in [
            #"{"edits":[{"before":"帮我整理 Prompt：","after":"","kind":"directive"}]}"#,
            #"{"edits":[{"before":"请保留原因。","after":"原因：请保留。","kind":"content","evidence":"请保留原因。"}]}"#
        ] {
            let (result, calls) = await run(source, [text(source), reviewJSON("等一下，请保留原因。", edits: response)])
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(result.repairAttemptCount, 1)
            XCTAssertTrue(result.validationCodes.contains(.planIntegrityFailure))
        }
    }

    func testReviewExtraFieldsFailBeforeRepairAndAlsoAtFinalConfirmation() async {
        let source = "我补一句，请按装软件。"
        let patch = #"{"edits":[{"before":"按装","after":"安装","kind":"word"}]}"#
        for invalid in [
            #"{"edits":[],"delivery":"direct_reply"}"#,
            #"{"edits":[],"editor_spans":[]}"#,
            #"{"edits":[],"layout":[]}"#,
            #"{"edits":[],"source_roles":[]}"#
        ] {
            for repairs in [0, 1] {
                let target = "我补一句，请安装软件。"
                let responses = repairs == 0 ? [text(source), invalid] : [text(source), reviewJSON(target, edits: patch), invalid]
                let (result, calls) = await run(source, responses)
                XCTAssertTrue(result.usedFallback)
                XCTAssertEqual(result.text, source)
                XCTAssertEqual(calls.count, repairs == 0 ? 2 : 3)
                XCTAssertEqual(result.repairAttemptCount, repairs)
                XCTAssertTrue(result.validationCodes.contains(.invalidStructuredResponse))
                XCTAssertFalse(result.validationCodes.contains(.planIntegrityFailure))
            }
        }
    }

    func testThirdReviewCannotApplyAgainOrStartFourthCall() async {
        let source = "我补一句，请按装软件。"
        let repair = #"{"edits":[{"before":"按装","after":"安装","kind":"word"}]}"#
        let furtherRepair = #"{"edits":[{"before":"安装","after":"卸载","kind":"word"}]}"#
        let (result, calls) = await run(source, [text(source), reviewJSON("我补一句，请安装软件。", edits: repair), furtherRepair, #"{"approved":true}"#])
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(result.repairAttemptCount, 1)
        XCTAssertTrue(result.validationCodes.contains(.invalidStructuredResponse))
    }

    func testPublicCorrectionAndDownstreamProhibitionMayRemainAfterReview() async {
        for source in ["请发布更正：上次说错了，原来写成周三，实际是周四。",
                       "请同事保留这条禁令：不要改由阿宁，等确认再安排。"] {
            let (result, calls) = await run(source, [text(source), reviewJSON(source)])
            XCTAssertFalse(result.usedFallback, source)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(result.repairAttemptCount, 0)
        }
    }

    private func text(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(["text": value]), as: UTF8.self)
    }

    private func reviewJSON(_ value: String, edits: String = #"{"edits":[]}"#) -> String {
        var object = try! JSONSerialization.jsonObject(with: Data(edits.utf8)) as! [String: Any]
        object["text"] = value
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func run(_ source: String, _ responses: [String]) async -> (VoicePolishResult, [LLMRequest]) {
        let client = LightScopeClient(responses)
        let input = VoiceInputEnvelope(providerFinalText: source,
            segments: [RecognitionSegment(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                                           confidence: nil, isFinal: true)], durationMs: 1_000, provider: .volcano)
        let request = VoicePolishRequest(input: input, context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: .light)
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishPipeline(client: client, config: config).process(request)
        return (result, await client.requests)
    }

    private func payload(_ request: LLMRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any])
    }
}

private actor LightScopeClient: LLMClient {
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
