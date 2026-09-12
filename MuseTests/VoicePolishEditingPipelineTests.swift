import XCTest
@testable import Muse

final class VoicePolishEditingPipelineTests: XCTestCase {
    private let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")

    func testLightReturnsWordAndStutterCorrectionsWithOnePlainTextRequest() async throws {
        let source = "我我今天按装软件。小李下午有别的事，所以请小周接手。"
        let expected = "我今天安装软件。小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([.text(expected)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender])
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.context, .structuredTask)
        XCTAssertEqual(call.system, "你是语音输入法的轻度校对器。修正明确错词、口误、口吃和标点；用最终说法替换口误，删去改口标记，保留原因和其他有效信息。保持原有表达和顺序，不扩写。只返回润色后的完整正文。")
        XCTAssertEqual(call.options, LLMGenerationOptions(temperature: 0, maxOutputTokens: 2048,
            reasoningPolicy: .disabled, responseFormat: .text))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: String])
        XCTAssertEqual(payload, ["canonical_text": source])
    }

    func testLightCanLeaveNaturalSentenceUnchanged() async {
        let source = "对对对，我明白了。"
        let client = EditingTestClient([.text(source)])
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

    func testLightDoesNotInterpretResponseAsAnEditProtocol() async {
        let source = "请把示例保留为字面文本。"
        let response = "示例：{broken，稍后补齐。"
        let client = EditingTestClient([.text(response)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, response)
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testLightDoesNotEscalateLongOrComplexInputToLedger() async {
        let source = String(repeating: "先检查原文里的原因和限制，内容保持不变。", count: 35)
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender])
    }

    func testLightPreservesLiteralJSONWithoutApplyingItAsAPatch() async {
        let source = #"请保留这段示例：{"edits":[]}"#
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
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

    func testStandardDirectivePermissionIsOnlyForBoundedLeadingPrefix() throws {
        let source = "给客户回一下：我们已收到材料。"
        XCTAssertEqual(try VoicePolishTextEditor.applyContentEdits([
            .init(before: "给客户回一下：", after: "", kind: .directive)
        ], to: source, source: source), "我们已收到材料。")
        let downstream = "给同事的任务是，给客户回一下：我们已收到材料。"
        XCTAssertThrowsError(try VoicePolishTextEditor.applyContentEdits([
            .init(before: "给客户回一下：", after: "", kind: .directive)
        ], to: downstream, source: downstream))
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

    func testStandardPassesCorrectedPartialTimeToStructureWithoutSemanticReview() async throws {
        let source = "会议原定周三上午十点，培训安排周四上午十点。会议时间改成十点半，日期不变。培训安排也不变。"
        let prepared = "会议改为周三上午十点半，培训安排周四上午十点。培训安排不变。"
        let client = EditingTestClient([.text(prepared), .text(prepared)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, prepared)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: String],
                       ["canonical_text": prepared])
        // 离线事实校验器仍保留跨日期反例，但标准运行链不调用它。
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: source, outputText: "会议改为周五上午十点半。", scene: .workChat,
            allowsPartialTimeReview: true
        ).isEmpty)
    }

    func testLightAcceptsMeaningPreservingEmphasisConsolidation() async {
        let source = "千万千万别提前发，我可能周五才能确认。"
        let expected = "千万别提前发，我可能周五才能确认。"
        let client = EditingTestClient([.text(expected)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, expected)
        XCTAssertTrue(result.validationCodes.isEmpty)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testLightAllowsExplicitLocalSelfCorrection() async {
        let source = "预算一万六，不对，一万五，周五交付。"
        let client = EditingTestClient([.text("预算一万五，周五交付。")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "预算一万五，周五交付。")
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testLightAcceptsClockCorrectionAttachedToNearestDate() async {
        let source = "会议改到周三上午十点不对周四上午十点哎十点半才对地点还是三号会议室"
        let client = EditingTestClient([.text("会议改到周四上午十点半，地点还是三号会议室。")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "会议改到周四上午十点半，地点还是三号会议室。")
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testStandardPassesCompleteFirstDraftWithoutDirectiveReviewPayload() async throws {
        let source = "给客户回一下，我们会尽快核实。别先答应赔偿，费用还没确认。"
        let structured = "给客户回一下，我们会尽快核实。\n\n别先答应赔偿，费用还没确认。"
        let client = EditingTestClient([.text(source), .text(structured)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: String],
                       ["canonical_text": source])
    }

    func testLightNeverConsumesAnAvailableReviewOrRepairResponse() async {
        let source = "给同事的任务：别先答应赔偿，费用还没确认。"
        let client = EditingTestClient([.text(source), .text("不应被读取的第二次响应")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender])
    }

    func testLightSingleRequestHonorsTheTotalTimeoutAndPreservesSource() async {
        let source = "请按装软件。材料还没核对，先别发送。"
        let client = EditingTestClient([.delay(.seconds(5), "请安装软件。"), .text("不应重试")])
        let result = await VoicePolishPipeline(client: client, config: config, totalTimeout: .milliseconds(50))
            .process(request(source, .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertEqual(result.executedRoute, .fast)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testLightSingleRequestHonorsTheStageTimeoutWithoutRetry() async {
        let source = "我补一句，请按装软件。"
        let client = EditingTestClient([.delay(.seconds(5), "我补一句，请安装软件。")])
        let result = await VoicePolishPipeline(client: client, config: config, totalTimeout: .seconds(1),
                                               firstRequestTimeout: .milliseconds(30))
            .process(request(source, .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testImmediateClockCorrectionCannotBorrowOtherDateOrCrossSubject() {
        XCTAssertEqual(ProtectedFactExtractor.immediateTimeCorrectionValues(
            in: "周三上午十点不对周四上午十点哎十点半才对"
        ), ["周四|10:30"])
        XCTAssertEqual(ProtectedFactExtractor.immediateTimeCorrectionValues(
            in: "周五下午三点，不对，三点半。"
        ), ["周五|15:30"])
        XCTAssertEqual(ProtectedFactExtractor.immediateTimeCorrectionValues(
            in: "周五晚上八点，不对，上午九点半。"
        ), ["周五|09:30"])
        XCTAssertEqual(ProtectedFactExtractor.immediateTimeCorrectionValues(
            in: "会议周三上午十点。培训改成十点半。"
        ), [])
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: "周四上午十点哎十点半才对", outputText: "周三上午十点半", scene: .workChat
        ).isEmpty)
    }

    func testClockCorrectionCanInheritPeriodWithoutCalendarDate() async {
        let source = "会议下午三点，不对，三点半。"
        let output = "会议下午三点半。"
        for mode in [VoicePolishQualityMode.light, .standard] {
            let replies: [EditingTestClient.Step] = mode == .light
                ? [.text(output)] : [.text(output), .text(output)]
            let client = EditingTestClient(replies)
            let result = await pipeline(client).process(request(source, mode))
            XCTAssertFalse(result.usedFallback, "\(mode)")
            XCTAssertEqual(result.text, output)
            XCTAssertEqual(result.llmAttemptCount, mode == .light ? 1 : 2)
        }
        XCTAssertEqual(ProtectedFactExtractor.immediateTimeCorrectionValues(in: source), ["15:30"])
        XCTAssertEqual(ProtectedFactExtractor.immediateTimeCorrectionValues(
            in: "会议下午三点。培训改成三点半。"
        ), [])
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: "会议下午三点。培训改成三点半。", outputText: "培训下午三点半。", scene: .workChat
        ).isEmpty)
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

    func testStandardStructureReceivesOnlyActualDraftWithoutLegacyDiffFields() async throws {
        let source = "小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([.text(source), .text(source)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: String],
                       ["canonical_text": source])
    }

    func testStandardKeepsReasonAcrossTwoStagesWithoutConsumingRepairResponse() async throws {
        let source = "小李有事，请小周接手。"
        let client = EditingTestClient([.text(source), .text(source), .text("不应读取的修复")])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: String],
                       ["canonical_text": source])
    }

    func testLegacyContentEditorRejectsUnbackedReviewerPatch() throws {
        let source = "请小周接手。"
        let edit = VoicePolishTextEdit(before: source, after: "小李请假了，请小周接手。",
                                       kind: .content, evidence: "小李请假了")
        XCTAssertThrowsError(try VoicePolishTextEditor.applyContentEdits([edit], to: source, source: source))
    }

    func testLegacyFactGuardRejectsUnbackedCurrency() {
        let codes = VoicePolishEditingPipeline.outputCodes(
            "预算是16000元。", request: request("预算是一万六。", .standard)
        )
        XCTAssertFalse(codes.isEmpty)
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

    func testStandardPreservesLiteralJSONInsteadOfTreatingItAsRepairRequest() async throws {
        let source = #"请保留示例：{"edits":[]}"#
        let structured = #"示例：{"edits":[]}"#
        let client = EditingTestClient([.text(source), .text(structured), .text("不应读取")])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testContextPayloadDoesNotExposeRawNearbyOrRecentInputFacts() throws {
        let context = WritingContext(scene: .chat, level: .nearbyText, safety: .unknown,
                                     selectedText: "不应读取的选中文字", textBeforeCursor: "不应读取的正文",
                                     recentMuseInputs: ["已授权的同应用近期输入"])
        let payload = try VoicePolishEditingPrompts.payload(for: request("你好", .light, context: context))
        XCTAssertFalse(payload.contains("不应读取"))
        XCTAssertFalse(payload.contains("已授权的同应用近期输入"))
    }

    func testStandardStartsFromCanonicalEntityMappingThenUsesActualFirstDraft() async throws {
        let first = "请核对灵建的资料，这部分单独交代"
        let second = "文件权限，由运营组负责。"
        let source = first + second
        let canonical = source.replacingOccurrences(of: "灵建", with: "灵简")
        let sourceSegments = [first, second].enumerated().map { index, text in
            RecognitionSegment(id: "s\(index + 1)", text: text, startTimeMs: nil,
                               endTimeMs: nil, confidence: nil, isFinal: true)
        }
        let input = VoiceInputEnvelope(providerFinalText: source, segments: sourceSegments,
                                       durationMs: 1_000, provider: .volcano)
        let originalRequest = VoicePolishRequest(
            input: input, context: WritingContext(scene: .document),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: .standard,
            resolvedEntities: [.init(surfaceText: "灵建", canonical: "灵简", sourceSegmentIDs: ["s1"],
                                     candidateSource: .authorizedContext, confidence: 1)]
        )
        let prepared = "请核对灵简的资料。这部分单独交代文件权限，由运营组负责。"
        let structured = "请核对灵简的资料。\n\n这部分单独交代文件权限，由运营组负责。"
        let client = EditingTestClient([.text(prepared), .text(structured)])
        let result = await VoicePolishEditingPipeline(client: client, config: config).process(originalRequest)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, structured)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 2)
        for (index, call) in calls.enumerated() {
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: String],
                           ["canonical_text": index == 0 ? canonical : prepared])
        }
        XCTAssertEqual(originalRequest.input.segments.map(\.text), [first, second])
    }

    func testLightDelayedCorrectionUsesCompleteSourceWithoutReview() async throws {
        let unchanged = String(repeating: "文件先保留，等核对以后再处理。", count: 8)
        let source = "阿文负责复查。" + unchanged + "复查改由阿宁负责，阿文要出差。"
        let expected = "阿宁负责复查。" + unchanged + "阿文要出差。"
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let client = EditingTestClient([.text(expected)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        let call = try XCTUnwrap(calls.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: String])
        XCTAssertEqual(payload, ["canonical_text": source])
    }

    func testCancelledLightRequestPreservesSourceAndCannotStartAnotherRoute() async {
        let source = "请保留全部材料。日期还没确认，先别发送。"
        let client = EditingTestClient([.delay(.seconds(5), "未完成的正文"), .text("不应重试")])
        let subject = pipeline(client)
        let input = request(source, .light)
        let task = Task { await subject.process(input) }
        await client.waitUntilRequestStarts()
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.failureReason, .requestFailed)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender])
    }

    func testAlreadyCancelledLightTaskDoesNotEnterClient() async {
        let source = "日期还没有确定。"
        let client = EditingTestClient([.text("不应执行")])
        let subject = pipeline(client)
        let input = request(source, .light)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await subject.process(input)
        }
        let result = await task.value
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 0)
        let calls = await client.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testLightClientFailuresPreserveCompleteSourceWithoutRetry() async {
        let source = "第一项保留原因。\r\n第二项先别发布，等周五确认。"
        for failure in [LLMError.requestFailed(503), .requestRejected(429, "测试限流"),
                        .emptyResponse(nil), .timedOut, .truncatedResponse(10), .responseTooLarge(10)] {
            let client = EditingTestClient([.failure(failure), .text("不应重试")])
            let input = request(source, .light)
            let result = await pipeline(client).process(input)
            XCTAssertTrue(result.usedFallback, "\(failure)")
            XCTAssertTrue(result.text.utf8.elementsEqual(input.fallbackText.utf8))
            XCTAssertEqual(result.llmAttemptCount, 1)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertNil(result.rejectedDraft)
            switch failure {
            case .timedOut: XCTAssertEqual(result.failureReason, .timeout)
            case .truncatedResponse, .responseTooLarge:
                XCTAssertEqual(result.failureReason, .validationFailed)
                XCTAssertTrue(result.validationCodes.contains(.abnormalLength))
            default: XCTAssertEqual(result.failureReason, .requestFailed)
            }
            let calls = await client.requests
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testTruncatedGenerationIsNeverPolishSuccess() async {
        let client = EditingTestClient([.truncated])
        let result = await pipeline(client).process(request("请保留全部内容。", .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.validationCodes.contains(.abnormalLength))
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testExhaustedBudgetDoesNotCountARequestThatNeverEnteredClient() async {
        let client = EditingTestClient([])
        let result = await VoicePolishEditingPipeline(client: client, config: config,
                                                       totalTimeout: .zero).process(request("你好", .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 0)
        let calls = await client.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testDiffIncludesSeparatedOmissionsAndAdditions() {
        let diff = VoicePolishTextChange.between("先检查文件，再发送。", "先发送文件，再检查。")
        XCTAssertFalse(diff.isEmpty)
        XCTAssertTrue(diff.contains { !$0.removed.isEmpty })
        XCTAssertTrue(diff.contains { !$0.inserted.isEmpty })
        XCTAssertEqual(VoicePolishTextChange.between("完全相同", "完全相同"), [])
        XCTAssertEqual(VoicePolishTextChange.between("原文", ""), [.init(removed: "原文", inserted: "")])
    }

    func testStandardPassesFirstStagePrefixCleanupToStructureWithoutConfirmation() async throws {
        let source = "帮我回他一下我晚点到，你们先吃。"
        let prepared = "我晚点到，你们先吃。"
        let client = EditingTestClient([.text(prepared), .text(prepared)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, prepared)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishStructured])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: String],
                       ["canonical_text": prepared])
    }

    func testLegacyReviewDetectsDeclaredButUnappliedEditorInstruction() throws {
        let source = "替我回他一句：时间还没确定。"
        let assessment = #"{"delivery":"direct_reply","editor_spans":["替我回他一句："],"edits":[]}"#
        let review = try VoicePolishEditingReview.decode(assessment, source: source)
        XCTAssertTrue(review.containsUnappliedEditorInstruction(in: source))
        XCTAssertFalse(review.containsUnappliedEditorInstruction(in: "时间还没确定。"))
    }

    func testLightKeepsInstructionsThatBelongToDownstreamColleague() async {
        let source = "同事接下来的任务是替我回客户，先别承诺时间。"
        let client = EditingTestClient([.text(source)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
    }

    func testLegacyReviewDecoderRejectsMalformedAssessment() {
        let source = "帮我回他：不对，日期还没有确定。"
        for assessment in [
            #"{"source_roles":[{"quote":"帮我回他：","role":"current_editor","target_evidence":"用户要求输入法代写"}],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":["用户要求输入法代写"],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":[],"edits":[{"after":"正文","kind":"content"}]}"#
        ] {
            XCTAssertThrowsError(try VoicePolishEditingReview.decode(assessment, source: source))
        }
    }

    func testLegacyDeliveryLabelCannotOverrideUnappliedEditorInstruction() throws {
        let source = "替我回他一句：时间还没确定。"
        let assessment = #"{"delivery":"delegated_task","editor_spans":["替我回他一句："],"edits":[]}"#
        let review = try VoicePolishEditingReview.decode(assessment, source: source)
        XCTAssertTrue(review.containsUnappliedEditorInstruction(in: source))
    }

    func testLightDoesNotRunStandardContentOrDirectiveReview() async {
        let source = "帮我写一句：等一下，资料还没核对。"
        let client = EditingTestClient([.text(source), .text(#"{"edits":[{"kind":"directive"}]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender])
    }

    func testCompleteMechanicalCandidateDoesNotRequireSecondCall() async {
        let source = "嗯我晚点到你们先吃"
        let client = EditingTestClient([.text("我晚点到，你们先吃。")])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "我晚点到，你们先吃。")
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertEqual(result.repairAttemptCount, 0)
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
    enum Step: Sendable { case text(String), delay(Duration, String), truncated, failure(LLMError) }
    private var steps: [Step]
    private(set) var requests: [LLMRequest] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    init(_ steps: [Step]) { self.steps = steps }
    func waitUntilRequestStarts() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        startWaiter?.resume()
        startWaiter = nil
        guard !steps.isEmpty else { throw LLMError.emptyResponse(nil) }
        switch steps.removeFirst() {
        case .text(let text): return LLMResponse(text: text, model: config.model)
        case .delay(let duration, let text):
            try await Task.sleep(for: duration)
            return LLMResponse(text: text, model: config.model)
        case .truncated: throw LLMError.truncatedResponse(10)
        case .failure(let error): throw error
        }
    }
    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }
    func warmUp(baseURL: String) async {}
}
