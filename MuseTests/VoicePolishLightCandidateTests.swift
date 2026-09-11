import XCTest
@testable import Muse

/// 固定候选及原文证据验证 v10 控制流，不代替真实模型的保真判读。
final class VoicePolishLightCandidateTests: XCTestCase {
    func testStrictWholeSourceMechanicalProofPreservesUnicodeParagraphsAndTechnicalTokens() throws {
        for (source, target) in [
            ("今天先核对明天发送", "今天先核对，明天发送。"),
            ("👨‍👩‍👧‍👦先看👍🏽\n再确认", "👨‍👩‍👧‍👦先看👍🏽。\n再确认。"),
            ("请运行swift test", "请运行 swift test。"),
            ("打开main点swift", "打开 main.swift。")
        ] {
            let result = try VoicePolishTextEditor.applyingUnreviewedMechanicalChanges(from: source, to: target)
            XCTAssertTrue(result.utf8.elementsEqual(target.utf8))
        }
        for (source, target) in [
            ("我我明天到", "我明天到。"), ("唔，我去。", "我去。"), ("呃，我去。", "我去。"),
            ("请按装软件", "请安装软件。"), ("先检查\n再发送", "先检查，再发送。"),
            ("运行 foo_bar", "运行 foobar"), ("连接10:45", "连接1045")
        ] {
            XCTAssertThrowsError(try VoicePolishTextEditor.applyingUnreviewedMechanicalChanges(from: source, to: target), source)
        }
    }

    func testThousandCharacterBoundedUnchangedAndPunctuationCandidatesStayOneCall() async {
        let unit = "先核对原始资料再记录原因和限制"
        let source = String(repeating: unit, count: 50)
        let punctuated = String(repeating: "先核对原始资料，再记录原因和限制。", count: 50)
        XCTAssertLessThanOrEqual(max(source.count, punctuated.count), 1_000)
        for target in [source, punctuated] {
            let (result, calls) = await run(source, [candidate(target)])
            XCTAssertFalse(result.usedFallback)
            XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testLongMechanicalFillerDeletionDoesNotUseRecursiveCallStack() async {
        let prefix = String(repeating: "先核对原始资料，再记录原因和限制。", count: 45)
        let source = prefix + "嗯，请继续核对。"
        let target = prefix + "请继续核对。"
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let (result, calls) = await run(source, [candidate(target)])
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(calls.count, 1)
    }

    func testLongSemanticResidualStillRejectsTheWholeCandidate() async {
        let prefix = String(repeating: "先核对原始资料，再记录原因和限制。", count: 45)
        let source = prefix + "请按装软件。"
        let target = prefix + "请安装软件。"
        XCTAssertLessThanOrEqual(source.count, 1_000)
        let (result, calls) = await run(source, [candidate(target), review(target)])
        assertFailure(result, source: source, calls: calls, count: 2, repairs: 0, code: .planIntegrityFailure)
    }

    func testIterativeLongMatchingPreservesFillerBudgetAndReviewPermission() throws {
        let prefix = String(repeating: "先核对原始资料，再记录原因和限制。", count: 45)
        let target = prefix + "请继续核对。"
        let six = prefix + "嗯嗯嗯嗯嗯嗯，请继续核对。"
        let seven = prefix + "嗯嗯嗯嗯嗯嗯嗯，请继续核对。"
        XCTAssertLessThanOrEqual(seven.count, 1_000)
        XCTAssertEqual(try VoicePolishTextEditor.applyingUnreviewedMechanicalChanges(from: six, to: target), target)
        XCTAssertThrowsError(try VoicePolishTextEditor.applyingUnreviewedMechanicalChanges(from: seven, to: target))
        let needsReview = prefix + "呃，请继续核对。"
        XCTAssertThrowsError(try VoicePolishTextEditor.applyingUnreviewedMechanicalChanges(from: needsReview, to: target))
        XCTAssertEqual(try VoicePolishTextEditor.apply([
            .init(before: needsReview, after: target, kind: .punctuation)
        ], to: needsReview, source: needsReview, mode: .light), target)
    }

    func testStutterAndAmbiguousFillersCannotSilentlyUseOneCall() async {
        for (source, target) in [("我我明天到", "我明天到。"), ("唔，我去。", "我去。"), ("呃，我去。", "我去。")] {
            let (result, calls) = await run(source, [candidate(target), review(nil)])
            assertFailure(result, source: source, calls: calls, count: 2, repairs: 0, code: .semanticDecisionUnverified)
        }
    }

    func testImmutableSourceRiskForcesReviewEvenWhenCandidateIsIdentical() async {
        for source in ["不对，日期还待确认。", "请同事不要改由阿宁。", "我补一句，先保留原因。"] {
            let (result, calls) = await run(source, [candidate(source), review(source)])
            XCTAssertFalse(result.usedFallback)
            XCTAssertEqual(result.text, source)
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(result.repairAttemptCount, 0)
        }
    }

    func testReviewEditsAnchorOriginalSourceInsteadOfCandidate() async {
        let source = "请按装软件马上检查"
        let target = "请安装软件，马上检查。"
        let edit = VoicePolishTextEdit(before: "按装", after: "安装", kind: .word)
        let (good, calls) = await run(source, [candidate(target), review(target, [edit])])
        XCTAssertFalse(good.usedFallback)
        XCTAssertTrue(good.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(good.repairAttemptCount, 0, "首稿已包含修改，复核给出证据不等于修复首稿")
        let wrongAnchor = VoicePolishTextEdit(before: "安装", after: "安装", kind: .word)
        let (bad, failedCalls) = await run(source, [candidate(target), review(target, [wrongAnchor])])
        assertFailure(bad, source: source, calls: failedCalls, count: 2, repairs: 0, code: .planIntegrityFailure)
    }

    func testResidualUnstatedWordCorrectionFailsWholeCandidate() async {
        let source = "请按装软件并从新检查。"
        let target = "请安装软件并重新检查。"
        let (result, calls) = await run(source, [candidate(target), review(target, [
            .init(before: "按装", after: "安装", kind: .word)
        ])])
        assertFailure(result, source: source, calls: calls, count: 2, repairs: 0, code: .planIntegrityFailure)
        XCTAssertNotEqual(result.text, "请安装软件并从新检查。", "不得交付部分通过的修改")
    }

    func testResidualStutterCannotHideBehindReviewedMechanicalPermission() async {
        let source = "我我去按装软件。"
        let target = "我去安装软件。"
        let (result, calls) = await run(source, [candidate(target), review(target, [
            .init(before: "按装", after: "安装", kind: .word)
        ])])
        assertFailure(result, source: source, calls: calls, count: 2, repairs: 0, code: .planIntegrityFailure)
    }

    func testOriginalSourceStutterEvidenceAllowsSameCandidateAfterReview() async {
        let source = "我我去按装软件。"
        let target = "我去安装软件。"
        let (result, calls) = await run(source, [candidate(target), review(target, [
            .init(before: "我我去", after: "我去", kind: .stutter),
            .init(before: "按装", after: "安装", kind: .word)
        ])])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, target)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testRepairHasOneFinalConfirmationWithActualSourceDraftAndChanges() async throws {
        let source = "我补一句，请按装软件。"
        let target = "我补一句，请安装软件。"
        let (result, calls) = await run(source, [candidate(source), review(target, [
            .init(before: "按装", after: "安装", kind: .word)
        ]), #"{"approved":true}"#])
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(result.llmAttemptCount, 3)
        XCTAssertEqual(result.repairAttemptCount, 1)
        XCTAssertEqual(calls.map(\.task), [.voicePolishFast, .voicePolishAnalyze, .voicePolishAnalyze])
        guard calls.count == 3 else { return }
        let second = try payload(calls[1]); let third = try payload(calls[2])
        XCTAssertEqual(second["draft_text"] as? String, source)
        XCTAssertEqual(third["canonical_text"] as? String, source)
        XCTAssertEqual(third["draft_text"] as? String, target)
        XCTAssertTrue((second["changes"] as? [[String: Any]])?.isEmpty == true)
        let changes = try XCTUnwrap(third["changes"] as? [[String: String]])
        XCTAssertTrue(changes.contains { $0["removed"] == "按" && $0["inserted"] == "安" })
        XCTAssertTrue(calls[2].system?.contains("approved") == true)
        XCTAssertTrue(calls.allSatisfy { !$0.user.contains("layout_segments") })
    }

    func testExplicitNullRefusalNeverCountsRepairOrDeliversInitialCandidate() async {
        let source = "请按装软件。"
        let (result, calls) = await run(source, [candidate("请安装软件。"), review(nil, [
            .init(before: "按装", after: "安装", kind: .word)
        ]), #"{"approved":true}"#])
        assertFailure(result, source: source, calls: calls, count: 2, repairs: 0, code: .semanticDecisionUnverified)
    }

    func testChangedInvalidRepairRecordsAttemptBeforePermissionsRejectIt() async {
        let source = "我补一句，给同事的任务是先核对。"
        for kind in [VoicePolishTextEdit.Kind.directive, .content] {
            let (result, calls) = await run(source, [candidate(source), review("先核对。", [
                .init(before: "我补一句，给同事的任务是", after: "", kind: kind)
            ])])
            assertFailure(result, source: source, calls: calls, count: 2, repairs: 1, code: .planIntegrityFailure)
        }
    }

    func testChangedTargetWithMissingSemanticEvidenceRecordsFailedRepair() async {
        let source = "我补一句，请按装软件。"
        let (result, calls) = await run(source, [candidate(source), review("我补一句，请安装软件。")])
        assertFailure(result, source: source, calls: calls, count: 2, repairs: 1, code: .planIntegrityFailure)
    }

    func testFalseOrInvalidThirdResponseCannotStartFourthCall() async {
        let source = "我补一句，请按装软件。"
        let target = "我补一句，请安装软件。"
        for (last, code) in [(#"{"approved":false}"#, VoicePolishValidationCode.semanticDecisionUnverified),
                             (#"{"approved":true,"text":"另稿"}"#, .invalidStructuredResponse),
                             (#"{"edits":[]}"#, .invalidStructuredResponse)] {
            let (result, calls) = await run(source, [candidate(source), review(target, [
                .init(before: "按装", after: "安装", kind: .word)
            ]), last, #"{"approved":true}"#])
            assertFailure(result, source: source, calls: calls, count: 3, repairs: 1, code: code)
        }
    }

    func testReviewMayRejectBadCandidateAndReturnCorrectedOriginalWithConfirmation() async {
        let source = "请检查软件。"
        let (result, calls) = await run(source, [candidate("请卸载软件。"), review(source), #"{"approved":true}"#])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(result.repairAttemptCount, 1)
    }

    func testChangedPunctuationTargetIsConfirmedAndNeverOverwrittenByFirstCandidate() async {
        let source = "不对先别执行等确认"
        let initial = "不对，先别执行，等确认。"
        let target = "不对。先别执行，等确认。"
        let (result, calls) = await run(source, [candidate(initial), review(target), #"{"approved":true}"#])
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(result.repairAttemptCount, 1)
    }

    func testRepeatedAnchorsFailAndExplicitUnchangedContextDisambiguates() async {
        let source = "先按装甲，再按装乙。"
        let target = "先安装甲，再按装乙。"
        let (bad, badCalls) = await run(source, [candidate(target), review(target, [
            .init(before: "按装", after: "安装", kind: .word)
        ])])
        assertFailure(bad, source: source, calls: badCalls, count: 2, repairs: 0, code: .planIntegrityFailure)
        let (good, goodCalls) = await run(source, [candidate(target), review(target, [
            .init(before: "先按装甲", after: "先安装甲", kind: .word)
        ])])
        XCTAssertFalse(good.usedFallback)
        XCTAssertEqual(good.text, target)
        XCTAssertEqual(goodCalls.count, 2)
    }

    func testEmojiSourceAnchorPreservesExactFinalUTF8() async {
        let source = "👨‍👩‍👧‍👦请按装👍🏽"
        let target = "👨‍👩‍👧‍👦请安装👍🏽。"
        let (result, calls) = await run(source, [candidate(target), review(target, [
            .init(before: "按装", after: "安装", kind: .word)
        ])])
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
        XCTAssertEqual(calls.count, 2)
    }

    func testLateCorrectionRequiresOriginalEvidenceAndRetainsReason() async {
        let source = "阿文负责复查。其他内容先保留。复查改由阿宁，阿文要出差。"
        let target = "阿宁负责复查。其他内容先保留。阿文要出差。"
        let edits: [VoicePolishTextEdit] = [
            .init(before: "阿文负责复查。", after: "阿宁负责复查。", kind: .correction, evidence: "复查改由阿宁，阿文要出差。"),
            .init(before: "复查改由阿宁，", after: "", kind: .correction)
        ]
        let (result, calls) = await run(source, [candidate(target), review(target, edits)])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, target)
        XCTAssertEqual(calls.count, 2)
        let missing = [VoicePolishTextEdit(before: "阿文负责复查。", after: "阿宁负责复查。", kind: .correction), edits[1]]
        let (bad, badCalls) = await run(source, [candidate(target), review(target, missing)])
        assertFailure(bad, source: source, calls: badCalls, count: 2, repairs: 0, code: .planIntegrityFailure)
    }

    func testCorrectionBudgetCannotBeBypassedByFullCandidate() async {
        let retained = "最终保留。"
        let source = String(repeating: "原先事项必须记录", count: 5) + "不对，" + retained
        let (result, calls) = await run(source, [candidate(retained), review(retained, [
            .init(before: source, after: retained, kind: .correction)
        ])])
        assertFailure(result, source: source, calls: calls, count: 2, repairs: 0, code: .planIntegrityFailure)
    }

    func testAllThreeResponseSchemasRejectWrongKeysTypesAndEmptyText() {
        for raw in [#"{"edits":[]}"#, #"{"text":null}"#, #"{"text":""}"#, #"{"text":1}"#,
                    #"{"text":"正文","edits":[]}"#, "not-json", "[]"] {
            assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightCandidate(raw) }
        }
        for raw in [#"{"text":"正文"}"#, #"{"edits":[]}"#, #"{"text":"","edits":[]}"#,
                    #"{"text":false,"edits":[]}"#, #"{"text":null,"edits":null}"#,
                    #"{"text":"正文","edits":[],"approved":true}"#,
                    #"{"text":null,"edits":[{"before":"甲","after":"乙","kind":"unknown"}]}"#] {
            assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightCandidateReview(raw) }
        }
        for raw in [#"{"approved":1}"#, #"{"approved":"true"}"#, #"{"approved":null}"#,
                    #"{"approved":true,"edits":[]}"#, "{}"] {
            assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightConfirmation(raw) }
        }
    }

    func testOldFirstProtocolAndMalformedReviewHaveNoRepairAttempts() async {
        let source = "不对，先核对。"
        let (first, firstCalls) = await run(source, [#"{"edits":[]}"#])
        assertFailure(first, source: source, calls: firstCalls, count: 1, repairs: 0, code: .invalidStructuredResponse)
        let (second, secondCalls) = await run(source, [candidate(source), #"{"text":"已改","edits":null}"#])
        assertFailure(second, source: source, calls: secondCalls, count: 2, repairs: 0, code: .invalidStructuredResponse)
    }

    func testUTF8DifferenceCannotUseSwiftCanonicalEqualityToSkipConfirmation() async {
        let source = "不对，가先保留。"
        let target = "不对，\u{1100}\u{1161}先保留。"
        XCTAssertEqual(source, target)
        XCTAssertFalse(source.utf8.elementsEqual(target.utf8))
        let (result, calls) = await run(source, [candidate(source), review(target), #"{"approved":true}"#])
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.repairAttemptCount, 1)
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(result.text.utf8.elementsEqual(target.utf8))
    }

    func testWhitespaceOnlyMechanicalCandidateStillFailsFinalContentGuard() async {
        let source = "。"
        let (result, calls) = await run(source, [candidate(" ")])
        assertFailure(result, source: source, calls: calls, count: 1, repairs: 0, code: .emptyOutput)
    }

    func testDuplicateRootNestedAndEscapedEquivalentKeysAreRejected() throws {
        for raw in [#"{"text":"甲","text":"乙"}"#, #"{"text":"甲","te\u0078t":"乙"}"#] {
            assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightCandidate(raw) }
        }
        for raw in [
            #"{"text":null,"text":"原文","edits":[]}"#,
            #"{"text":"原文","text":null,"edits":[]}"#,
            #"{"text":null,"te\u0078t":"原文","edits":[]}"#,
            #"{"text":"安装","edits":[{"before":"按装","before":"安装","after":"安装","kind":"word"}]}"#,
            #"{"text":"安装","edits":[{"before":"按装","after":"安装","kind":"word","k\u0069nd":"directive"}]}"#
        ] {
            assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightCandidateReview(raw) }
        }
        for raw in [#"{"approved":false,"approved":true}"#, #"{"approved":true,"approved":false}"#,
                    #"{"approved":false,"approv\u0065d":true}"#] {
            assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightConfirmation(raw) }
        }
        let quoted = "引号里的\"text\"、反斜杠\\和 emoji 👍🏽只是正文。"
        XCTAssertEqual(try VoicePolishEditingReview.decodeLightCandidate(candidate(quoted)), quoted)
    }

    func testUnpairedSurrogatesRejectAllTextLocationsButValidPairDecodes() throws {
        for escape in [#"\uD800"#, #"\uDC00"#] {
            assertDecodeFailure {
                _ = try VoicePolishEditingReview.decodeLightCandidate("{\"text\":\"" + escape + "\"}")
            }
            assertDecodeFailure {
                _ = try VoicePolishEditingReview.decodeLightCandidateReview("{\"text\":\"" + escape + "\",\"edits\":[]}")
            }
            assertDecodeFailure {
                _ = try VoicePolishEditingReview.decodeLightCandidateReview(
                    "{\"text\":null,\"edits\":[{\"before\":\"按装\",\"after\":\"" + escape + "\",\"kind\":\"word\"}]}")
            }
        }
        XCTAssertEqual(try VoicePolishEditingReview.decodeLightCandidate(#"{"text":"\uD83D\uDE00正文"}"#), "😀正文")
        XCTAssertEqual(try VoicePolishEditingReview.decodeLightCandidateReview(
            #"{"text":"\uD83D\uDE00正文","edits":[]}"#).text, "😀正文")
    }

    func testLightResponsesKeepByteAndEditCountLimits() throws {
        let edit = VoicePolishTextEdit(before: "按装", after: "安装", kind: .word)
        XCTAssertEqual(try VoicePolishEditingReview.decodeLightCandidateReview(
            review(nil, Array(repeating: edit, count: 128))).edits.count, 128)
        assertDecodeFailure {
            _ = try VoicePolishEditingReview.decodeLightCandidateReview(review(nil, Array(repeating: edit, count: 129)))
        }
        let padding = String(repeating: " ", count: VoicePolishOutputNormalizer.maximumResponseBytes)
        assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightCandidate(padding + candidate("正文")) }
        assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightCandidateReview(padding + review(nil)) }
        assertDecodeFailure { _ = try VoicePolishEditingReview.decodeLightConfirmation(padding + #"{"approved":true}"#) }
    }

    private func assertDecodeFailure(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertTrue($0 is VoicePolishEditingReviewError, file: file, line: line)
        }
    }

    private func assertFailure(_ result: VoicePolishResult, source: String, calls: [LLMRequest], count: Int,
                               repairs: Int, code: VoicePolishValidationCode,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.usedFallback, file: file, line: line)
        XCTAssertTrue(result.text.utf8.elementsEqual(source.utf8), file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, count, file: file, line: line)
        XCTAssertEqual(calls.count, count, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, repairs, file: file, line: line)
        XCTAssertTrue(result.validationCodes.contains(code), "\(result.validationCodes)", file: file, line: line)
    }

    private func candidate(_ text: String) -> String { json(["text": text]) }
    private func review(_ text: String?, _ edits: [VoicePolishTextEdit] = []) -> String {
        let values = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(edits))
        return json(["text": text as Any? ?? NSNull(), "edits": values])
    }
    private func json(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func payload(_ request: LLMRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any])
    }
    private func run(_ source: String, _ responses: [String]) async -> (VoicePolishResult, [LLMRequest]) {
        let client = LightCandidateClient(responses)
        let request = VoicePolishRequest(input: VoiceInputEnvelope(providerFinalText: source,
            segments: [.init(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil, confidence: nil, isFinal: true)],
            durationMs: 1_000, provider: .volcano), context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: ""), qualityMode: .light)
        let config = LLMConfig(apiKey: "test-only", model: "configured-model", baseURL: "https://example.invalid")
        let result = await VoicePolishPipeline(client: client, config: config).process(request)
        return (result, await client.requests)
    }
}

private actor LightCandidateClient: LLMClient {
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
