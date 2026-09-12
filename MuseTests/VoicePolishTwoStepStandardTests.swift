import Foundation
import XCTest
import os
@testable import Muse

final class VoicePolishTwoStepStandardTests: XCTestCase {
    private let config = LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1")

    func testStandardReusesLightRequestThenConsumesItsExactActualResponse() async throws {
        let source = "请用 Cloud Code 复查，小李负责。小李请假了，改成小王负责。"
        let initial = " \r\n请用 Claude Code 复查，小王负责。小李请假了。Cafe\u{301} 👩🏽‍💻\t "
        let final = "\n请用 Claude Code 复查。\r\n小王负责，小李请假了。Cafe\u{301} 👩🏽‍💻\n "
        let lightClient = TwoStepStandardClient([.text(initial), .text("不应调用")])
        let lightInput = request(source, mode: .light, correctsCloudCode: true)
        let lightResult = await pipeline(lightClient).process(lightInput)
        let lightCalls = await lightClient.requests
        let stages = OSAllocatedUnfairLock(initialState: [VoicePolishStage]())
        let standardClient = TwoStepStandardClient([.text(initial), .text(final), .text("不应复核")])
        let standardPipeline = VoicePolishEditingPipeline(client: standardClient, config: config) { stage in
            stages.withLock { $0.append(stage) }
        }

        let result = await standardPipeline.process(request(source, correctsCloudCode: true))
        let calls = await standardClient.requests

        XCTAssertEqual(lightCalls.count, 1)
        XCTAssertEqual(calls.count, 2)
        let first = try XCTUnwrap(calls.first)
        XCTAssertEqual(first, lightCalls.first)
        XCTAssertEqual(calls.map(\.task), [.voicePolishRender, .voicePolishStructured])
        XCTAssertEqual(try payload(first), ["canonical_text": lightInput.fallbackText])
        let second = try XCTUnwrap(calls.last)
        let actualSecondSource = try XCTUnwrap(payload(second)["canonical_text"])
        XCTAssertTrue(actualSecondSource.utf8.elementsEqual(initial.utf8))
        XCTAssertEqual(Set(try payload(second).keys), Set(["canonical_text"]))
        XCTAssertEqual(first.system, VoicePolishEditingPrompts.light)
        XCTAssertEqual(second.system, VoicePolishEditingPrompts.standard)
        XCTAssertEqual(stages.withLock { $0 }, [.polishing, .rendering])
        for call in calls {
            XCTAssertEqual(call.context, .structuredTask)
            XCTAssertEqual(call.options, LLMGenerationOptions(
                temperature: 0, maxOutputTokens: 2_048, reasoningPolicy: .disabled, responseFormat: .text
            ))
        }
        XCTAssertTrue(lightResult.text.utf8.elementsEqual(initial.utf8))
        XCTAssertTrue(result.text.utf8.elementsEqual(final.utf8))
        XCTAssertFalse(result.usedFallback)
        XCTAssertNil(result.failureReason)
        XCTAssertNil(result.rejectedDraft)
        XCTAssertTrue(result.validationCodes.isEmpty)
        XCTAssertEqual(result.detectedRoute, .structured)
        XCTAssertEqual(result.executedRoute, .structured)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testPromptsKeepAcceptedLightAndApprovedStructureWording() {
        XCTAssertEqual(VoicePolishEditingPrompts.version, 12)
        XCTAssertEqual(VoicePolishEditingPrompts.light,
            "你是语音输入法的轻度校对器。修正明确错词、口误、口吃和标点；用最终说法替换口误，删去改口标记，保留原因和其他有效信息。保持原有表达和顺序，不扩写。只返回润色后的完整正文。")
        XCTAssertEqual(VoicePolishEditingPrompts.standard,
            "你是语音输入法的文字编辑。修正明确错词、口误、口吃和标点；用最终说法替换口误，删去改口标记，保留原因和其他有效信息。把同一事项及其补充合在一起，再按事项分段或列点，保持原有口吻，不扩写。只返回润色后的完整正文。")
    }

    func testExplicitRequirementsOnlyEnterStructureStageWithoutChangingLightRequest() async throws {
        let source = "本周先整理客户反馈，再发测试报告。"
        let intermediate = "本周先整理客户反馈，再发测试报告。"
        let requirements = "请用简短段落。\n  保留英文术语 Cafe\u{301}。"
        let input = request(source, additionalRequirements: requirements)
        let client = TwoStepStandardClient([.text(intermediate), .text("本周先整理客户反馈。\n再发测试报告。")])
        let lightClient = TwoStepStandardClient([.text(intermediate)])
        _ = await pipeline(lightClient).process(request(source, mode: .light, additionalRequirements: requirements))

        let result = await pipeline(client).process(input)
        let calls = await client.requests
        let lightCalls = await lightClient.requests

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first, lightCalls.first)
        XCTAssertEqual(try payload(XCTUnwrap(calls.first)), ["canonical_text": source])
        let second = try payload(XCTUnwrap(calls.last))
        XCTAssertEqual(Set(second.keys), Set(["canonical_text", "additional_requirements"]))
        XCTAssertEqual(second["canonical_text"], intermediate)
        let actualRequirements = try XCTUnwrap(second["additional_requirements"])
        XCTAssertTrue(actualRequirements.utf8.elementsEqual(input.preferences.additionalRequirements.utf8))
        XCTAssertEqual(calls.last?.system, VoicePolishEditingPrompts.standard)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        XCTAssertEqual(result.repairAttemptCount, 0)
    }

    func testFullTextPayloadOmitsWhitespaceOnlyRequirementsAndPreservesNonemptyValue() throws {
        let empty = try JSONSerialization.jsonObject(with: Data(VoicePolishEditingPrompts.fullTextPayload(
            "正文", additionalRequirements: " \t\r\n"
        ).utf8)) as? [String: String]
        XCTAssertEqual(empty, ["canonical_text": "正文"])
        let original = " \r\n请保留英文 Cafe\u{301}。\n  用自然段。\t "
        let nonempty = try JSONSerialization.jsonObject(with: Data(VoicePolishEditingPrompts.fullTextPayload(
            "正文", additionalRequirements: original
        ).utf8)) as? [String: String]
        let actual = try XCTUnwrap(nonempty?["additional_requirements"])
        XCTAssertTrue(actual.utf8.elementsEqual(original.utf8))
    }

    func testInvalidFirstResponseStopsBeforeStructureAndPreservesCanonical() async {
        let input = request("请用 Cloud Code 复查。", correctsCloudCode: true)
        for (response, code) in invalidResponses {
            let client = TwoStepStandardClient([.text(response), .text("不应进入第二步")])
            let result = await pipeline(client).process(input)
            assertFallback(result, source: input.fallbackText, attempts: 1, reason: .validationFailed)
            XCTAssertEqual(result.validationCodes, [code])
            XCTAssertEqual(result.rejectedDraft, response)
            let calls = await client.requests
            XCTAssertEqual(calls.map(\.task), [.voicePolishRender])
        }
    }

    func testInvalidSecondResponseNeverDeliversIntermediateDraft() async {
        let input = request("小李负责。小李请假了，改成小王负责。")
        let intermediate = "小王负责，小李请假了。"
        for (response, code) in invalidResponses {
            let client = TwoStepStandardClient([.text(intermediate), .text(response), .text("不应重试")])
            let result = await pipeline(client).process(input)
            assertFallback(result, source: input.fallbackText, attempts: 2, reason: .validationFailed)
            XCTAssertEqual(result.validationCodes, [code])
            XCTAssertEqual(result.rejectedDraft, response)
            let calls = await client.requests
            XCTAssertEqual(calls.count, 2)
        }
    }

    func testFirstClientFailureNeverStartsAnotherStage() async {
        let input = request("请用 Cloud Code 复查，先别发送。", correctsCloudCode: true)
        for error in clientFailures {
            let client = TwoStepStandardClient([.failure(error), .text("不应重试")])
            let result = await pipeline(client).process(input)
            assertFallback(result, source: input.fallbackText, attempts: 1, reason: expectedReason(error))
            XCTAssertNil(result.rejectedDraft)
            let calls = await client.requests
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testSecondClientFailureRetainsOriginalSourceInsteadOfFirstDraft() async {
        let input = request("小李负责。小李请假了，改成小王负责。")
        let intermediate = "小王负责，小李请假了。"
        for error in clientFailures {
            let client = TwoStepStandardClient([.text(intermediate), .failure(error), .text("不应重试")])
            let result = await pipeline(client).process(input)
            assertFallback(result, source: input.fallbackText, attempts: 2, reason: expectedReason(error))
            XCTAssertEqual(result.rejectedDraft, intermediate)
            let calls = await client.requests
            XCTAssertEqual(calls.count, 2)
        }
    }

    func testSecondStageHonorsStageTimeoutWithoutDeliveringFirstDraft() async {
        let source = "有两件事。先校对，再整理。"
        let client = TwoStepStandardClient([.text("先校对，再整理。"), .delay(.seconds(1), "迟到的稿")])
        let subject = VoicePolishEditingPipeline(
            client: client, config: config, totalTimeout: .seconds(2), stageTimeout: .milliseconds(30)
        )
        let result = await subject.process(request(source))
        assertFallback(result, source: source, attempts: 2, reason: .timeout)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 2)
    }

    func testSecondStageSharesTheOriginalTotalDeadline() async {
        let source = "先校对，再整理。"
        let client = TwoStepStandardClient([.text("校对后的正文。"), .delay(.seconds(1), "迟到的稿")])
        let subject = VoicePolishEditingPipeline(
            client: client, config: config, totalTimeout: .milliseconds(80), stageTimeout: .seconds(2)
        )
        let result = await subject.process(request(source))
        assertFallback(result, source: source, attempts: 2, reason: .timeout)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 2)
    }

    func testExpiredBudgetDoesNotCountAnUnstartedClientCall() async {
        let source = "保留原文。"
        let client = TwoStepStandardClient([.text("不应请求")])
        let subject = VoicePolishEditingPipeline(client: client, config: config, totalTimeout: .zero)
        let result = await subject.process(request(source))
        assertFallback(result, source: source, attempts: 0, reason: .timeout)
        let calls = await client.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancellationDuringFirstStageDoesNotStartStructure() async {
        let source = "先确认，再发送。"
        let client = TwoStepStandardClient([.delay(.seconds(5), "迟到的稿"), .text("不应整理")])
        let subject = pipeline(client)
        let input = request(source)
        let task = Task { await subject.process(input) }
        await client.waitUntilRequestCount(1)
        task.cancel()
        let result = await task.value
        assertFallback(result, source: source, attempts: 1, reason: .requestFailed)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testCancellationDuringSecondStageNeverDeliversFirstDraft() async {
        let source = "小李负责。小李请假了，改成小王负责。"
        let intermediate = "小王负责，小李请假了。"
        let client = TwoStepStandardClient([.text(intermediate), .delay(.seconds(5), "迟到的稿")])
        let subject = pipeline(client)
        let input = request(source)
        let task = Task { await subject.process(input) }
        await client.waitUntilRequestCount(2)
        task.cancel()
        let result = await task.value
        assertFallback(result, source: source, attempts: 2, reason: .requestFailed)
        XCTAssertEqual(result.rejectedDraft, intermediate)
        let calls = await client.requests
        XCTAssertEqual(calls.count, 2)
    }

    private var invalidResponses: [(String, VoicePolishValidationCode)] {
        [(" \r\n\t", .emptyOutput), ("正文\u{0001}", .unsafeCharacters),
         (String(repeating: "x", count: VoicePolishOutputNormalizer.maximumResponseBytes + 1), .abnormalLength)]
    }

    private var clientFailures: [LLMError] {
        [.requestFailed(503), .requestRejected(429, "测试限流"), .emptyResponse(nil), .timedOut,
         .truncatedResponse(10), .responseTooLarge(10)]
    }

    private func expectedReason(_ error: LLMError) -> VoicePolishFailureReason {
        switch error {
        case .timedOut: return .timeout
        case .truncatedResponse, .responseTooLarge: return .validationFailed
        default: return .requestFailed
        }
    }

    private func assertFallback(
        _ result: VoicePolishResult, source: String, attempts: Int, reason: VoicePolishFailureReason,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(result.usedFallback, file: file, line: line)
        XCTAssertTrue(result.text.utf8.elementsEqual(source.utf8), file: file, line: line)
        XCTAssertEqual(result.llmAttemptCount, attempts, file: file, line: line)
        XCTAssertEqual(result.repairAttemptCount, 0, file: file, line: line)
        XCTAssertEqual(result.failureReason, reason, file: file, line: line)
    }

    private func payload(_ request: LLMRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: String])
    }

    private func pipeline(_ client: TwoStepStandardClient) -> VoicePolishEditingPipeline {
        VoicePolishEditingPipeline(client: client, config: config)
    }

    private func request(
        _ source: String, mode: VoicePolishQualityMode = .standard, correctsCloudCode: Bool = false,
        additionalRequirements: String = ""
    ) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(providerFinalText: source, segments: [
                RecognitionSegment(id: "s1", text: source, startTimeMs: nil, endTimeMs: nil,
                                   confidence: nil, isFinal: true)
            ], durationMs: 1_000, provider: .volcano),
            context: WritingContext(scene: .workChat),
            preferences: UserPolishPreferences(additionalRequirements: additionalRequirements),
            qualityMode: mode,
            resolvedEntities: correctsCloudCode ? [ResolvedEntity(
                surfaceText: "Cloud Code", canonical: "Claude Code", sourceSegmentIDs: ["s1"],
                candidateSource: .snippet, confidence: 1
            )] : []
        )
    }
}

private actor TwoStepStandardClient: LLMClient {
    enum Step: Sendable { case text(String), failure(LLMError), delay(Duration, String) }
    private var steps: [Step]
    private(set) var requests: [LLMRequest] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ steps: [Step]) { self.steps = steps }

    func waitUntilRequestCount(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        let ready = waiters.filter { $0.count <= requests.count }
        waiters.removeAll { $0.count <= requests.count }
        ready.forEach { $0.continuation.resume() }
        guard !steps.isEmpty else { throw LLMError.emptyResponse(nil) }
        switch steps.removeFirst() {
        case .text(let text): return LLMResponse(text: text, model: config.model)
        case .failure(let error): throw error
        case .delay(let duration, let text):
            try await Task.sleep(for: duration)
            return LLMResponse(text: text, model: config.model)
        }
    }

    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        throw LLMError.emptyResponse(nil)
    }

    func warmUp(baseURL: String) async {}
}
