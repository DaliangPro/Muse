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

    func testDeclaredCountIsPreservedByCompleteOrderedListWithoutRepeatingHeader() {
        let source = "下面共3项，请按原顺序整理。关于登录失败，负责人小陈。关于支付失败，负责人小林。关于退出失败，负责人产品组。"
        let output = """
        1. 登录失败：负责人小陈。
        2. 支付失败：负责人小林。
        3. 退出失败：负责人产品组。
        """
        let request = makeRequest(source)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts(for: request)
        )

        XCTAssertFalse(validation.codes.contains(.missingProtectedFact))
        XCTAssertFalse(validation.codes.contains(.planIntegrityFailure))
        XCTAssertEqual(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )?.count,
            3
        )
    }

    func testDeclaredCountEvidenceAcceptsCompleteSharedPredicateWithoutDistinctDetails() {
        let source = "下面共3项，请按原顺序整理。登录失败需要确认。支付失败需要确认。退出失败需要确认。"
        let output = """
        1. 登录失败：需要确认。
        2. 支付失败：需要确认。
        3. 退出失败：需要确认。
        """
        let request = makeRequest(source)
        let sourceFacts = facts(for: request)
        let validations = [
            VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: sourceFacts
            ),
            VoicePolishValidator.validateStructured(
                response: structuredResponse(
                    output: output,
                    request: request,
                    sourceFacts: sourceFacts
                ),
                request: request,
                sourceFacts: sourceFacts
            ),
        ]

        XCTAssertEqual(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )?.count,
            3
        )
        for validation in validations {
            XCTAssertFalse(validation.codes.contains(.missingProtectedFact))
            XCTAssertFalse(validation.codes.contains(.planIntegrityFailure))
        }
    }

    func testDeclaredCountEvidenceRejectsIncompleteSharedPredicate() {
        let source = "下面共3项，请按原顺序整理。登录失败需要确认。支付失败需要确认。退出失败需要确认。"
        let output = """
        1. 登录失败：需要确认。
        2. 支付失败：需要处理。
        3. 退出失败：需要确认。
        """
        let request = makeRequest(source)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts(for: request)
        )

        XCTAssertNil(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )
        )
        XCTAssertTrue(validation.codes.contains(.missingProtectedFact))
    }

    func testDeclaredCountEvidenceRejectsSharedGenericDetailPlaceholders() {
        let source = "下面共3项，请按原顺序整理。关于登录失败，负责人小陈。关于支付失败，负责人小林。关于退出失败，负责人产品组。"
        let outputs = [
            """
            1. 登录失败：负责人。
            2. 支付失败：负责人。
            3. 退出失败：负责人。
            """,
            """
            1. 登录失败：负责人小陈。
            2. 支付失败：负责人。
            3. 退出失败：负责人产品组。
            """,
        ]
        let request = makeRequest(source)
        let sourceFacts = facts(for: request)

        for output in outputs {
            XCTAssertNil(
                VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                    in: output,
                    canonicalSource: source
                ),
                output
            )
            let validation = VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: sourceFacts
            )
            XCTAssertTrue(
                validation.codes.contains(.missingProtectedFact),
                "\(output) codes=\(validation.codes)"
            )
        }
    }

    func testUnpunctuatedLongListDoesNotMakeHeaderCountConditional() {
        let source = "下面共3项请按原顺序逐项整理每项完整保留关于登录失败负责人小陈周一复现如果遇到阻塞就写清真实原因关于支付失败负责人小林周二核对如果外部条件变化只更新受影响部分关于退出失败负责人产品组周三确认如果结果不一致就留下复核结论"
        let output = """
        1. 登录失败：负责人小陈，周一复现；遇到阻塞时写清真实原因。
        2. 支付失败：负责人小林，周二核对；外部条件变化时只更新受影响部分。
        3. 退出失败：负责人产品组，周三确认；结果不一致时留下复核结论。
        """

        let evidence = VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
            in: output,
            canonicalSource: source
        )
        XCTAssertEqual(evidence?.count, 3)

        let request = makeRequest(source)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts(for: request)
        )
        XCTAssertFalse(validation.codes.contains(.missingProtectedFact))
    }

    func testDeclaredCountEvidenceRejectsDuplicatedItemUsedToFillTheList() {
        let source = "下面共3项，请按原顺序整理。关于登录失败，负责人小陈。关于支付失败，负责人小林。关于退出失败，负责人产品组。"
        let output = """
        1. 登录失败：负责人小陈。
        2. 支付失败：负责人小林。
        3. 支付失败补充：继续由小林处理。
        """
        let request = makeRequest(source)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts(for: request)
        )

        XCTAssertNil(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )
        )
        XCTAssertTrue(validation.codes.contains(.missingProtectedFact))
    }

    func testOrdinaryQuantityCannotBorrowAnUnrelatedSevenItemList() {
        let source = "客户共有7人参与。名单是甲方、乙方、丙方、丁方、戊方、己方和庚方。"
        let output = """
        1. 甲方：参与。
        2. 乙方：参与。
        3. 丙方：参与。
        4. 丁方：参与。
        5. 戊方：参与。
        6. 己方：参与。
        7. 庚方：参与。
        """
        let request = makeRequest(source)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts(for: request)
        )

        XCTAssertNil(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )
        )
        XCTAssertTrue(validation.codes.contains(.missingProtectedFact))
    }

    func testProblemCountCannotBorrowASeparateModuleListAcrossUnrelatedBoundary() {
        let source = "目前有3个问题尚未解决，但它们与下面汇报无关。今天只汇报登录、支付、退款三个模块的负责人：登录由小陈负责，支付由小林负责，退款由产品组负责。"
        let output = """
        1. 登录：小陈负责。
        2. 支付：小林负责。
        3. 退款：产品组负责。
        """

        XCTAssertNil(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )
        )
    }

    func testDeclaredCountEvidenceCannotTakeWrongOrderFromAnOldRecord() {
        let source = "下面共3项，请按原顺序整理：登录失败由小陈复现，支付失败由小林核对，退出失败由产品组确认。旧记录曾按登录失败、退出失败、支付失败展示，但那不是本次顺序。"
        let output = """
        1. 登录失败：小陈复现。
        2. 退出失败：产品组确认。
        3. 支付失败：小林核对。
        """

        XCTAssertNil(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )
        )
    }

    func testDeclaredCountEvidenceRejectsCopiedBodiesEvenWithCorrectTitles() {
        let source = "下面共3项，请按原顺序整理。登录失败先复现登录链路，支付失败要核对支付回调，退出失败需确认退出状态。"
        let output = """
        1. 登录失败：先复现登录链路。
        2. 支付失败：先复现登录链路。
        3. 退出失败：先复现登录链路。
        """

        XCTAssertNil(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )
        )
    }

    func testConflictingGenericCountHeaderCannotBorrowAnotherSourceNumber() {
        let source = "下面共3项，请按原顺序整理，每项预留4个工作日。登录失败由小陈复现，支付失败由小林核对，退出失败由产品组确认。"
        let output = """
        总数：4
        1. 登录失败：小陈复现。
        2. 支付失败：小林核对。
        3. 退出失败：产品组确认。
        """

        XCTAssertNil(
            VoicePolishListCountConsistency.preservedDeclaredCountEvidence(
                in: output,
                canonicalSource: source
            )
        )
    }

    func testClassifierSynonymsAreAcceptedOnlyWhenSixItemStructureProvesTheCount() {
        let source = "首页文案由小陈负责，引导页由小林负责，权限说明由产品组负责，长文润色由设计组负责，历史记录由开发组负责，安装包签名由测试组负责。六件事分别写清负责人。"
        let output = """
        六项工作安排如下：
        1. 首页文案：小陈负责。
        2. 引导页：小林负责。
        3. 权限说明：产品组负责。
        4. 长文润色：设计组负责。
        5. 历史记录：开发组负责。
        6. 安装包签名：测试组负责。
        """
        let request = makeRequest(source)
        let validation = VoicePolishValidator.validateFast(
            output: output,
            request: request,
            sourceFacts: facts(for: request)
        )

        XCTAssertFalse(validation.codes.contains(.missingProtectedFact))
        XCTAssertFalse(
            validation.codes.contains(.planIntegrityFailure),
            "\(validation.codes) evidence=\(String(describing: VoicePolishListCountConsistency.preservedDeclaredCountEvidence(in: output, canonicalSource: source)))"
        )

        let contradictory = output.replacingOccurrences(
            of: "六项工作安排如下",
            with: "五项工作安排如下"
        )
        let contradictoryValidation = VoicePolishValidator.validateFast(
            output: contradictory,
            request: request,
            sourceFacts: facts(for: request)
        )
        XCTAssertTrue(contradictoryValidation.codes.contains(.planIntegrityFailure))
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
