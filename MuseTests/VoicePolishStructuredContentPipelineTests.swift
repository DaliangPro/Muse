import XCTest
@testable import Muse

final class VoicePolishStructuredContentPipelineTests: XCTestCase {
    func testStructureMovesReasonWithoutRewritingReturnedContent() async throws {
        let source = "小赵负责核对名单。报价等财务回复。小李下午有别的事。"
        let structured = "小赵负责核对名单。小李下午有别的事。\n\n报价等财务回复。"
        let (result, calls) = await run(source, [source, structured])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishStructured])
        for call in calls {
            XCTAssertEqual(call.options.responseFormat, .text)
            XCTAssertEqual(try payload(call) as? [String: String], ["canonical_text": source])
        }
    }

    // 旧布局工具仍保留独立反例；标准运行链不再解码或执行这些布局协议。
    func testLegacyLayoutDecoderRejectsMissingDuplicatedAndInventedReasonSegments() throws {
        let source = "小赵负责名单。小李下午有别的事。"
        let segments = try VoicePolishStructurePlan.segments(in: source)
        for layout in [
            #"[{"style":"paragraph","segment_ids":["c1"]}]"#,
            #"[{"style":"paragraph","segment_ids":["c1","c1"]}]"#,
            #"[{"style":"paragraph","segment_ids":["c1","made-up"]}]"#,
            #"[{"style":"paragraph","segment_ids":["c1","c2"],"text":"小赵负责名单。"}]"#
        ] {
            let object = try JSONSerialization.jsonObject(with: Data(layout.utf8))
            XCTAssertThrowsError(try VoicePolishStructurePlan.decodeLayout(from: object, segments: segments))
        }
    }

    func testStandardPassesCompleteFirstDraftToStructureInsteadOfApplyingPatches() async throws {
        let source = "名单交给小赵。小李下午有别的事，所以调整分工。"
        let prepared = "名单交给小赵，小李下午有别的事，所以调整分工。"
        let (result, calls) = await run(source, [prepared, prepared])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, prepared)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(try payload(calls[1]) as? [String: String], ["canonical_text": prepared])
    }

    func testReturnedNumberingIsPreservedWithoutProgramRenumbering() async {
        let source = "请执行 `swift test`。等审核完成。请执行 `swift build`。"
        let structured = "1. 请执行 `swift test`。\n\n等审核完成。\n\n2. 请执行 `swift build`。"
        let (result, _) = await run(source, [source, structured], scene: .code)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: source, outputText: "等审核3天完成。", scene: .code
        ).isEmpty)
    }

    func testManyReturnedBulletMarkersAreNotMistakenForContentExpansion() async {
        let source = String(repeating: "甲。", count: 20)
        let structured = Array(repeating: "- 甲。", count: 20).joined(separator: "\n\n")
        let (result, _) = await run(source, [source, structured])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        XCTAssertGreaterThan(result.text.count, source.count * 2)
    }

    func testLegacyLayoutRejectsSegmentsFromBeforeSentenceBoundaryChange() throws {
        let original = try VoicePolishStructurePlan.segments(in: "先检查，再发送。")
        let corrected = try VoicePolishStructurePlan.segments(in: "先检查。再发送。")
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(corrected.count, 2)
        for ids in [["c1"], ["c1", "c2"]] {
            let blocks: [[String: Any]] = [["style": "paragraph", "segment_ids": ids]]
            if ids.count == 1 {
                XCTAssertThrowsError(try VoicePolishStructurePlan.decodeLayout(from: blocks, segments: corrected))
            } else {
                let layout = try VoicePolishStructurePlan.decodeLayout(from: blocks, segments: corrected)
                XCTAssertEqual(try VoicePolishStructurePlan.render(layout, segments: corrected), "先检查。再发送。")
            }
        }
    }

    func testLegacyReviewCannotApplyPendingContentRepairAndOldLayoutTogether() throws {
        let source = "请按装软件。"
        let review = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[{"before":"按装","after":"安装","kind":"word"}],"layout":[{"style":"paragraph","segment_ids":["c1"]}]}"#
        XCTAssertThrowsError(try VoicePolishEditingReview.decode(
            review, source: source, structureSegments: VoicePolishStructurePlan.segments(in: source)
        ))
    }

    func testLightDoesNotRequestOrRenderStandardLayout() async throws {
        let source = "等一下，先别发送，等我确认。"
        let (result, calls) = await run(source, [source], mode: .light)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.options.responseFormat, .text)
        XCTAssertEqual(Set(try payload(call).keys), ["canonical_text"])
    }

    func testStandardKeepsMeaningPreservingEmphasisConsolidationFromFirstStage() async {
        let source = "确实确实有帮助。"
        let prepared = "确实有帮助。"
        let (result, _) = await run(source, [prepared, prepared])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, prepared)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testClockCorrectionKeepsFinalWholeASCIIClockInBothModes() async throws {
        let source = "会议10:30，不对，10:45开始。"
        let output = "会议10:45开始。"
        for mode in [VoicePolishQualityMode.light, .standard] {
            let (result, _) = await run(source, mode == .light ? [output] : [output, output], mode: mode)
            XCTAssertFalse(result.usedFallback, "\(mode)")
            XCTAssertEqual(result.text, output)
            XCTAssertEqual(result.llmAttemptCount, mode == .light ? 1 : 2)
        }
    }

    func testLegacyLayoutCannotAddProgramListMarkersInsideIndentedCode() throws {
        let source = "代码如下：\n    if ready:\n        send()"
        let segments = try VoicePolishStructurePlan.segments(in: source)
        for style in ["numbered", "bullet", "paragraph"] {
            let blocks: [[String: Any]] = [["style": style, "segment_ids": ["c1"]]]
            if style == "paragraph" {
                let layout = try VoicePolishStructurePlan.decodeLayout(from: blocks, segments: segments)
                XCTAssertEqual(try VoicePolishStructurePlan.render(layout, segments: segments), source)
            } else {
                XCTAssertThrowsError(try VoicePolishStructurePlan.decodeLayout(from: blocks, segments: segments))
            }
        }
    }

    func testExistingBlankLinesDoNotCreateEmptyNumberedItem() async {
        let source = "先检查。\n\n再发布。"
        let structured = "1. 先检查。\n\n2. 再发布。"
        let (result, _) = await run(source, [source, structured])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
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
