import XCTest
@testable import Muse

final class VoicePolishLedgerPipelineTests: XCTestCase {
    private let config = LLMConfig(
        apiKey: "test",
        model: "mock-model",
        baseURL: "https://example.com/v1"
    )

    func testDailyLongTextUsesPlannerWriterAndColdReviewer() async throws {
        let source = dailySource("本周课程交接")
        let request = makeRequest(source)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = ledger(spans: spans)
        let draft = VoicePolishLedgerDraftDocument(fragments: zip(plan.units, spans).map {
            VoicePolishLedgerDraftFragment(
                id: "f_\($0.0.id)",
                unitIds: [$0.0.id],
                text: $0.1.text.replacingOccurrences(
                    of: "，清理口述重复后再形成自然段",
                    with: "，并整理为自然表达"
                )
            )
        })
        let finalText = draft.fragments.map(\.text).joined(separator: "\n\n")
        let client = LedgerScriptedLLM(responses: [
            try encoded(plan),
            try encoded(draft),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(
            client: client,
            config: config
        ).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, finalText)
        XCTAssertEqual(result.executedRoute, .deep)
        XCTAssertEqual(result.llmAttemptCount, 3)
        let requests = await client.requests()
        XCTAssertEqual(
            requests.map(\.task),
            [.voicePolishAnalyze, .voicePolishRender, .voicePolishAnalyze]
        )
        XCTAssertEqual(requests[0].options.responseFormat, .jsonObject)
        XCTAssertEqual(requests[1].options.responseFormat, .jsonObject)
    }

    func testWriterCannotOmitAnyDailyLongTextUnit() async throws {
        let request = makeRequest(dailySource("漏项检查"))
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = ledger(spans: spans)
        let incomplete = VoicePolishLedgerDraftDocument(fragments: zip(plan.units.dropLast(), spans).map {
            VoicePolishLedgerDraftFragment(id: "f_\($0.0.id)", unitIds: [$0.0.id], text: $0.1.text)
        })
        let client = LedgerScriptedLLM(responses: [
            try encoded(plan),
            try encoded(incomplete),
        ])

        let result = await VoicePolishPipeline(client: client, config: config).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testNonCommitmentCannotBecomeCertainNonOccurrence() async throws {
        let source = "周五上午先发内部试看，邮件里不要承诺周五对外发布。"
        let wrong = "周五上午先发内部试看，我们不会在周五对外发布。"
        let repaired = "周五上午先发内部试看，邮件里不要承诺周五对外发布。"
        let request = makeRequest(source)
        let spanIDs = evidenceSpanIDs(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: "周五上午先发内部试看，邮件里不要承诺周五对外发布",
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "confirmed",
            exactTokens: ["周五上午"],
            surfaceTokens: []
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(unit: unit)),
            try encoded(draft(wrong)),
            try encoded(passReview()),
            try encoded(draft(repaired)),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(
            client: client,
            config: config
        ).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repaired)
        XCTAssertEqual(result.llmAttemptCount, 5)
        let requests = await client.requests()
        XCTAssertTrue(requests[3].user.contains("不得改成事情确定不会发生"))
    }

    func testVerifiedContextEntityMissingTriggersTargetedRepair() async throws {
        let source = "项目名按北城研究写。"
        let repaired = "项目名统一使用北辰研究。"
        let entity = ResolvedEntity(
            surfaceText: "北城研究",
            canonical: "北辰研究",
            sourceSegmentIDs: ["s1"],
            candidateSource: .authorizedContext,
            confidence: 0.98
        )
        let request = makeRequest(source, scene: .aiPrompt, resolvedEntities: [entity])
        let spanIDs = evidenceSpanIDs(for: request)
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(finalMeaning: "项目名按北城研究写", spanIDs: spanIDs)),
            try encoded(draft("比较五款语音输入工具。")),
            try encoded(passReview()),
            try encoded(draft(repaired)),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(
            client: client,
            config: config
        ).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repaired)
        XCTAssertEqual(result.llmAttemptCount, 5)
        let requests = await client.requests()
        XCTAssertTrue(requests[0].user.contains("北辰研究"))
        XCTAssertTrue(requests[3].user.contains("恢复已确认的标准实体"))
    }

    func testFailedConfirmationStopsAfterFiveCallsWithoutLegacyRetry() async throws {
        let source = "周五上午先发内部试看，邮件里不要承诺周五对外发布。"
        let wrong = "周五上午先发内部试看，我们不会在周五对外发布。"
        let request = makeRequest(source)
        let spanIDs = evidenceSpanIDs(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: "周五上午先发内部试看，邮件里不要承诺周五对外发布",
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "not_promised",
            exactTokens: ["周五上午"],
            surfaceTokens: []
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(unit: unit)),
            try encoded(draft(wrong)),
            try encoded(passReview()),
            try encoded(draft(wrong)),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(
            client: client,
            config: config
        ).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 5)
        XCTAssertEqual(result.failureReason, .validationFailed)
        XCTAssertTrue(result.validationCodes.contains(.semanticDecisionUnverified))
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 5)
    }

    func testRiskShortTextUsesLedgerWhileSimpleShortQuestionKeepsLightPath() {
        XCTAssertTrue(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "如果还是不行，让他把系统版本和错误截图发过来。",
            scene: .customerSupport
        )))
        XCTAssertTrue(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "跟团队说会议改到周四下午。",
            scene: .workChat
        )))
        XCTAssertTrue(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "只有客户确认，才能对外发布。",
            scene: .workChat
        )))
        XCTAssertTrue(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "不要覆盖安装，建议先跑测试。",
            scene: .workChat
        )))
        XCTAssertFalse(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "你到哪了",
            scene: .chat
        )))
    }

    func testMissingConditionalCueRepairsPlannerOnce() async throws {
        let source = "如果还是不行，让他把系统版本和错误截图发过来。"
        let request = makeRequest(source, scene: .customerSupport)
        let spanIDs = evidenceSpanIDs(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: "如果问题仍未解决，请发送系统版本和错误截图",
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "confirmed",
            exactTokens: [],
            surfaceTokens: []
        )
        let invalid = ledger(unit: unit)
        let valid = VoicePolishIntentLedger(
            audience: [],
            units: [unit],
            corrections: [],
            conditionals: [VoicePolishLedgerConditional(
                id: "c1",
                cueIds: ["lc001"],
                operatorKind: "if_then",
                condition: VoicePolishLedgerCondition(
                    subject: "还是不行",
                    predicate: "不行",
                    polarity: true,
                    sourceSpanIds: spanIDs
                ),
                consequences: [VoicePolishLedgerConsequence(
                    action: "把系统版本和错误截图发过来",
                    polarity: true,
                    sourceSpanIds: spanIDs
                )]
            )],
            technicalTokenMappings: [],
            dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )
        let finalText = "如果问题仍未解决，请把系统版本和错误截图发给我们。"
        let client = LedgerScriptedLLM(responses: [
            try encoded(invalid),
            try encoded(valid),
            try encoded(draft(finalText)),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(client: client, config: config).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, finalText)
        XCTAssertEqual(result.llmAttemptCount, 4)
        let requests = await client.requests()
        XCTAssertEqual(
            requests.map(\.task),
            [.voicePolishAnalyze, .voicePolishAnalyze, .voicePolishRender, .voicePolishAnalyze]
        )
        XCTAssertTrue(requests[1].user.contains("invalid_ledger_response"))
    }

    func testDictatedSymbolMappingIsAppliedBeforeReview() async throws {
        let source = "执行scripts斜杠package短横线app点sh，然后检查codesign。"
        let request = makeRequest(source, scene: .code)
        let spanIDs = evidenceSpanIDs(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: "执行打包脚本，然后检查codesign",
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "confirmed",
            exactTokens: [],
            surfaceTokens: []
        )
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [unit],
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [],
            dictatedSymbolMappings: [VoicePolishLedgerTokenMapping(
                alias: "scripts斜杠package短横线app点sh",
                canonical: "scripts/package-app.sh",
                sourceSpanIds: spanIDs,
                transform: "spoken_ascii_symbols"
            )],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(plan),
            try encoded(draft("执行scripts斜杠package短横线app点sh，然后检查codesign。")),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(client: client, config: config).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "执行scripts/package-app.sh，然后检查codesign。")
        XCTAssertEqual(result.llmAttemptCount, 3)
    }

    func testLongSingleSegmentBecomesBoundedEvidenceSpans() {
        let request = makeRequest(dailySource("证据范围"))
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)

        XCTAssertGreaterThan(spans.count, 1)
        XCTAssertEqual(spans.map(\.text).joined(), request.input.fallbackText)
        XCTAssertTrue(spans.allSatisfy { $0.text.count <= 180 })
        XCTAssertEqual(spans.first?.start, 0)
        XCTAssertEqual(spans.last?.end, request.input.fallbackText.count)
    }

    func testOfficialDeepSeekFlashUsesProInsideLedgerOnly() {
        let flash = LLMConfig(
            apiKey: "test",
            model: "deepseek-v4-flash",
            baseURL: "https://api.deepseek.com"
        )
        XCTAssertEqual(
            VoicePolishLedgerPipeline.qualityConfig(for: flash).model,
            "deepseek-v4-pro"
        )
        XCTAssertEqual(
            VoicePolishLedgerPipeline.reviewConfig(for: flash).model,
            "deepseek-v4-flash"
        )

        let custom = LLMConfig(
            apiKey: "test",
            model: "deepseek-v4-flash",
            baseURL: "https://gateway.example.com/v1"
        )
        XCTAssertEqual(
            VoicePolishLedgerPipeline.qualityConfig(for: custom).model,
            "deepseek-v4-flash"
        )
    }

    func testOfficialDeepSeekUsesProForGenerationAndFlashForColdReview() async throws {
        let source = "不要承诺周五发布。"
        let request = makeRequest(source)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "constraint",
            deliveryRole: "recipient_content",
            finalMeaning: source,
            sourceSpanIds: spans.map(\.id),
            status: "keep",
            modality: "not_promised",
            exactTokens: [],
            surfaceTokens: []
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(unit: unit)),
            try encoded(draft(source)),
            try encoded(passReview()),
        ])
        let official = LLMConfig(
            apiKey: "test",
            model: "deepseek-v4-flash",
            baseURL: "https://api.deepseek.com"
        )

        let result = await VoicePolishPipeline(client: client, config: official).process(request)

        XCTAssertFalse(result.usedFallback)
        let models = await client.models()
        XCTAssertEqual(models, ["deepseek-v4-pro", "deepseek-v4-pro", "deepseek-v4-flash"])
    }

    func testPlannerCannotInventLowercaseTechnicalJoin() throws {
        let request = makeRequest("执行 git status，然后反馈结果。", scene: .code)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: request.input.fallbackText,
            sourceSpanIds: spans.map(\.id),
            status: "keep",
            modality: "confirmed",
            exactTokens: [],
            surfaceTokens: []
        )
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [unit],
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [VoicePolishLedgerTokenMapping(
                alias: "git status",
                canonical: "gitstatus",
                sourceSpanIds: spans.map(\.id),
                transform: "remove_internal_ascii_whitespace"
            )],
            dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        ))
    }

    func testTechnicalJoinRejectsVersionsButAcceptsClearlySplitIdentifier() throws {
        func plan(
            source: String,
            alias: String,
            canonical: String
        ) throws -> (VoicePolishIntentLedger, [VoicePolishEvidenceSpan]) {
            let request = makeRequest(source, scene: .code)
            let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
            let unit = VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: source, sourceSpanIds: spans.map(\.id), status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )
            return (VoicePolishIntentLedger(
                audience: [], units: [unit], corrections: [], conditionals: [],
                technicalTokenMappings: [VoicePolishLedgerTokenMapping(
                    alias: alias, canonical: canonical, sourceSpanIds: spans.map(\.id),
                    transform: "remove_internal_ascii_whitespace"
                )],
                dictatedSymbolMappings: [], contextMappings: [],
                structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
            ), spans)
        }

        for (source, alias, canonical) in [
            ("请使用 Swift 6 复测。", "Swift 6", "Swift6"),
            ("请使用 Node 20 复测。", "Node 20", "Node20"),
            ("请检查 Claude Code 配置。", "Claude Code", "ClaudeCode"),
        ] {
            let (ledger, spans) = try plan(source: source, alias: alias, canonical: canonical)
            XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
                ledger,
                spans: spans,
                verifiedMappings: [],
                requiredLogicCues: [],
                scene: .code
            ))
        }

        let (valid, validSpans) = try plan(
            source: "请检查 Voice Pol ish 的调用链。",
            alias: "Voice Pol ish",
            canonical: "VoicePolish"
        )
        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            valid,
            spans: validSpans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        ))
    }

    func testOnlyIfAndCannotThenRequireSourceBoundConditionals() throws {
        let request = makeRequest("只有客户确认，才能发布。不能完成复核，就继续等待。")
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let cues = VoicePolishLedgerIntegrityValidator.requiredLogicCues(
            source: request.input.fallbackText,
            spans: spans
        )
        XCTAssertEqual(cues.count, 2)
        let units = spans.enumerated().map { index, span in
            VoicePolishLedgerUnit(
                id: "u\(index + 1)", kind: "constraint", deliveryRole: "recipient_content",
                finalMeaning: span.text, sourceSpanIds: [span.id], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )
        }
        let invalid = VoicePolishIntentLedger(
            audience: [], units: units, corrections: [],
            conditionals: cues.enumerated().map { index, cue in
                let wrongSpan = spans[(index + 1) % spans.count].id
                return VoicePolishLedgerConditional(
                    id: "c\(index + 1)", cueIds: [cue.id],
                    operatorKind: cue.operatorKind,
                    condition: VoicePolishLedgerCondition(
                        subject: "条件", predicate: "成立", polarity: true,
                        sourceSpanIds: [wrongSpan]
                    ),
                    consequences: [VoicePolishLedgerConsequence(
                        action: "执行", polarity: true, sourceSpanIds: [wrongSpan]
                    )]
                )
            },
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: units.map(\.id))
        )

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            invalid,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        ))
    }

    func testConditionalMeaningCannotBeInventedInsideAValidSourceSpan() throws {
        let request = makeRequest("只有客户确认，才能发布。")
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let cues = VoicePolishLedgerIntegrityValidator.requiredLogicCues(
            source: request.input.fallbackText,
            spans: spans
        )
        let unit = VoicePolishLedgerUnit(
            id: "u1", kind: "constraint", deliveryRole: "recipient_content",
            finalMeaning: request.input.fallbackText, sourceSpanIds: [spans[0].id],
            status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        func plan(subject: String, predicate: String, action: String) -> VoicePolishIntentLedger {
            VoicePolishIntentLedger(
                audience: [], units: [unit], corrections: [],
                conditionals: [VoicePolishLedgerConditional(
                    id: "c1", cueIds: [cues[0].id],
                    operatorKind: "only_if",
                    condition: VoicePolishLedgerCondition(
                        subject: subject, predicate: predicate, polarity: true,
                        sourceSpanIds: [spans[0].id]
                    ),
                    consequences: [VoicePolishLedgerConsequence(
                        action: action, polarity: true, sourceSpanIds: [spans[0].id]
                    )]
                )],
                technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
                structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
            )
        }

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(subject: "老板", predicate: "批准", action: "删除数据库"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        ))
        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(subject: "客户", predicate: "确认", action: "发布"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        ))
    }

    func testConditionalOperatorIsFixedByLocalCue() throws {
        let request = makeRequest("只有客户确认，才能发布。如果客户确认，就发送通知。")
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let cues = VoicePolishLedgerIntegrityValidator.requiredLogicCues(
            source: request.input.fallbackText,
            spans: spans
        )
        XCTAssertEqual(cues.map(\.operatorKind), ["only_if", "if_then"])

        let units = spans.enumerated().map { index, span in
            VoicePolishLedgerUnit(
                id: "u\(index + 1)", kind: "constraint", deliveryRole: "recipient_content",
                finalMeaning: span.text, sourceSpanIds: [span.id], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )
        }
        let wrong = VoicePolishIntentLedger(
            audience: [], units: units, corrections: [],
            conditionals: [
                VoicePolishLedgerConditional(
                    id: "c1", cueIds: [cues[0].id], operatorKind: "if_then",
                    condition: VoicePolishLedgerCondition(
                        subject: "客户", predicate: "确认", polarity: true,
                        sourceSpanIds: [spans[0].id]
                    ),
                    consequences: [VoicePolishLedgerConsequence(
                        action: "发布", polarity: true, sourceSpanIds: [spans[0].id]
                    )]
                ),
                VoicePolishLedgerConditional(
                    id: "c2", cueIds: [cues[1].id], operatorKind: "if_then",
                    condition: VoicePolishLedgerCondition(
                        subject: "客户", predicate: "确认", polarity: true,
                        sourceSpanIds: [spans[1].id]
                    ),
                    consequences: [VoicePolishLedgerConsequence(
                        action: "发送通知", polarity: true, sourceSpanIds: [spans[1].id]
                    )]
                ),
            ],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "paragraphs", orderedUnitIds: units.map(\.id)
            )
        )

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            wrong,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        ))
    }

    func testExcludedContextAliasDoesNotBecomeRequiredOutput() throws {
        let request = makeRequest(
            "给客户回复已收到，但内部北城研究不要告诉客户",
            resolvedEntities: [ResolvedEntity(
                surfaceText: "北城研究",
                canonical: "北辰研究",
                sourceSegmentIDs: ["s1"],
                candidateSource: .authorizedContext,
                confidence: 0.99
            )]
        )
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        XCTAssertEqual(spans.count, 1)
        let plan = VoicePolishIntentLedger(
            audience: [VoicePolishLedgerAudience(
                text: "客户", sourceSpanIds: [spans[0].id], surfaceTokens: ["客户"],
                deliveryMode: "direct_address"
            )],
            units: [
                VoicePolishLedgerUnit(
                    id: "u1", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "给客户回复已收到", sourceSpanIds: [spans[0].id],
                    status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "u2", kind: "constraint", deliveryRole: "excluded_content",
                    finalMeaning: "内部北城研究不要告诉客户", sourceSpanIds: [spans[0].id],
                    status: "remove", modality: "prohibited", exactTokens: [],
                    surfaceTokens: ["北城研究"]
                ),
            ],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )
        let mappings = VoicePolishLedgerIntegrityValidator.verifiedMappings(request: request, spans: spans)
        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: mappings,
            requiredLogicCues: [],
            scene: .document
        )

        XCTAssertTrue(validated.contextMappings.isEmpty)
        XCTAssertTrue(VoicePolishLedgerIntegrityValidator.deterministicIssues(
            output: "已收到。",
            request: request,
            ledger: validated,
            spans: spans
        ).isEmpty)
    }

    func testLongOriginalTextCannotBeReportedAsPolished() async throws {
        let request = makeRequest(dailySource("原样假成功"))
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = ledger(spans: spans)
        let original = VoicePolishLedgerDraftDocument(fragments: zip(plan.units, spans).map {
            VoicePolishLedgerDraftFragment(id: "f_\($0.0.id)", unitIds: [$0.0.id], text: $0.1.text)
        })
        let repaired = VoicePolishLedgerDraftDocument(fragments: original.fragments.map {
            var fragment = $0
            fragment.text = fragment.text.replacingOccurrences(
                of: "，清理口述重复后再形成自然段",
                with: "，并整理为自然表达"
            )
            return fragment
        })
        let client = LedgerScriptedLLM(responses: [
            try encoded(plan), try encoded(original), try encoded(passReview()),
            try encoded(repaired), try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(client: client, config: config).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 5)
        XCTAssertNotEqual(result.text.replacingOccurrences(of: "\n", with: ""), request.input.fallbackText)
    }

    func testNearOriginalLongDraftWithOralScaffoldingCannotPass() async throws {
        let source = (1...8).map { index in
            "第\(index)部分，嗯，我们已经核对了负责人、时间边界和待确认事项，然后的话还要把各自的下一步说明清楚，怎么说呢，就是说只改一个标点仍然不算完整成稿。"
        }.joined()
        let request = makeRequest(source)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = ledger(spans: spans)
        let nearOriginal = VoicePolishLedgerDraftDocument(fragments: zip(plan.units, spans).map {
            VoicePolishLedgerDraftFragment(
                id: "f_\($0.0.id)", unitIds: [$0.0.id],
                text: $0.1.text.replacingOccurrences(of: "第1部分，", with: "第1部分：")
            )
        })
        let repaired = VoicePolishLedgerDraftDocument(fragments: zip(plan.units, spans).map {
            VoicePolishLedgerDraftFragment(
                id: "f_\($0.0.id)", unitIds: [$0.0.id],
                text: $0.1.text
                    .replacingOccurrences(of: "嗯，", with: "")
                    .replacingOccurrences(of: "然后的话", with: "随后")
                    .replacingOccurrences(of: "怎么说呢，", with: "")
                    .replacingOccurrences(of: "就是说", with: "")
            )
        })
        let client = LedgerScriptedLLM(responses: [
            try encoded(plan), try encoded(nearOriginal), try encoded(passReview()),
            try encoded(repaired), try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(client: client, config: config).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 5)
        XCTAssertFalse(result.text.contains("然后的话"))
        XCTAssertFalse(result.text.contains("怎么说呢"))
    }

    func testReviewerIssueWithoutSourceEvidenceCannotTriggerBlindRepair() async throws {
        let source = "不要照抄证据不足的复核问题。"
        let request = makeRequest(source)
        let spanIDs = evidenceSpanIDs(for: request)
        let malformedReview = VoicePolishReviewerResult(
            verdict: "repair",
            issues: [VoicePolishReviewerIssue(
                type: "missing",
                severity: "major",
                unitIds: ["u1"],
                sourceSpanIds: [],
                draftSpan: nil,
                repairInstruction: "补充没有来源锚点的内容"
            )]
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(finalMeaning: source, spanIDs: spanIDs)),
            try encoded(draft(source)),
            try encoded(malformedReview),
        ])

        let result = await VoicePolishLedgerPipeline(
            client: client,
            config: config
        ).process(request)

        XCTAssertTrue(result.text == nil)
        XCTAssertEqual(result.attempts, 3)
        XCTAssertEqual(result.failureStage, .reviewing)
    }

    func testSourceBoundPercentageCannotDisappearFromDraft() async throws {
        let source = "原计划灰度 10%，今晚不要上线，明早再决定。"
        let wrong = "今晚不要上线，明早再决定。"
        let repaired = "原计划灰度 10%，今晚不要上线，明早再决定。"
        let request = makeRequest(source, scene: .workChat)
        let spanIDs = evidenceSpanIDs(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "claim",
            deliveryRole: "recipient_content",
            finalMeaning: source,
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "confirmed",
            exactTokens: [],
            surfaceTokens: []
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(unit: unit)),
            try encoded(draft(wrong)),
            try encoded(passReview()),
            try encoded(draft(repaired)),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(client: client, config: config).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repaired)
        XCTAssertEqual(result.llmAttemptCount, 5)
        let requests = await client.requests()
        XCTAssertEqual(requests.count, 5)
        let repairRequest = requests.dropFirst(3).first
        XCTAssertTrue(
            repairRequest?.user.contains("10%") == true
                || repairRequest?.user.contains("10 %") == true
        )
    }

    func testFirstPersonDraftCannotBecomeUserInstructionLayer() async throws {
        let source = "灵建这个名字还没确认，先保留，别替我猜。"
        let wrong = "灵建这个名字还没确认，先保留，别替用户猜测。"
        let request = makeRequest(source, scene: .workChat)
        let spanIDs = evidenceSpanIDs(for: request)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "constraint",
            deliveryRole: "recipient_content",
            finalMeaning: source,
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "pending",
            exactTokens: [],
            surfaceTokens: []
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(unit: unit)),
            try encoded(draft(wrong)),
            try encoded(passReview()),
            try encoded(draft(source)),
            try encoded(passReview()),
        ])

        let result = await VoicePolishPipeline(client: client, config: config).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 5)
        let requests = await client.requests()
        XCTAssertTrue(requests[3].user.contains("第一人称"))
    }

    func testLedgerHasOneBoundedTotalDeadline() async {
        let request = makeRequest(dailySource("总时限"))
        let client = LedgerScriptedLLM(responses: [])

        let result = await VoicePolishLedgerPipeline(
            client: client,
            config: config,
            totalTimeout: .seconds(1)
        ).process(request)

        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertEqual(result.attempts, 1)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    private func makeRequest(
        _ source: String,
        scene: WritingScene = .document,
        resolvedEntities: [ResolvedEntity] = []
    ) -> VoicePolishRequest {
        VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: source,
                segments: [RecognitionSegment(
                    id: "s1",
                    text: source,
                    startTimeMs: 0,
                    endTimeMs: 8_000,
                    confidence: 0.98,
                    isFinal: true
                )],
                durationMs: 8_000,
                provider: .volcano
            ),
            context: WritingContext(scene: scene, level: .metadataOnly, safety: .unknown),
            preferences: UserPolishPreferences(additionalRequirements: ""),
            qualityMode: .automatic,
            resolvedEntities: resolvedEntities
        )
    }

    private func ledger(
        finalMeaning: String,
        spanIDs: [String] = ["s1"]
    ) -> VoicePolishIntentLedger {
        ledger(unit: VoicePolishLedgerUnit(
            id: "u1",
            kind: "claim",
            deliveryRole: "recipient_content",
            finalMeaning: finalMeaning,
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "confirmed",
            exactTokens: [],
            surfaceTokens: []
        ))
    }

    private func ledger(unit: VoicePolishLedgerUnit) -> VoicePolishIntentLedger {
        VoicePolishIntentLedger(
            audience: [],
            units: [unit],
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [],
            dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "paragraphs",
                orderedUnitIds: [unit.id]
            )
        )
    }

    private func ledger(spans: [VoicePolishEvidenceSpan]) -> VoicePolishIntentLedger {
        let units = spans.enumerated().map { index, span in
            VoicePolishLedgerUnit(
                id: "u\(index + 1)",
                kind: "claim",
                deliveryRole: "recipient_content",
                finalMeaning: span.text,
                sourceSpanIds: [span.id],
                status: "keep",
                modality: "confirmed",
                exactTokens: [],
                surfaceTokens: []
            )
        }
        return VoicePolishIntentLedger(
            audience: [],
            units: units,
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [],
            dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "paragraphs",
                orderedUnitIds: units.map(\.id)
            )
        )
    }

    private func draft(
        _ text: String,
        unitID: String = "u1"
    ) -> VoicePolishLedgerDraftDocument {
        VoicePolishLedgerDraftDocument(fragments: [VoicePolishLedgerDraftFragment(
            id: "f_\(unitID)",
            unitIds: [unitID],
            text: text
        )])
    }

    private func passReview() -> VoicePolishReviewerResult {
        VoicePolishReviewerResult(verdict: "pass", issues: [])
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func evidenceSpanIDs(for request: VoicePolishRequest) -> [String] {
        VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request).map(\.id)
    }

    private func dailySource(_ focus: String) -> String {
        ([focus] + (1...16).map {
            "第\($0)部分需要保留原始事实、负责人、时间边界和待确认状态，清理口述重复后再形成自然段。"
        }).joined()
    }

}

private actor LedgerScriptedLLM: LLMClient {
    private var responses: [String]
    private var recorded: [LLMRequest] = []
    private var configuredModels: [String] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        recorded.append(request)
        configuredModels.append(config.model)
        guard !responses.isEmpty else { throw LedgerScriptedLLMError.noResponse }
        return LLMResponse(text: responses.removeFirst(), model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        _ = text
        _ = prompt
        _ = context
        _ = config
        throw LedgerScriptedLLMError.noResponse
    }

    func warmUp(baseURL: String) async { _ = baseURL }

    func requests() -> [LLMRequest] { recorded }
    func requestCount() -> Int { recorded.count }
    func models() -> [String] { configuredModels }
}

private enum LedgerScriptedLLMError: Error {
    case noResponse
}
