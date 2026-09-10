import XCTest
@testable import Muse

final class VoicePolishEditingPipelineTests: XCTestCase {
    private let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")

    func testLightAppliesOnlyAnchoredEditsAndKeepsUntouchedReason() async {
        let source = "我我今天按装软件。小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([
            .text(#"{"edits":[{"before":"我我今天","after":"我今天","kind":"stutter"},{"before":"按装","after":"安装","kind":"word"}]}"#)
        ])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "我今天安装软件。小李下午有别的事，所以请小周接手。")
        XCTAssertEqual(result.llmAttemptCount, 1)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast])
        XCTAssertEqual(calls.first?.options.reasoningPolicy, .disabled)
        XCTAssertTrue(calls.first?.user.contains("\"mode\":\"light\"") == true)
    }

    func testLightCanLeaveNaturalSentenceUnchanged() async {
        let client = EditingTestClient([.text(#"{"edits":[]}"#)])
        let source = "对对对，我明白了。"
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testFactGuardPreservesNaturalTimesDecimalsAndOrdinaryWords() {
        for scene in [WritingScene.workChat, .code] {
            for source in ["明天下午三点开会，重点是核对链接。", "价格是三点五元，九点半出发。"] {
                XCTAssertEqual(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
                    sourceText: source, outputText: source, scene: scene
                ), [], "\(scene): \(source)")
            }
        }
    }

    func testMalformedEditJSONIsValidationFailure() async {
        let client = EditingTestClient([.text("{broken")])
        let result = await pipeline(client).process(request("明天开会。", .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.failureReason, .validationFailed)
    }

    func testLightDoesNotEscalateLongOrComplexInputToLedger() async {
        let source = String(repeating: "先检查原文里的原因和限制，内容保持不变。", count: 35)
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let client = EditingTestClient([.text(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast])
    }

    func testLightRejectsStandardRewriteWithoutAnotherModelCall() async {
        let source = "先检查，再发送。"
        let client = EditingTestClient([.text(#"{"edits":[{"before":"先检查，再发送。","after":"先发送，再检查。","kind":"content"}]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.failureReason, .validationFailed)
    }

    func testLightRejectsOrderSwapDisguisedAsWordCorrection() throws {
        XCTAssertThrowsError(try VoicePolishTextEditor.apply([
            .init(before: "先检查，再发送", after: "先发送，再检查", kind: .word)
        ], to: "先检查，再发送", source: "先检查，再发送", mode: .light))
    }

    func testLightRejectsFactDeletionDisguisedAsStutter() throws {
        let source = "检查文件并发送文件"
        XCTAssertThrowsError(try VoicePolishTextEditor.apply([
            .init(before: source, after: "发送文件", kind: .stutter)
        ], to: source, source: source, mode: .light))
        let reversedTasks = "甲通知乙，乙通知甲。"
        XCTAssertThrowsError(try VoicePolishTextEditor.apply([
            .init(before: reversedTasks, after: "甲通知乙。", kind: .stutter)
        ], to: reversedTasks, source: reversedTasks, mode: .light))
    }

    func testLightRemovesAdjacentStuttersButCanInsertMissingWord() throws {
        let source = "我我我今今天要按装软件"
        XCTAssertEqual(try VoicePolishTextEditor.apply([
            .init(before: "我我我今今天", after: "我今天", kind: .stutter),
            .init(before: "要按装", after: "要安装", kind: .word)
        ], to: source, source: source, mode: .light), "我今天要安装软件")
        XCTAssertEqual(try VoicePolishTextEditor.apply([
            .init(before: "我明去", after: "我明天去", kind: .word)
        ], to: "我明去", source: "我明去", mode: .light), "我明天去")
    }

    func testLightTechnicalSymbolsUseOnlyExactMechanicalChanges() throws {
        for (source, output) in [("swift build短横线c release", "swift build -c release"),
                                 ("main点swift", "main.swift")] {
            XCTAssertEqual(try VoicePolishTextEditor.apply([
                .init(before: source, after: output, kind: .symbol)
            ], to: source, source: source, mode: .light), output)
        }
        for (source, output) in [("三点开会", "三.开会"), ("先swift test", "swift test")] {
            XCTAssertThrowsError(try VoicePolishTextEditor.apply([
                .init(before: source, after: output, kind: .symbol)
            ], to: source, source: source, mode: .light))
        }
    }

    func testLightDirectivePermissionIsOnlyForBoundedLeadingPrefix() throws {
        let source = "给客户回一下：我们已收到材料。"
        XCTAssertEqual(try VoicePolishTextEditor.apply([
            .init(before: "给客户回一下：", after: "", kind: .directive)
        ], to: source, source: source, mode: .light), "我们已收到材料。")
        let downstream = "给同事的任务是，给客户回一下：我们已收到材料。"
        XCTAssertThrowsError(try VoicePolishTextEditor.apply([
            .init(before: "给客户回一下：", after: "", kind: .directive)
        ], to: downstream, source: downstream, mode: .light))
    }

    func testFactGuardAcceptsQuotedExistingCommandButRejectsNewCommand() {
        for output in ["请执行 `swift test`。", "请执行 swift test。"] {
            XCTAssertEqual(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
                sourceText: "请执行 swift test。", outputText: output, scene: .code
            ), [])
        }
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: "请执行 swift test。", outputText: "请执行 `swift build`。", scene: .code
        ).isEmpty)
    }

    func testStandardPartialTimeRequiresSemanticReviewAndCannotInventDate() async {
        let source = "会议原定周三上午十点，培训安排周四上午十点。会议时间改成十点半，日期不变。培训安排也不变。"
        let good = "会议改为周三上午十点半，培训仍为周四上午十点。"
        let client = EditingTestClient([.text(good), .text(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: source, outputText: "会议改为周五上午十点半。", scene: .workChat,
            allowsPartialTimeReview: true
        ).isEmpty)
        let wrong = "会议改为周四上午十点半，培训仍为周四上午十点。"
        let repair = #"{"edits":[{"before":"会议改为周四上午十点半","after":"会议改为周三上午十点半","kind":"content","evidence":"会议原定周三上午十点"}]}"#
        let correctionClient = EditingTestClient([.text(wrong), .text(repair), .text(#"{"edits":[]}"#)])
        let corrected = await pipeline(correctionClient).process(request(source, .standard))
        XCTAssertFalse(corrected.usedFallback)
        XCTAssertEqual(corrected.text, good)
        XCTAssertEqual(corrected.llmAttemptCount, 3)
    }

    func testLightPreservesDeliberateEmphasisEvenIfPatchIsSubsequence() async {
        let source = "确实确实有帮助。"
        let client = EditingTestClient([.text(#"{"edits":[{"before":"确实确实","after":"确实","kind":"stutter"}]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.validationCodes.contains(.missingProtectedFact))
    }

    func testLightAllowsExplicitLocalSelfCorrection() async {
        let source = "预算一万六，不对，一万五，周五交付。"
        let client = EditingTestClient([.text(#"{"edits":[{"before":"一万六，不对，一万五","after":"一万五","kind":"correction"}]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "预算一万五，周五交付。")
    }

    func testLightRejectsContentDeletionDisguisedAsPunctuation() throws {
        let source = "小李下午有别的事，所以找小周。"
        XCTAssertThrowsError(try VoicePolishTextEditor.apply([
            .init(before: source, after: "找小周。", kind: .punctuation)
        ], to: source, source: source, mode: .light))
    }

    func testLightPunctuationCannotIntroduceParagraphStructure() throws {
        let source = "先检查，再发送"
        XCTAssertThrowsError(try VoicePolishTextEditor.apply([
            .init(before: source, after: "先检查。\n\n再发送。", kind: .punctuation)
        ], to: source, source: source, mode: .light))
    }

    func testLightPunctuationCannotEraseTechnicalCharacters() throws {
        for (source, output) in [("git reset --hard", "git reset hard"),
                                 ("foo_bar", "foobar"), ("main.swift", "mainswift"),
                                 ("/tmp/file", "tmp/file"), ("10:30", "1030")] {
            XCTAssertThrowsError(try VoicePolishTextEditor.apply([
                .init(before: source, after: output, kind: .punctuation)
            ], to: source, source: source, mode: .light))
        }
        XCTAssertEqual(try VoicePolishTextEditor.apply([
            .init(before: "run swift test", after: "run swift test.", kind: .punctuation)
        ], to: "run swift test", source: "run swift test", mode: .light), "run swift test.")
    }

    func testLightCannotMoveTechnicalMarksOrHideTheirDeletionInAnotherKind() throws {
        for (source, output, kind) in [
            ("请用 foo_bar", "请用 foobar_", VoicePolishTextEdit.Kind.punctuation),
            ("我我使用 foo_bar", "我使用 foobar", .stutter),
            ("按装 foo_bar", "安装 foobar", .word)
        ] {
            XCTAssertThrowsError(try VoicePolishTextEditor.apply([
                .init(before: source, after: output, kind: kind)
            ], to: source, source: source, mode: .light))
        }
        XCTAssertEqual(try VoicePolishTextEditor.apply([
            .init(before: "foo_bar foo_bar", after: "foo_bar", kind: .stutter)
        ], to: "foo_bar foo_bar", source: "foo_bar foo_bar", mode: .light), "foo_bar")
    }

    func testPatchesRejectAmbiguousMissingAndOverlappingAnchorsAtomically() throws {
        for edits in [
            [VoicePolishTextEdit(before: "检查", after: "查看", kind: .word)],
            [VoicePolishTextEdit(before: "不存在", after: "查看", kind: .word)],
            [.init(before: "先检查", after: "先查看", kind: .word),
             .init(before: "检查文件", after: "查看文件", kind: .word)]
        ] {
            XCTAssertThrowsError(try VoicePolishTextEditor.apply(
                edits, to: "先检查文件，再检查结果", source: "先检查文件，再检查结果", mode: .light
            ))
        }
    }

    func testPatchOffsetsAreStableAcrossEmojiAndMultipleEdits() throws {
        let source = "👨‍👩‍👧‍👦我我按装软件，然后看看效果👍🏽"
        let output = try VoicePolishTextEditor.apply([
            .init(before: "我我", after: "我", kind: .stutter),
            .init(before: "按装", after: "安装", kind: .word),
            .init(before: "效果👍🏽", after: "效果👍🏽。", kind: .punctuation)
        ], to: source, source: source, mode: .light)
        XCTAssertEqual(output, "👨‍👩‍👧‍👦我安装软件，然后看看效果👍🏽。")
    }

    func testStandardReviewsActualDraftWithFullSourceAndComputedDeletions() async throws {
        let source = "小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([.text(source), .text(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishAnalyze])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: Any])
        XCTAssertEqual(payload["canonical_text"] as? String, source)
        XCTAssertEqual(payload["draft_text"] as? String, source)
        XCTAssertEqual(payload["mode"] as? String, "standard")
        XCTAssertNotNil(payload["changes"])
    }

    func testStandardCanRepairMissingReasonAndMustConfirmActualRepairedDraft() async throws {
        let source = "小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([
            .text("请小周接手。"),
            .text(#"{"edits":[{"before":"请小周接手。","after":"小李下午有别的事，所以请小周接手。","kind":"content","evidence":"小李下午有别的事，所以请小周接手。"}]}"#),
            .text(#"{"edits":[]}"#)
        ])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 3)
        let calls = await client.requests
        let firstReview = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: Any])
        let changes = try XCTUnwrap(firstReview["changes"] as? [[String: String]])
        XCTAssertTrue(changes.compactMap { $0["removed"] }.joined().contains("小李下午有别的事"))
        let confirmation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[2].user.utf8)) as? [String: Any])
        XCTAssertEqual(confirmation["draft_text"] as? String, source)
    }

    func testStandardRejectsUnbackedReviewerPatch() async {
        let source = "请小周接手。"
        let client = EditingTestClient([
            .text(source),
            .text(#"{"edits":[{"before":"请小周接手。","after":"小李请假了，请小周接手。","kind":"content","evidence":"小李请假了"}]}"#)
        ])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
    }

    func testStandardCannotAcceptUnbackedCurrencyEvenWhenReviewerPasses() async {
        let client = EditingTestClient([.text("预算是 16000 元。"), .text(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request("预算是一万六。", .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.planIntegrityFailure))
    }

    func testFactGuardAcceptsEquivalentBareNumbersAndUnitsButRejectsInventedOnes() {
        let cases: [(String, String, Bool)] = [
            ("预算是一万六。", "预算是 16000。", true),
            ("预算是一万六。", "预算是 16000 元。", false),
            ("等待两分钟。", "等待 2 分钟。", true),
            ("等待两分钟。", "等待 2 小时。", false),
            ("预算是两万美元。", "预算是 20000 元。", false),
            ("本次金额是四万八。", "本次金额是 48000。", true),
            ("请执行 `swift build`。", "请执行 `swift test`。", false)
        ]
        for (source, output, allowed) in cases {
            XCTAssertEqual(VoicePolishEditingPipeline.outputCodes(output, request: request(source, .standard)).isEmpty,
                           allowed, "\(source) → \(output)")
        }
    }

    func testStandardRejectsConfirmationThatStillWantsToRepair() async {
        let patch = #"{"edits":[{"before":"请检查。","after":"请核对。","kind":"content","evidence":"请核对。"}]}"#
        let client = EditingTestClient([.text("请检查。"), .text(patch), .text(patch)])
        let result = await pipeline(client).process(request("请核对。", .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 3)
    }

    func testContextPayloadDoesNotExposeRawNearbyOrRecentInputFacts() throws {
        let context = WritingContext(scene: .chat, level: .nearbyText, safety: .unknown,
                                     selectedText: "不应读取的选中文字", textBeforeCursor: "不应读取的正文",
                                     recentMuseInputs: ["已授权的同应用近期输入"])
        let payload = try VoicePolishEditingPrompts.payload(for: request("你好", .light, context: context))
        XCTAssertFalse(payload.contains("不应读取"))
        XCTAssertFalse(payload.contains("已授权的同应用近期输入"))
    }

    func testCancelledAndTimedOutLightCallsNeverStartAnotherRoute() async {
        let client = EditingTestClient([.delay(.seconds(5), #"{"edits":[]}"#)])
        let result = await VoicePolishPipeline(client: client, config: config,
                                               totalTimeout: .milliseconds(30)).process(request("你好", .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 1)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testTruncatedGenerationIsNeverPolishSuccess() async {
        let client = EditingTestClient([.truncated])
        let result = await pipeline(client).process(request("请保留全部内容。", .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.abnormalLength))
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testDiffIncludesSeparatedOmissionsAndAdditions() {
        let diff = VoicePolishTextChange.between("先检查文件，再发送。", "先发送文件，再检查。")
        XCTAssertFalse(diff.isEmpty)
        XCTAssertTrue(diff.contains { !$0.removed.isEmpty })
        XCTAssertTrue(diff.contains { !$0.inserted.isEmpty })
        XCTAssertEqual(VoicePolishTextChange.between("完全相同", "完全相同"), [])
        XCTAssertEqual(VoicePolishTextChange.between("原文", ""), [.init(removed: "原文", inserted: "")])
    }

    private func pipeline(_ client: EditingTestClient) -> VoicePolishPipeline {
        VoicePolishPipeline(client: client, config: config)
    }

    private func request(_ source: String, _ mode: VoicePolishQualityMode,
                         context: WritingContext = WritingContext(scene: .workChat)) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(providerFinalText: source,
                                      segments: [RecognitionSegment(id: "s1", text: source, startTimeMs: nil,
                                                                     endTimeMs: nil, confidence: nil, isFinal: true)],
                                      durationMs: 1_000, provider: .volcano),
            context: context, preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: mode
        )
    }
}

private actor EditingTestClient: LLMClient {
    enum Step: Sendable { case text(String), delay(Duration, String), truncated }
    private var steps: [Step]
    private(set) var requests: [LLMRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw LLMError.emptyResponse(nil) }
        switch steps.removeFirst() {
        case .text(let text): return LLMResponse(text: text, model: config.model)
        case .delay(let duration, let text):
            try await Task.sleep(for: duration)
            return LLMResponse(text: text, model: config.model)
        case .truncated: throw LLMError.truncatedResponse(10)
        }
    }
    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }
    func warmUp(baseURL: String) async {}
}
