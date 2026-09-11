import XCTest
@testable import Muse

final class VoicePolishStructuredContentPipelineTests: XCTestCase {
    func testStructureMovesReasonWithoutDeletingAnyContent() async throws {
        let source = "小赵负责核对名单。报价等财务回复。小李下午有别的事。"
        let review = #"{"delivery":"delegated_task","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1","c3"]},{"style":"paragraph","segment_ids":["c2"]}]}"#
        let (result, calls) = await run(source, [#"{"edits":[]}"#, review])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "小赵负责核对名单。小李下午有别的事。\n\n报价等财务回复。")
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishAnalyze])
        XCTAssertEqual(calls.first?.options.responseFormat, .jsonObject)
        let initial = try payload(calls[0])
        XCTAssertNil(initial["layout_segments"])
        let reviewed = try payload(calls[1])
        let segments = try XCTUnwrap(reviewed["layout_segments"] as? [[String: String]])
        XCTAssertEqual(segments.compactMap { $0["text"] }.joined(), source)
        XCTAssertEqual(segments.compactMap { $0["id"] }, ["c1", "c2", "c3"])
    }

    func testMissingReasonSegmentCannotBecomeSuccessfulOutput() async {
        let source = "小赵负责名单。小李下午有别的事。"
        for layout in [
            #"[{"style":"paragraph","segment_ids":["c1"]}]"#,
            #"[{"style":"paragraph","segment_ids":["c1","c1"]}]"#,
            #"[{"style":"paragraph","segment_ids":["c1","made-up"]}]"#,
            #"[{"style":"paragraph","segment_ids":["c1","c2"],"text":"小赵负责名单。"}]"#
        ] {
            let review = #"{"delivery":"delegated_task","editor_spans":[],"edits":[],"layout":\#(layout)}"#
            let (result, _) = await run(source, [#"{"edits":[]}"#, review])
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(result.llmAttemptCount, 2)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertTrue(result.validationCodes.contains(.invalidStructuredResponse))
        }
    }

    func testStandardNoLongerAcceptsFreeTextOrUnboundedContentRewrite() async {
        let source = "名单交给小赵。小李下午有别的事，所以调整分工。"
        for initial in ["名单交给小赵。", #"{"edits":[{"before":"名单交给小赵。小李下午有别的事，所以调整分工。","after":"名单交给小赵。","kind":"content","evidence":"名单交给小赵。"}]}"#] {
            let (result, _) = await run(source, [initial])
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(result.llmAttemptCount, 1)
        }
    }

    func testProgramNumberingDoesNotGrantNewNumbersToModelContent() async {
        let source = "请执行 `swift test`。等审核完成。请执行 `swift build`。"
        let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"numbered","segment_ids":["c1"]},{"style":"paragraph","segment_ids":["c2"]},{"style":"numbered","segment_ids":["c3"]}]}"#
        let (result, _) = await run(source, [#"{"edits":[]}"#, review], scene: .code)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "1. 请执行 `swift test`。\n\n等审核完成。\n\n1. 请执行 `swift build`。")
        let insertion = #"{"edits":[{"before":"等审核完成","after":"等审核3天完成","kind":"word"}]}"#
        let (invented, _) = await run(source, [insertion, review], scene: .code)
        XCTAssertTrue(invented.usedFallback)
        XCTAssertEqual(invented.text, source)
    }

    func testManyTrustedBulletMarkersAreNotMistakenForContentExpansion() async throws {
        let source = String(repeating: "甲。", count: 20)
        let layout = (1...20).map { ["style": "bullet", "segment_ids": ["c\($0)"]] as [String: Any] }
        let review = try json(["delivery": "other_or_uncertain", "editor_spans": [], "edits": [], "layout": layout])
        let (result, _) = await run(source, [#"{"edits":[]}"#, review])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, Array(repeating: "- 甲。", count: 20).joined(separator: "\n\n"))
        XCTAssertGreaterThan(result.text.count, source.count * 2)
    }

    func testRepairRebuildsSegmentsAndRejectsPreviousLayout() async throws {
        let source = "先检查，再发送。"
        let repair = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[{"before":"先检查，再发送。","after":"先检查。再发送。","kind":"punctuation"}],"layout":[]}"#
        for ids in [["c1"], ["c1", "c2"]] {
            let confirmation = try json(["delivery": "other_or_uncertain", "editor_spans": [], "edits": [],
                                         "layout": [["style": "paragraph", "segment_ids": ids]]])
            let (result, calls) = await run(source, [#"{"edits":[]}"#, repair, confirmation])
            XCTAssertEqual(result.usedFallback, ids.count == 1)
            XCTAssertEqual(result.llmAttemptCount, 3)
            XCTAssertEqual(result.repairAttemptCount, 1)
            XCTAssertEqual(result.text, ids.count == 1 ? source : "先检查。再发送。")
            let second = try payload(calls[1]), third = try payload(calls[2])
            XCTAssertEqual((second["layout_segments"] as? [Any])?.count, 1)
            XCTAssertEqual((third["layout_segments"] as? [Any])?.count, 2)
            XCTAssertEqual(third["draft_text"] as? String, "先检查。再发送。")
        }
    }

    func testPendingContentRepairCannotAlsoApproveOldLayout() async {
        let source = "请按装软件。"
        let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[{"before":"按装","after":"安装","kind":"word"}],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        let (result, _) = await run(source, [#"{"edits":[]}"#, review])
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertTrue(result.validationCodes.contains(.invalidStructuredResponse))
    }

    func testLightCannotAcceptStandardLayoutField() async throws {
        let source = "先别发送，等我确认。"
        let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        let (result, calls) = await run(source, [#"{"edits":[]}"#, review], mode: .light)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        for call in calls { XCTAssertNil(try payload(call)["layout_segments"]) }
    }

    func testStandardContentStillProtectsDeliberateEmphasis() async {
        let source = "确实确实有帮助。"
        let patch = #"{"edits":[{"before":"确实确实","after":"确实","kind":"stutter"}]}"#
        let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        let (result, _) = await run(source, [patch, review])
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.validationCodes.contains(.missingProtectedFact))
    }

    func testClockCorrectionKeepsFinalWholeASCIIClockInBothModes() async {
        let source = "会议10:30，不对，10:45开始。"
        let patch = #"{"edits":[{"before":"会议10:30，不对，10:45开始。","after":"会议10:45开始。","kind":"correction"}]}"#
        for mode in [VoicePolishQualityMode.light, .standard] {
            let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[]}"#
            let layout = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
            let (result, _) = await run(source, mode == .light ? [patch, review] : [patch, review, layout], mode: mode)
            XCTAssertFalse(result.usedFallback, "\(mode)")
            XCTAssertEqual(result.text, "会议10:45开始。")
            XCTAssertEqual(result.llmAttemptCount, mode == .light ? 2 : 3)
        }
    }

    func testIndentedCodeCannotAcquireProgramListMarkers() async {
        let source = "代码如下：\n    if ready:\n        send()"
        for style in ["numbered", "bullet", "paragraph"] {
            let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"\#(style)","segment_ids":["c1"]}]}"#
            let (result, _) = await run(source, [#"{"edits":[]}"#, review], scene: .code)
            XCTAssertEqual(result.usedFallback, style != "paragraph")
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(result.llmAttemptCount, 2)
        }
    }

    func testExistingBlankLinesDoNotCreateEmptyNumberedItem() async {
        let source = "先检查。\n\n再发布。"
        let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[],"layout":[{"style":"numbered","segment_ids":["c1"]},{"style":"numbered","segment_ids":["c2"]}]}"#
        let (result, _) = await run(source, [#"{"edits":[]}"#, review])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "1. 先检查。\n\n2. 再发布。")
        XCTAssertEqual(RecognitionSession.finalizeInsertionText(result.text, mode: .formalWriting, isLLMOutput: true), result.text)
    }

    private func run(_ source: String, _ responses: [String], scene: WritingScene = .workChat,
                     mode: VoicePolishQualityMode = .standard) async -> (VoicePolishResult, [LLMRequest]) {
        let client = StructurePipelineClient(responses)
        let input = VoiceInputEnvelope(providerFinalText: source,
            segments: [RecognitionSegment(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true)],
            durationMs: 1_000, provider: .volcano)
        let request = VoicePolishRequest(input: input, context: WritingContext(scene: scene),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: mode)
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishPipeline(client: client, config: config).process(request)
        return (result, await client.requests)
    }

    private func payload(_ request: LLMRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any])
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

private actor StructurePipelineClient: LLMClient {
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
