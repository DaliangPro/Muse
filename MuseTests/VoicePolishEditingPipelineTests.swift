import XCTest
@testable import Muse

final class VoicePolishEditingPipelineTests: XCTestCase {
    private let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")

    func testLightAppliesOnlyAnchoredEditsAndKeepsUntouchedReason() async {
        let source = "我我今天按装软件。小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([
            .text(#"{"edits":[{"before":"我我今天","after":"我今天","kind":"stutter"},{"before":"按装","after":"安装","kind":"word"}]}"#),
            .review(#"{"edits":[]}"#)
        ])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "我今天安装软件。小李下午有别的事，所以请小周接手。")
        XCTAssertEqual(result.llmAttemptCount, 2)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze])
        XCTAssertEqual(calls.first?.context, .structuredTask)
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
        let patch = #"{"edits":[{"before":"会议原定周三上午十点","after":"会议原定周三上午十点半","kind":"correction","evidence":"会议时间改成十点半，日期不变。"}]}"#
        let good = source.replacingOccurrences(of: "会议原定周三上午十点", with: "会议原定周三上午十点半")
        let client = EditingTestClient([.text(patch), .review(#"{"edits":[]}"#), .review(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, good)
        XCTAssertEqual(result.llmAttemptCount, 3)
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: source, outputText: "会议改为周五上午十点半。", scene: .workChat,
            allowsPartialTimeReview: true
        ).isEmpty)
        let wrong = #"{"edits":[{"before":"会议原定周三上午十点","after":"会议原定周四上午十点半","kind":"correction","evidence":"会议时间改成十点半，日期不变。"}]}"#
        let repair = #"{"edits":[{"before":"会议原定周四上午十点半","after":"会议原定周三上午十点半","kind":"word"}]}"#
        let correctionClient = EditingTestClient([.text(wrong), .review(repair), .review(#"{"edits":[]}"#)])
        let corrected = await pipeline(correctionClient).process(request(source, .standard))
        // 跨日期补丁缺少支持最终值的连续来源，必须在首稿阶段拒绝。
        XCTAssertTrue(corrected.usedFallback)
        XCTAssertEqual(corrected.llmAttemptCount, 1)
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
        let client = EditingTestClient([.text(#"{"edits":[{"before":"一万六，不对，一万五","after":"一万五","kind":"correction"}]}"#), .review(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "预算一万五，周五交付。")
    }

    func testLightAcceptsClockCorrectionAttachedToNearestDate() async {
        let source = "会议改到周三上午十点不对周四上午十点哎十点半才对地点还是三号会议室"
        let client = EditingTestClient([.text(#"{"edits":[{"before":"周三上午十点不对周四上午十点哎十点半才对","after":"周四上午十点半","kind":"correction"}]}"#), .review(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "会议改到周四上午十点半地点还是三号会议室")
        XCTAssertEqual(result.llmAttemptCount, 2)
    }

    func testLightInlineEditingInstructionMustPassReviewOfActualDraft() async throws {
        let source = "给客户回一下，我们会尽快核实。别先答应赔偿，费用还没确认。"
        let patch = #"{"edits":[{"before":"给客户回一下，","after":"","kind":"directive"},{"before":"别先答应赔偿，","after":"","kind":"directive"}]}"#
        let client = EditingTestClient([.text(patch), .review(#"{"edits":[]}"#)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "我们会尽快核实。费用还没确认。")
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: Any])
        XCTAssertEqual(payload["canonical_text"] as? String, source)
        XCTAssertEqual(payload["draft_text"] as? String, result.text)
        XCTAssertNotNil(payload["changes"] as? [[String: String]])
        XCTAssertEqual(payload["mode"] as? String, "light")
    }

    func testLightCannotDeliverUnconfirmedDeletionOrExecuteStandardReviewRepair() async {
        let source = "给同事的任务：别先答应赔偿，费用还没确认。"
        let patch = #"{"edits":[{"before":"别先答应赔偿，","after":"","kind":"directive"}]}"#
        let refusal = #"{"edits":[{"before":"费用还没确认。","after":"别先答应赔偿，费用还没确认。","kind":"content","evidence":"别先答应赔偿，费用还没确认。"}]}"#
        let scenarios: [[EditingTestClient.Step]] = [[.text(patch)], [.text(patch), .review(refusal)]]
        for steps in scenarios {
            let client = EditingTestClient(steps)
            let result = await pipeline(client).process(request(source, .light))
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(result.llmAttemptCount, 2)
            XCTAssertEqual(result.repairAttemptCount, steps.count > 1 ? 1 : 0)
            let calls = await client.requests
            XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze])
        }
    }

    func testLightSemanticReviewUsesRemainingSharedTimeout() async {
        let patch = #"{"edits":[{"before":"按装","after":"安装","kind":"word"}]}"#
        let client = EditingTestClient([.text(patch), .delay(.seconds(5), #"{"edits":[]}"#)])
        let result = await VoicePolishPipeline(client: client, config: config, totalTimeout: .milliseconds(50))
            .process(request("请按装软件。", .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.executedRoute, .fast)
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
        let patch = #"{"edits":[{"before":"下午三点，不对，三点半","after":"下午三点半","kind":"correction"}]}"#
        for mode in [VoicePolishQualityMode.light, .standard] {
            var replies: [EditingTestClient.Step] = [.text(patch), .review(#"{"edits":[]}"#)]
            if mode == .standard { replies.append(.review(#"{"edits":[]}"#)) }
            let client = EditingTestClient(replies)
            let result = await pipeline(client).process(request(source, mode))
            XCTAssertFalse(result.usedFallback, "\(mode)")
            XCTAssertEqual(result.text, output)
            XCTAssertEqual(result.llmAttemptCount, mode == .light ? 2 : 3)
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

    func testStandardReviewsActualDraftWithFullSourceAndComputedDeletions() async throws {
        let source = "小李下午有别的事，所以请小周接手。"
        let client = EditingTestClient([.text(#"{"edits":[]}"#), .review(#"{"edits":[]}"#)])
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
        let source = "小李有事，请小周接手。"
        let client = EditingTestClient([
            .text(#"{"edits":[{"before":"小李有事，","after":"","kind":"directive"}]}"#),
            .review(#"{"edits":[{"before":"请小周","after":"小李有事，请小周","kind":"word"}]}"#),
            .review(#"{"edits":[]}"#)
        ])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 3)
        let calls = await client.requests
        let firstReview = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: Any])
        let changes = try XCTUnwrap(firstReview["changes"] as? [[String: String]])
        XCTAssertTrue(changes.compactMap { $0["removed"] }.joined().contains("小李有事"))
        let confirmation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[2].user.utf8)) as? [String: Any])
        XCTAssertEqual(confirmation["draft_text"] as? String, source)
        XCTAssertEqual(confirmation["layout_segments"] as? [[String: String]], [["id": "c1", "text": source]])
    }

    func testStandardRejectsUnbackedReviewerPatch() async {
        let source = "请小周接手。"
        let client = EditingTestClient([
            .text(#"{"edits":[]}"#),
            .review(#"{"edits":[{"before":"请小周接手。","after":"小李请假了，请小周接手。","kind":"content","evidence":"小李请假了"}]}"#)
        ])
        let result = await pipeline(client).process(request(source, .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
    }

    func testStandardCannotAcceptUnbackedCurrencyEvenWhenReviewerPasses() async {
        let client = EditingTestClient([.text(#"{"edits":[{"before":"一万六","after":"16000元","kind":"word"}]}"#), .review(#"{"edits":[]}"#)])
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
        let patch = #"{"edits":[{"before":"请检查。","after":"请核对。","kind":"word"}]}"#
        let more = #"{"edits":[{"before":"请核对。","after":"请检查。","kind":"word"}]}"#
        let client = EditingTestClient([.text(#"{"edits":[]}"#), .review(patch), .review(more)])
        let result = await pipeline(client).process(request("请检查。", .standard))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 3)
        XCTAssertEqual(result.repairAttemptCount, 1)
    }

    func testContextPayloadDoesNotExposeRawNearbyOrRecentInputFacts() throws {
        let context = WritingContext(scene: .chat, level: .nearbyText, safety: .unknown,
                                     selectedText: "不应读取的选中文字", textBeforeCursor: "不应读取的正文",
                                     recentMuseInputs: ["已授权的同应用近期输入"])
        let payload = try VoicePolishEditingPrompts.payload(for: request("你好", .light, context: context))
        XCTAssertFalse(payload.contains("不应读取"))
        XCTAssertFalse(payload.contains("已授权的同应用近期输入"))
    }

    func testEveryEditingStageKeepsSourceBoundariesAndCanonicalEntityMapping() async throws {
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
        let initial = "请核对灵简的资料，这部分交代。文件权限，由运营组负责。"
        let repaired = "请核对灵简的资料，这部分单独交代。文件权限，由运营组负责。"
        let edit = VoicePolishTextEdit(before: "这部分交代", after: "这部分单独交代", kind: .word)
        let repairJSON = String(decoding: try JSONEncoder().encode(["edits": [edit]]), as: UTF8.self)
        let initialJSON = #"{"edits":[{"before":"这部分单独交代","after":"这部分交代","kind":"directive"},{"before":"交代文件权限","after":"交代。文件权限","kind":"punctuation"}]}"#
        let client = EditingTestClient([.text(initialJSON), .review(repairJSON), .review(#"{"edits":[]}"#)])
        let result = await VoicePolishEditingPipeline(client: client, config: config).process(originalRequest)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repaired)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 3)
        for (index, call) in calls.enumerated() {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.user.utf8)) as? [String: Any])
            XCTAssertEqual(payload["schema_version"] as? Int, 8)
            XCTAssertEqual(payload["canonical_text"] as? String, canonical)
            XCTAssertEqual(payload["source_segments"] as? [[String: String]],
                           [["id": "s1", "text": first], ["id": "s2", "text": second]])
            XCTAssertEqual(payload["authorized_context"] as? [String], ["灵建 → 灵简"])
            XCTAssertEqual(payload["draft_text"] as? String, index == 0 ? nil : (index == 1 ? initial : repaired))
            if index == 0 {
                XCTAssertNil(payload["review_focus"])
                XCTAssertNil(payload["review_focus_total"])
            } else {
                let focus = try XCTUnwrap(payload["review_focus"] as? [[String: Any]])
                XCTAssertNotNil(payload["changes"])
                if index == 1 {
                    XCTAssertEqual(focus.count, 1)
                    XCTAssertEqual(payload["review_focus_total"] as? Int, 1)
                    XCTAssertTrue(try XCTUnwrap(focus.first?["source_context"] as? String)
                        .contains("这部分单独交代"))
                } else {
                    // 修后只多一个句号，终审不能沿用首稿的内容删除焦点。
                    XCTAssertTrue(focus.isEmpty)
                    XCTAssertEqual(payload["review_focus_total"] as? Int, 0)
                }
            }
        }
    }

    func testLightDelayedCorrectionRequiresActualDraftConfirmation() async throws {
        let unchanged = String(repeating: "文件先保留，等核对以后再处理。", count: 8)
        let source = "阿文负责复查。" + unchanged + "复查改由阿宁负责，阿文要出差。"
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let patch = #"{"edits":[{"before":"阿文负责复查。","after":"阿宁负责复查。","kind":"correction","evidence":"复查改由阿宁负责，阿文要出差。"}]}"#
        let expected = "阿宁负责复查。" + unchanged + "复查改由阿宁负责，阿文要出差。"
        for approves in [true, false] {
            let review = approves ? #"{"edits":[]}"# : #"{"edits":[{"before":"阿宁负责复查。","after":"阿文负责复查。","kind":"content","evidence":"阿文负责复查。"}]}"#
            let client = EditingTestClient([.text(patch), .review(review)])
            let result = await pipeline(client).process(request(source, .light))
            XCTAssertEqual(result.llmAttemptCount, 2)
            XCTAssertEqual(result.usedFallback, !approves)
            XCTAssertEqual(result.text, approves ? expected : source)
            let calls = await client.requests
            XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze])
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[1].user.utf8)) as? [String: Any])
            XCTAssertEqual(payload["draft_text"] as? String, expected)
            XCTAssertEqual(payload["canonical_text"] as? String, source)
        }
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

    func testLightEmptyPlanStillReviewsSourceAndCanRepairUnpunctuatedPrefix() async throws {
        let source = "帮我回他一下我晚点到，你们先吃。"
        let spans = #"["帮我回他一下"]"#
        let repair = #"{"delivery":"direct_reply","editor_spans":\#(spans),"edits":[{"before":"帮我回他一下我晚点到","after":"我晚点到","kind":"directive"}]}"#
        let confirmation = #"{"delivery":"direct_reply","editor_spans":\#(spans),"edits":[]}"#
        let client = EditingTestClient([.text(#"{"edits":[]}"#), .text(repair), .text(confirmation)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "我晚点到，你们先吃。")
        XCTAssertEqual(result.llmAttemptCount, 3)
        XCTAssertEqual(result.repairAttemptCount, 1)
        let calls = await client.requests
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze, .voicePolishAnalyze])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calls[2].user.utf8)) as? [String: Any])
        XCTAssertEqual(payload["canonical_text"] as? String, source)
        XCTAssertEqual(payload["draft_text"] as? String, result.text)
    }

    func testEmptyEditsCannotApproveDeclaredButUnappliedEditorInstruction() async {
        let source = "替我回他一句：时间还没确定。"
        let assessment = #"{"delivery":"direct_reply","editor_spans":["替我回他一句："],"edits":[]}"#
        for mode in [VoicePolishQualityMode.light, .standard] {
            let client = EditingTestClient([.text(#"{"edits":[]}"#), .text(assessment)])
            let result = await pipeline(client).process(request(source, mode))
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.llmAttemptCount, 2)
            XCTAssertEqual(result.repairAttemptCount, 0)
            XCTAssertTrue(result.validationCodes.contains(.planIntegrityFailure))
        }
    }

    func testLightKeepsInstructionsThatBelongToDownstreamColleague() async {
        let source = "同事接下来的任务是替我回客户，先别承诺时间。"
        let assessment = #"{"delivery":"delegated_task","editor_spans":[],"edits":[]}"#
        let client = EditingTestClient([.text(#"{"edits":[]}"#), .text(assessment)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 2)
    }

    func testMalformedReviewIsReportedBeforeAnyRepairAttempt() async {
        let source = "帮我回他：日期还没有确定。"
        for assessment in [
            #"{"source_roles":[{"quote":"帮我回他：","role":"current_editor","target_evidence":"用户要求输入法代写"}],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":["用户要求输入法代写"],"edits":[]}"#,
            #"{"delivery":"direct_reply","editor_spans":[],"edits":[{"after":"正文","kind":"content"}]}"#
        ] {
            for mode in [VoicePolishQualityMode.light, .standard] {
                let client = EditingTestClient([.text(#"{"edits":[]}"#), .text(assessment)])
                let result = await pipeline(client).process(request(source, mode))
                XCTAssertTrue(result.usedFallback)
                XCTAssertEqual(result.text, source)
                XCTAssertEqual(result.llmAttemptCount, 2)
                XCTAssertEqual(result.repairAttemptCount, 0)
                XCTAssertTrue(result.validationCodes.contains(.invalidStructuredResponse))
                XCTAssertFalse(result.validationCodes.contains(.planIntegrityFailure))
            }
        }
    }

    func testDeliveryLabelCannotOverrideUnappliedEditorInstruction() async {
        let source = "替我回他一句：时间还没确定。"
        let assessment = #"{"delivery":"delegated_task","editor_spans":["替我回他一句："],"edits":[]}"#
        let client = EditingTestClient([.text(#"{"edits":[]}"#), .text(assessment)])
        let result = await pipeline(client).process(request(source, .light))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.repairAttemptCount, 0)
        XCTAssertTrue(result.validationCodes.contains(.planIntegrityFailure))
    }

    func testLightReviewCannotUseStandardContentRewriteOrStartFourthCall() async {
        let source = "帮我写一句：资料还没核对。"
        let spans = #"["帮我写一句："]"#
        for kind in ["content", "directive"] {
            let repair = #"{"delivery":"direct_reply","editor_spans":\#(spans),"edits":[{"before":"帮我写一句：","after":"","kind":"\#(kind)","evidence":"帮我写一句："}]}"#
            let more = #"{"delivery":"other_or_uncertain","editor_spans":[],"edits":[{"before":"还没","after":"已经","kind":"word"}]}"#
            let client = EditingTestClient([.text(#"{"edits":[]}"#), .text(repair), .text(more)])
            let result = await pipeline(client).process(request(source, .light))
            XCTAssertTrue(result.usedFallback)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(result.llmAttemptCount, kind == "content" ? 2 : 3)
            XCTAssertEqual(result.repairAttemptCount, 1)
        }
    }

    func testMechanicalChangesDoNotRequireSecondCallBecauseModelNamedThemWord() async {
        let source = "嗯我晚点到你们先吃"
        let client = EditingTestClient([.text(#"{"edits":[{"before":"嗯我晚点到你们先吃","after":"我晚点到，你们先吃。","kind":"word"}]}"#)])
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
    enum Step: Sendable { case text(String), review(String), delay(Duration, String), truncated }
    private var steps: [Step]
    private(set) var requests: [LLMRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw LLMError.emptyResponse(nil) }
        switch steps.removeFirst() {
        case .text(let text): return LLMResponse(text: text, model: config.model)
        case .review(let edits):
            // 这些回归考察补丁与调用流程；默认布局逐项引用请求中的实际片段，专门的布局反例用原始 text 响应。
            var object = try JSONSerialization.jsonObject(with: Data(edits.utf8)) as! [String: Any]
            object["delivery"] = "other_or_uncertain"
            object["editor_spans"] = []
            let payload = try JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any]
            if let segments = payload?["layout_segments"] as? [[String: String]], object["layout"] == nil {
                let ids = segments.compactMap { $0["id"] }
                object["layout"] = (object["edits"] as? [Any])?.isEmpty == true
                    ? [["style": "paragraph", "segment_ids": ids]] : []
            }
            return LLMResponse(text: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), model: config.model)
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
