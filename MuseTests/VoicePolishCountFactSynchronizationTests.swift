import XCTest
@testable import Muse

final class VoicePolishCountFactSynchronizationTests: XCTestCase {
    private let config = LLMConfig(
        apiKey: "test",
        model: "mock-model",
        baseURL: "https://example.com/v1"
    )

    func testFastAndStructuredValidatorsAcceptProvenTenToElevenSynchronization() {
        let source = incrementingListSource(
            declaredCount: "10",
            originalCount: 10
        )
        let request = makeRequest(source)
        let output = VoicePolishListCountConsistency
            .synchronizeDeclaredCountForProvenTrailingAddition(
                in: source,
                canonicalSource: source
            )
        let sourceFacts = facts(for: request)
        let response = structuredResponse(
            output: output,
            request: request,
            sourceFacts: sourceFacts
        )
        let validations = [
            VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: sourceFacts
            ),
            VoicePolishValidator.validateStructured(
                response: response,
                request: request,
                sourceFacts: sourceFacts
            ),
        ]

        XCTAssertTrue(output.contains("这次共有11项"))
        for validation in validations {
            XCTAssertFalse(validation.codes.contains(.missingProtectedFact))
            XCTAssertFalse(validation.codes.contains(.planIntegrityFailure))
        }
    }

    func testFastPipelineAcceptsProvenArabicTwelveToThirteenSynchronization() async {
        let source = incrementingListSource(
            declaredCount: "12",
            originalCount: 12
        )
        let request = makeRequest(source)
        let client = CountSynchronizationScriptedLLM(responses: [source])

        let result = await pipeline(client).process(request)

        XCTAssertEqual(result.executedRoute, .fast)
        XCTAssertEqual(result.llmAttemptCount, 1)
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(result.text.contains("这次共有13项"))
        XCTAssertFalse(result.validationCodes.contains(.missingProtectedFact))
        XCTAssertFalse(result.validationCodes.contains(.planIntegrityFailure))
    }

    func testStructuredValidatorAcceptsOnlyTheProvenCountFactTransition() {
        for (declaredCount, originalCount) in [("十", 10), ("12", 12)] {
            let source = incrementingListSource(
                declaredCount: declaredCount,
                originalCount: originalCount
            )
            let request = makeRequest(source)
            let output = VoicePolishListCountConsistency
                .synchronizeDeclaredCountForProvenTrailingAddition(
                    in: source,
                    canonicalSource: source
                )
            let sourceFacts = facts(for: request)
            let response = structuredResponse(
                output: output,
                request: request,
                sourceFacts: sourceFacts
            )

            let validation = VoicePolishValidator.validateStructured(
                response: response,
                request: request,
                sourceFacts: sourceFacts
            )

            XCTAssertFalse(
                validation.codes.contains(.missingProtectedFact),
                "\(originalCount) -> \(originalCount + 1)"
            )
            XCTAssertFalse(
                validation.codes.contains(.planIntegrityFailure),
                "\(originalCount) -> \(originalCount + 1)"
            )
        }
    }

    func testCountSynchronizationDoesNotRelaxOrdinaryNumberAmountOrDateFacts() {
        let source = incrementingListSource(
            declaredCount: "10",
            originalCount: 10,
            firstItem: "核对编号42、预算500元和日期2026-08-03。"
        )
        let changedFacts = source
            .replacingOccurrences(of: "编号42", with: "编号43")
            .replacingOccurrences(of: "500元", with: "600元")
            .replacingOccurrences(of: "2026-08-03", with: "2026-08-04")
        let synchronizedChangedFacts = VoicePolishListCountConsistency
            .synchronizeDeclaredCountForProvenTrailingAddition(
                in: changedFacts,
                canonicalSource: source
            )
        let request = makeRequest(source)
        let sourceFacts = facts(for: request)
        let fastValidation = VoicePolishValidator.validateFast(
            output: synchronizedChangedFacts,
            request: request,
            sourceFacts: sourceFacts
        )
        let structuredValidation = VoicePolishValidator.validateStructured(
            response: structuredResponse(
                output: synchronizedChangedFacts,
                request: request,
                sourceFacts: sourceFacts
            ),
            request: request,
            sourceFacts: sourceFacts
        )

        for validation in [fastValidation, structuredValidation] {
            XCTAssertTrue(validation.codes.contains(.missingProtectedFact))
            XCTAssertTrue(validation.codes.contains(.planIntegrityFailure))
        }
    }

    func testSameValueInOrdinaryTextMakesCountFactExemptionUnavailable() async {
        let source = incrementingListSource(
            declaredCount: "10",
            originalCount: 10,
            firstItem: "保留10天观察窗口。"
        )
        let changedOrdinaryNumber = source.replacingOccurrences(
            of: "保留10天",
            with: "保留11天"
        )
        let synchronizedCandidate = VoicePolishListCountConsistency
            .synchronizeDeclaredCountForProvenTrailingAddition(
                in: changedOrdinaryNumber,
                canonicalSource: source
            )

        let projected = VoicePolishListCountConsistency
            .projectedTextForFactValidation(
                in: synchronizedCandidate,
                canonicalSource: source
            )
        XCTAssertNotNil(projected)
        XCTAssertTrue(projected?.contains("这次共有10项") == true)
        XCTAssertTrue(projected?.contains("保留11天") == true)

        let request = makeRequest(source)
        let sourceFacts = facts(for: request)
        let validation = VoicePolishValidator.validateFast(
            output: synchronizedCandidate,
            request: request,
            sourceFacts: sourceFacts
        )
        XCTAssertTrue(validation.codes.contains(.planIntegrityFailure))

        let client = CountSynchronizationScriptedLLM(
            responses: [changedOrdinaryNumber]
        )
        let result = await pipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.text.contains("保留10天"))
        XCTAssertFalse(result.text.contains("保留11天"))
    }

    func testInlineTenthEleventhAndTwelfthOrdinalFactsAreNotCoveredByCountProjection() {
        let ordinals = [
            "一", "二", "三", "四", "五", "六",
            "七", "八", "九", "十", "十一", "十二",
        ]
        let labels = [
            "确认需求", "安排设计", "完成开发", "执行测试", "整理文档", "准备培训",
            "检查发布", "观察监控", "组织复盘", "完成归档", "保留备份", "通知团队",
        ]
        let inlineItems = zip(ordinals, labels)
            .map { "第\($0.0)个是\($0.1)" }
            .joined(separator: "。")
        let canonicalSource = "这次共有12项。\(inlineItems)。再补充一项：完成最终检查。"
        let candidateBeforeSynchronization = incrementingListSource(
            declaredCount: "12",
            originalCount: 12
        )
        let candidate = VoicePolishListCountConsistency
            .synchronizeDeclaredCountForProvenTrailingAddition(
                in: candidateBeforeSynchronization,
                canonicalSource: canonicalSource
            )

        XCTAssertTrue(candidate.contains("这次共有13项"))
        XCTAssertNotNil(
            VoicePolishListCountConsistency.projectedTextForFactValidation(
                in: candidate,
                canonicalSource: canonicalSource
            )
        )

        let request = makeRequest(canonicalSource)
        let sourceFacts = facts(for: request)
        XCTAssertTrue(sourceFacts.contains { $0.kind == .number && $0.canonicalValue == "10" })
        XCTAssertTrue(sourceFacts.contains { $0.kind == .number && $0.canonicalValue == "11" })
        XCTAssertTrue(sourceFacts.contains { $0.kind == .number && $0.canonicalValue == "12" })

        let validation = VoicePolishValidator.validateFast(
            output: candidate,
            request: request,
            sourceFacts: sourceFacts
        )
        XCTAssertTrue(validation.codes.contains(.missingProtectedFact))
    }

    private func pipeline(
        _ client: CountSynchronizationScriptedLLM
    ) -> VoicePolishPipeline {
        VoicePolishPipeline(client: client, config: config)
    }

    private func makeRequest(_ text: String) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: text,
                segments: [RecognitionSegment(
                    id: "s1",
                    text: text,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(
                scene: .workChat,
                level: .metadataOnly,
                safety: .unknown
            ),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .balanced
        )
    }

    private func facts(
        for request: VoicePolishRequest
    ) -> [SourceFactCandidate] {
        ProtectedFactExtractor.extract(
            from: VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                from: request.input.segments
            )
        )
    }

    private func structuredResponse(
        output: String,
        request: VoicePolishRequest,
        sourceFacts: [SourceFactCandidate]
    ) -> StructuredVoicePolishResponse {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        return StructuredVoicePolishResponse(
            plan: VoicePolishPlan(
                version: VoicePolishPrompts.version,
                language: request.input.detectedLanguage,
                scene: request.context.scene,
                finalIntent: "保留事实并同步列表总数",
                orderedBlocks: [VoicePolishBlock(
                    id: "b1",
                    text: output,
                    sourceSegmentIDs: ["s1"],
                    kind: .content
                )],
                discardedFragments: [],
                corrections: [],
                sideNotes: [],
                facts: sourceFacts.map { fact in
                    ProtectedFact(
                        sourceText: fact.sourceText,
                        canonicalValue: fact.canonicalValue,
                        kind: fact.kind,
                        disposition: .mustPreserve,
                        exclusionReason: nil,
                        sourceSegmentIDs: fact.sourceSegmentIDs
                    )
                },
                uncertainEntities: [],
                outputFormat: VoiceOutputFormat(
                    kind: expectation.kind,
                    expectedListCount: expectation.expectedListItemCount
                ),
                confidence: 0.95
            ),
            finalText: output
        )
    }

    private func incrementingListSource(
        declaredCount: String,
        originalCount: Int,
        firstItem: String = "确认需求。"
    ) -> String {
        let labels = [
            firstItem,
            "安排设计。",
            "完成开发。",
            "执行测试。",
            "整理文档。",
            "准备培训。",
            "检查发布。",
            "观察监控。",
            "组织复盘。",
            "完成归档。",
            "保留备份。",
            "通知团队。",
        ]
        precondition((1...labels.count).contains(originalCount))
        let originalItems = labels.prefix(originalCount).enumerated().map {
            "\($0.offset + 1). \($0.element)"
        }
        let addition = "\(originalCount + 1). 再补充一项：完成最终检查。"
        return (["这次共有\(declaredCount)项：", ""] + originalItems + [addition])
            .joined(separator: "\n")
    }
}

private actor CountSynchronizationScriptedLLM: LLMClient {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(
        _ request: LLMRequest,
        config: LLMConfig
    ) async throws -> LLMResponse {
        guard !responses.isEmpty else {
            throw CountSynchronizationMockError.missingResponse
        }
        return LLMResponse(text: responses.removeFirst(), model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        throw CountSynchronizationMockError.unsupportedProcess
    }

    func warmUp(baseURL: String) async {}
}

private enum CountSynchronizationMockError: Error {
    case missingResponse
    case unsupportedProcess
}
