import XCTest
@testable import Muse

final class VoicePolishLedgerPipelineTests: XCTestCase {
    private let config = LLMConfig(
        apiKey: "test",
        model: "mock-model",
        baseURL: "https://example.com/v1"
    )

    private func productionLedgerPipeline(
        _ client: any LLMClient,
        config: LLMConfig? = nil
    ) -> VoicePolishPipeline {
        VoicePolishPipeline(
            client: client,
            config: config ?? self.config,
            ledgerMinimumCharacterCount: 0
        )
    }

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

        let result = await productionLedgerPipeline(client).process(request)

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
        XCTAssertTrue(requests.allSatisfy { $0.options.reasoningPolicy == .disabled })
    }

    func testRecipientSurfaceTokensAreLocallyIgnoredInsteadOfTriggeringPlanRepair() async throws {
        let source = "明天开会，请团队准时参加，不要迟到。"
        let finalText = source
        let request = makeRequest(source, scene: .workChat)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: finalText,
            sourceSpanIds: evidenceSpanIDs(for: request),
            status: "keep",
            modality: "confirmed",
            exactTokens: [],
            surfaceTokens: ["请团队准时参加"]
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(ledger(unit: unit)),
            try encoded(draft(finalText)),
            try encoded(passReview()),
        ])

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, finalText)
        XCTAssertEqual(result.llmAttemptCount, 3)
        XCTAssertNil(result.plannerValidationTrace)
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

        let result = await productionLedgerPipeline(client).process(request)

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

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repaired)
        XCTAssertEqual(result.llmAttemptCount, 5)
        let requests = await client.requests()
        XCTAssertTrue(requests[3].user.contains("不得改成事情确定不会发生"))
    }

    func testPlannerKeepsNonCommitmentOutOfCorrectionRelations() {
        XCTAssertTrue(
            VoicePolishLedgerPrompts.planner.contains(
                "不要承诺/不能保证/不要假设/禁止"
            )
        )
        XCTAssertTrue(
            VoicePolishLedgerPrompts.plannerRepair.contains(
                "correction_subject_not_bound_to_old_value"
            )
        )
        XCTAssertTrue(
            VoicePolishLedgerPrompts.plannerRepair.contains(
                "必须删除对应伪 correction"
            )
        )
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

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repaired)
        XCTAssertEqual(result.llmAttemptCount, 5)
        let requests = await client.requests()
        XCTAssertTrue(requests[0].user.contains("北辰研究"))
        XCTAssertTrue(requests[3].user.contains("恢复已确认的标准实体"))
    }

    func testVerifiedContextMappingIsNotDuplicatedAsSourceCorrection() throws {
        let source = "项目名我口述成北城研究，但选中的标题是准的，按标题写。"
        let entity = ResolvedEntity(
            surfaceText: "北城研究",
            canonical: "北辰研究",
            sourceSegmentIDs: ["s1"],
            candidateSource: .authorizedContext,
            confidence: 0.98
        )
        let request = makeRequest(source, scene: .aiPrompt, resolvedEntities: [entity])
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let mappings = VoicePolishLedgerIntegrityValidator.verifiedMappings(
            request: request,
            spans: spans
        )
        let spanIDs = spans.map(\.id)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "项目名使用北辰研究", sourceSpanIds: spanIDs,
                status: "replace", modality: "confirmed",
                exactTokens: ["北辰研究"], surfaceTokens: []
            )],
            corrections: [VoicePolishLedgerCorrection(
                subject: "项目名", oldValue: "北城研究", finalValue: "北辰研究",
                oldSpanIds: spanIDs, finalSpanIds: spanIDs,
                renderingPolicy: "final_only"
            )],
            conditionals: [], technicalTokenMappings: [], dictatedSymbolMappings: [],
            contextMappings: mappings,
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: ["u1"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: mappings,
            requiredLogicCues: [],
            scene: .aiPrompt
        )

        XCTAssertTrue(validated.corrections.isEmpty)
        XCTAssertEqual(validated.contextMappings, mappings)
        XCTAssertEqual(validated.units[0].finalMeaning, "项目名使用北辰研究")
    }

    func testInvalidContextAliasCorrectionIsDroppedInsteadOfForcingPlanRepair() throws {
        let source = "项目名我口述成北城研究，但选中的标题是准的，按标题写。"
        let entity = ResolvedEntity(
            surfaceText: "北城研究", canonical: "北辰研究", sourceSegmentIDs: ["s1"],
            candidateSource: .authorizedContext, confidence: 0.98
        )
        let request = makeRequest(source, scene: .aiPrompt, resolvedEntities: [entity])
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let mappings = VoicePolishLedgerIntegrityValidator.verifiedMappings(
            request: request,
            spans: spans
        )
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "项目名：北辰研究", sourceSpanIds: spans.map(\.id),
                status: "replace", modality: "confirmed", exactTokens: ["北辰研究"],
                surfaceTokens: []
            )],
            corrections: [VoicePolishLedgerCorrection(
                subject: "项目名", oldValue: "北城研究", finalValue: "按选中标题",
                oldSpanIds: spans.map(\.id), finalSpanIds: spans.map(\.id),
                renderingPolicy: "final_only"
            )],
            conditionals: [], technicalTokenMappings: [], dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: ["u1"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: mappings,
            requiredLogicCues: [],
            scene: .aiPrompt
        )

        XCTAssertTrue(validated.corrections.isEmpty)
        XCTAssertTrue(validated.units[0].finalMeaning.contains("北辰研究"))
    }

    func testAIPromptUnitWithInventedFactFallsBackToItsOwnSourceEvidence() throws {
        let request = makeRequest("目标是比较五款工具。", scene: .aiPrompt)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "目标是比较五款工具，预算 999 元。",
                sourceSpanIds: spans.map(\.id), status: "keep", modality: "confirmed",
                exactTokens: [], surfaceTokens: []
            )],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: ["u1"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .aiPrompt
        )

        XCTAssertEqual(validated.units[0].finalMeaning, spans[0].text)
        XCTAssertFalse(validated.units[0].finalMeaning.contains("999"))
    }

    func testSelectedAIPromptTitleSurvivesWhenItsInstructionUnitIsRemoved() throws {
        let source = "项目名我口述成北城研究，但选中的标题是准的，按标题写。目标是比较五款工具。"
        let entity = ResolvedEntity(
            surfaceText: "北城研究",
            canonical: "北辰研究",
            sourceSegmentIDs: ["s1"],
            candidateSource: .authorizedContext,
            confidence: 0.98
        )
        let request = makeRequest(source, scene: .aiPrompt, resolvedEntities: [entity])
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        XCTAssertEqual(spans.count, 2)
        let mappings = VoicePolishLedgerIntegrityValidator.verifiedMappings(
            request: request,
            spans: spans
        )
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [
                VoicePolishLedgerUnit(
                    id: "editor", kind: "constraint", deliveryRole: "editor_directive",
                    finalMeaning: spans[0].text, sourceSpanIds: [spans[0].id], status: "remove",
                    modality: "confirmed", exactTokens: [], surfaceTokens: ["按标题写"]
                ),
                VoicePolishLedgerUnit(
                    id: "goal", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: spans[1].text, sourceSpanIds: [spans[1].id], status: "keep",
                    modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
            ],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: ["goal"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: mappings,
            requiredLogicCues: [],
            scene: .aiPrompt
        )

        let titleUnit = try XCTUnwrap(validated.units.first {
            $0.deliveryRole == "recipient_content" && $0.finalMeaning.contains("北辰研究")
        })
        XCTAssertEqual(titleUnit.exactTokens, ["北辰研究"])
        XCTAssertEqual(validated.structure.orderedUnitIds.first, titleUnit.id)
        XCTAssertEqual(validated.contextMappings, mappings)
    }

    func testCurrentAIPromptEditingInstructionIsRemovedFromRecipientStructure() throws {
        let source = "帮我把研究要求整理成可直接给 AI 的 Prompt。先别开始研究，只整理任务。目标是比较五款工具。"
        let request = makeRequest(source, scene: .aiPrompt)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        XCTAssertEqual(spans.count, 3)
        let editor = VoicePolishLedgerUnit(
            id: "editor", kind: "constraint", deliveryRole: "recipient_content",
            finalMeaning: "先别开始研究，只整理任务", sourceSpanIds: [spans[0].id, spans[1].id],
            status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        let goal = VoicePolishLedgerUnit(
            id: "goal", kind: "action", deliveryRole: "recipient_content",
            finalMeaning: "目标是比较五款工具", sourceSpanIds: [spans[2].id],
            status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        let plan = VoicePolishIntentLedger(
            audience: [], units: [editor, goal], corrections: [], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "ai_prompt", orderedUnitIds: ["editor", "goal"]
            )
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .aiPrompt
        )

        XCTAssertEqual(validated.units[0].deliveryRole, "editor_directive")
        XCTAssertEqual(validated.units[0].status, "remove")
        XCTAssertEqual(validated.units[0].surfaceTokens, ["先别开始研究，只整理任务"])
        XCTAssertEqual(validated.structure.orderedUnitIds, ["goal"])
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

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 5)
        XCTAssertEqual(result.failureReason, .validationFailed)
        XCTAssertTrue(result.validationCodes.contains(.semanticDecisionUnverified))
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 5)
    }

    func testVeryShortTextKeepsLightPathWhileRiskyMediumTextUsesLedger() {
        XCTAssertFalse(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "如果还是不行，让他把系统版本和错误截图发过来。",
            scene: .customerSupport
        )))
        XCTAssertFalse(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "跟团队说会议改到周四下午。",
            scene: .workChat
        )))
        XCTAssertFalse(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "只有客户确认，才能对外发布。",
            scene: .workChat
        )))
        XCTAssertFalse(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "不要覆盖安装，建议先跑测试。",
            scene: .workChat
        )))
        XCTAssertFalse(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            "你到哪了",
            scene: .chat
        )))
        let riskyMedium = "如果还是不行，让他把系统版本、错误截图、复现步骤和最近一次操作时间发过来，"
            + "同时说明不要承诺当天一定解决，只需确认我们已经收到并会继续排查，明天下午前再同步一次进展。"
        XCTAssertGreaterThanOrEqual(riskyMedium.count, 80)
        XCTAssertTrue(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            riskyMedium,
            scene: .customerSupport
        )))
        XCTAssertTrue(VoicePolishLedgerPipeline.shouldUse(for: makeRequest(
            dailySource("日常长文路由"),
            scene: .document
        )))
    }

    func testMissingConditionalCueIsRecoveredLocallyWithoutPlannerRetry() async throws {
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
        let finalText = "如果问题仍未解决，请把系统版本和错误截图发给我们。"
        let client = LedgerScriptedLLM(responses: [
            try encoded(invalid),
            try encoded(draft(finalText)),
            try encoded(passReview()),
        ])

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, finalText)
        XCTAssertEqual(result.llmAttemptCount, 3)
        let requests = await client.requests()
        XCTAssertEqual(
            requests.map(\.task),
            [.voicePolishAnalyze, .voicePolishRender, .voicePolishAnalyze]
        )
    }

    func testPlannerFailureReportsStableEvidenceDiagnostic() async throws {
        let request = makeRequest(dailySource("证据诊断"))
        let initiallyInvalid = VoicePolishIntentLedger(
            audience: [],
            units: [],
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [],
            dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: [])
        )
        let repairedButInvalid = ledger(unit: VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: "整理证据诊断",
            sourceSpanIds: ["不存在的证据"],
            status: "keep",
            modality: "confirmed",
            exactTokens: [],
            surfaceTokens: []
        ))
        let client = LedgerScriptedLLM(responses: [
            try encoded(initiallyInvalid),
            try encoded(repairedButInvalid),
        ])

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.failureReason, .validationFailed)
        XCTAssertEqual(
            result.plannerValidationTrace,
            VoicePolishPlannerValidationTrace(
                initialCode: "units_empty",
                repairedCode: "unit_identity_enum_or_source_span_invalid"
            )
        )
        XCTAssertEqual(result.llmAttemptCount, 2)
    }

    func testPlannerInvalidJSONReportsStableDecodeTrace() async throws {
        let request = makeRequest(dailySource("JSON 诊断"))
        let client = LedgerScriptedLLM(responses: ["{}", "{}"])

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(
            result.plannerValidationTrace,
            VoicePolishPlannerValidationTrace(
                initialCode: "ledger_json_decode_failed",
                repairedCode: "ledger_json_decode_failed"
            )
        )
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

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, "执行scripts/package-app.sh，然后检查codesign。")
        XCTAssertEqual(result.llmAttemptCount, 3)
    }

    func testValidatedTokenMappingsCanBackUnitMeaningAndExactTokens() throws {
        let source = "检查 Voice Pol ish 后执行scripts斜杠package短横线app点sh。"
        let request = makeRequest(source, scene: .code)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let spanIDs = spans.map(\.id)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: "检查 VoicePolish 后执行 scripts/package-app.sh。",
            sourceSpanIds: spanIDs,
            status: "keep",
            modality: "confirmed",
            exactTokens: ["VoicePolish", "scripts/package-app.sh"],
            surfaceTokens: []
        )
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [unit],
            corrections: [],
            conditionals: [],
            technicalTokenMappings: [VoicePolishLedgerTokenMapping(
                alias: "Voice Pol ish",
                canonical: "VoicePolish",
                sourceSpanIds: spanIDs,
                transform: "remove_internal_ascii_whitespace"
            )],
            dictatedSymbolMappings: [VoicePolishLedgerTokenMapping(
                alias: "scripts斜杠package短横线app点sh",
                canonical: "scripts/package-app.sh",
                sourceSpanIds: spanIDs,
                transform: "spoken_ascii_symbols"
            )],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        )

        XCTAssertEqual(validated.units[0].exactTokens, ["VoicePolish", "scripts/package-app.sh"])
    }

    func testValidatedTokenMappingCannotBackAnotherSourceSpan() throws {
        let request = makeRequest("检查 Voice Pol ish。然后执行测试。", scene: .code)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        XCTAssertEqual(spans.count, 2)
        let units = [
            VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: spans[0].text, sourceSpanIds: [spans[0].id], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            ),
            VoicePolishLedgerUnit(
                id: "u2", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "执行 VoicePolish 测试。", sourceSpanIds: [spans[1].id],
                status: "keep", modality: "confirmed", exactTokens: ["VoicePolish"],
                surfaceTokens: []
            ),
        ]
        let plan = VoicePolishIntentLedger(
            audience: [], units: units, corrections: [], conditionals: [],
            technicalTokenMappings: [VoicePolishLedgerTokenMapping(
                alias: "Voice Pol ish", canonical: "VoicePolish",
                sourceSpanIds: [spans[0].id], transform: "remove_internal_ascii_whitespace"
            )],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "paragraphs", orderedUnitIds: units.map(\.id)
            )
        )

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        ))
    }

    func testValidatedTokenMappingCannotFanOutCanonicalAcrossRedundantSpans() throws {
        let request = makeRequest("检查 Voice Pol ish。然后执行测试。", scene: .code)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        XCTAssertEqual(spans.count, 2)
        let units = [
            VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: spans[0].text, sourceSpanIds: [spans[0].id], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            ),
            VoicePolishLedgerUnit(
                id: "u2", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "执行 VoicePolish 测试。", sourceSpanIds: [spans[1].id],
                status: "keep", modality: "confirmed", exactTokens: ["VoicePolish"],
                surfaceTokens: []
            ),
        ]
        let plan = VoicePolishIntentLedger(
            audience: [], units: units, corrections: [], conditionals: [],
            technicalTokenMappings: [VoicePolishLedgerTokenMapping(
                alias: "Voice Pol ish", canonical: "VoicePolish",
                sourceSpanIds: spans.map(\.id), transform: "remove_internal_ascii_whitespace"
            )],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "paragraphs", orderedUnitIds: units.map(\.id)
            )
        )

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        ))
    }

    func testSpokenCLIMappingsBackRealTestAndBuildCommands() throws {
        for (source, alias, canonical) in [
            (
                "执行swift test双横线filter VoicePolishPipelineTests。",
                "swift test双横线filter VoicePolishPipelineTests",
                "swift test --filter VoicePolishPipelineTests"
            ),
            (
                "执行swift build短横线c release。",
                "swift build短横线c release",
                "swift build -c release"
            ),
        ] {
            let request = makeRequest(source, scene: .code)
            let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
            let spanIDs = spans.map(\.id)
            let plan = VoicePolishIntentLedger(
                audience: [],
                units: [VoicePolishLedgerUnit(
                    id: "u1", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "执行\(canonical)。", sourceSpanIds: spanIDs,
                    status: "keep", modality: "confirmed", exactTokens: [canonical],
                    surfaceTokens: []
                )],
                corrections: [], conditionals: [], technicalTokenMappings: [],
                dictatedSymbolMappings: [VoicePolishLedgerTokenMapping(
                    alias: alias, canonical: canonical, sourceSpanIds: spanIDs,
                    transform: "spoken_cli_symbols"
                )],
                contextMappings: [],
                structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
            )

            XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
                plan,
                spans: spans,
                verifiedMappings: [],
                requiredLogicCues: [],
                scene: .code
            ))
        }
    }

    func testCanonicalNumberCanReformatButCannotInventExactFormatUnitOrCurrency() throws {
        let request = makeRequest("预算最后通过的是一万六。")
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let spanIDs = spans.map(\.id)
        func plan(finalMeaning: String, exactTokens: [String]) -> VoicePolishIntentLedger {
            ledger(unit: VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: finalMeaning, sourceSpanIds: spanIDs, status: "keep",
                modality: "confirmed", exactTokens: exactTokens, surfaceTokens: []
            ))
        }

        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(finalMeaning: "预算最后通过的是16000。", exactTokens: []),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(finalMeaning: "预算最后通过的是16000。", exactTokens: ["16000"]),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))

        let normalized = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(finalMeaning: "预算最后通过的是16000元。", exactTokens: []),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        )
        XCTAssertEqual(normalized.units[0].finalMeaning, "预算最后通过的是16000。")

        let reordered = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(finalMeaning: "最终通过的预算是16000元。", exactTokens: []),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        )
        XCTAssertEqual(reordered.units[0].finalMeaning, "最终通过的预算是16000。")
    }

    func testLedgerRejectsAddedRemovedSwappedUnitsAndCurrencies() throws {
        let rejectedPairs = [
            ("工期是三十天。", "工期是30年。"),
            ("预算是一万六元。", "预算是16000美元。"),
            ("工期是三十天。", "工期是30。"),
            ("预算是$16000。", "预算是￥16000。"),
            ("预算是1.6万美元。", "预算是16000元。"),
            ("工期30天，预算30元。", "工期30元，预算30天。"),
            ("工期30天，预算30元。", "预算30天，工期30元。"),
            ("工期30天，预算40元。", "工期30天。"),
            ("预算16000元。", "预算待定。"),
            ("30天交付。", "质保期30天。"),
            ("30天交付。", "30天质保。"),
            ("研发预算30元，运营预算30元。", "预算30元，预算30元。"),
        ]
        for (source, finalMeaning) in rejectedPairs {
            let request = makeRequest(source)
            let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
            let plan = ledger(unit: VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: finalMeaning, sourceSpanIds: spans.map(\.id), status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            ))

            XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
                plan,
                spans: spans,
                verifiedMappings: [],
                requiredLogicCues: [],
                scene: .document
            ))
        }

        let acceptedPairs = [
            ("工期是三十天。", "工期是30日。"),
            ("预算是$16000。", "预算是16000美元。"),
            ("预算是1.6万美元。", "预算是16000美元。"),
            ("预算是美元16000。", "预算是$16000。"),
            ("预算是人民币16000。", "预算是￥16000。"),
            ("工期30天，预算30元。", "预算30元，工期30天。"),
            ("项目周期30天。", "工期30天。"),
            ("预计工期30天。", "工期预计为30天。"),
            ("发布日期是2026-08-28。", "发布日期是2026年8月28日。"),
        ]
        for (source, finalMeaning) in acceptedPairs {
            let request = makeRequest(source)
            let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
            let plan = ledger(unit: VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: finalMeaning, sourceSpanIds: spans.map(\.id), status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            ))

            XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
                plan,
                spans: spans,
                verifiedMappings: [],
                requiredLogicCues: [],
                scene: .document
            ), "\(source) -> \(finalMeaning)")
        }
    }

    func testExplicitMeasurementCorrectionMayRemoveOnlyItsOldValue() throws {
        let spans = [
            VoicePolishEvidenceSpan(
                id: "old", segmentID: "s1", start: 0, end: 8,
                text: "工期原定三十天。", digest: "old"
            ),
            VoicePolishEvidenceSpan(
                id: "final", segmentID: "s2", start: 8, end: 19,
                text: "不对，最终工期改为二十天。", digest: "final"
            ),
        ]
        let unit = VoicePolishLedgerUnit(
            id: "u1", kind: "claim", deliveryRole: "recipient_content",
            finalMeaning: "最终工期为20天。", sourceSpanIds: ["old", "final"],
            status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        let correction = VoicePolishLedgerCorrection(
            subject: "工期", oldValue: "三十天", finalValue: "二十天",
            oldSpanIds: ["old"], finalSpanIds: ["final"], renderingPolicy: "final_only"
        )
        let correctedPlan = VoicePolishIntentLedger(
            audience: [], units: [unit], corrections: [correction], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )

        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            correctedPlan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))

        let unprovenPlan = VoicePolishIntentLedger(
            audience: [], units: [unit], corrections: [], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            unprovenPlan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))

        let wrongSubject = VoicePolishLedgerCorrection(
            subject: "上海项目工期", oldValue: "三十天", finalValue: "二十天",
            oldSpanIds: ["old"], finalSpanIds: ["final"], renderingPolicy: "final_only"
        )
        let wrongSubjectPlan = VoicePolishIntentLedger(
            audience: [], units: [unit], corrections: [wrongSubject], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            wrongSubjectPlan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))

        let finalBelongsToAnotherSubjectSpans = [
            VoicePolishEvidenceSpan(
                id: "beijing", segmentID: "s1", start: 0, end: 12,
                text: "北京项目工期原定30天。", digest: "beijing"
            ),
            VoicePolishEvidenceSpan(
                id: "shanghai", segmentID: "s2", start: 12, end: 24,
                text: "不对，上海项目工期确定为20天。", digest: "shanghai"
            ),
        ]
        let finalBelongsToAnotherSubject = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: "上海项目工期为20天。",
                sourceSpanIds: ["beijing", "shanghai"], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [VoicePolishLedgerCorrection(
                subject: "北京项目工期", oldValue: "30天", finalValue: "20天",
                oldSpanIds: ["beijing"], finalSpanIds: ["shanghai"],
                renderingPolicy: "final_only"
            )],
            conditionals: [], technicalTokenMappings: [], dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            finalBelongsToAnotherSubject,
            spans: finalBelongsToAnotherSubjectSpans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))

        let omittedSubjectSpans = [VoicePolishEvidenceSpan(
            id: "s1", segmentID: "s1", start: 0, end: 18,
            text: "工期先定30天，不对，改成20天。", digest: "s1"
        )]
        let omittedSubjectPlan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: "工期改为20天。", sourceSpanIds: ["s1"], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [VoicePolishLedgerCorrection(
                subject: "工期", oldValue: "30天", finalValue: "20天",
                oldSpanIds: ["s1"], finalSpanIds: ["s1"], renderingPolicy: "final_only"
            )],
            conditionals: [], technicalTokenMappings: [], dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )
        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            omittedSubjectPlan,
            spans: omittedSubjectSpans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))

        let unpunctuatedSpans = [VoicePolishEvidenceSpan(
            id: "s1", segmentID: "s1", start: 0, end: 33,
            text: "分析销售表先看最近十二个月不对我们数据只有九个月那就分析全部九个月",
            digest: "s1"
        )]
        let unpunctuatedPlan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "分析全部 9 个月数据。", sourceSpanIds: ["s1"],
                status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [VoicePolishLedgerCorrection(
                subject: "销售表分析范围", oldValue: "十二个月", finalValue: "九个月",
                oldSpanIds: ["s1"], finalSpanIds: ["s1"], renderingPolicy: "final_only"
            )],
            conditionals: [], technicalTokenMappings: [], dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )
        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            unpunctuatedPlan,
            spans: unpunctuatedSpans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .aiPrompt
        ))

        let interveningSubjectSpans = [VoicePolishEvidenceSpan(
            id: "s1", segmentID: "s1", start: 0, end: 34,
            text: "北京项目工期30天，上海项目工期40天，不对，改成20天。",
            digest: "s1"
        )]
        let wrongDistantCarryPlan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: "北京项目工期20天，上海项目工期40天。",
                sourceSpanIds: ["s1"], status: "keep", modality: "confirmed",
                exactTokens: [], surfaceTokens: []
            )],
            corrections: [VoicePolishLedgerCorrection(
                subject: "北京项目工期", oldValue: "30天", finalValue: "20天",
                oldSpanIds: ["s1"], finalSpanIds: ["s1"], renderingPolicy: "final_only"
            )],
            conditionals: [], technicalTokenMappings: [], dictatedSymbolMappings: [],
            contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
        )
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            wrongDistantCarryPlan,
            spans: interveningSubjectSpans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))
    }

    func testDeclaredStepCountUpdateRewritesOldTotalFromRecipientUnit() throws {
        let source = "部署要做三步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh等一下还有一步要检查codesign所以一共四步最后再启动应用"
        let request = makeRequest(source, scene: .code)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let allSpanIDs = spans.map(\.id)
        let correction = VoicePolishLedgerCorrection(
            subject: "部署步骤数", oldValue: "三步", finalValue: "四步",
            oldSpanIds: allSpanIDs, finalSpanIds: allSpanIDs,
            renderingPolicy: "final_only"
        )
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [
                VoicePolishLedgerUnit(
                    id: "header", kind: "claim", deliveryRole: "recipient_content",
                    finalMeaning: "部署要做三步。", sourceSpanIds: allSpanIDs,
                    status: "replace", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "test", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "运行 swift test。", sourceSpanIds: allSpanIDs,
                    status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "build", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "运行 swift build -c release。", sourceSpanIds: allSpanIDs,
                    status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "package", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "执行 scripts/package-app.sh。", sourceSpanIds: allSpanIDs,
                    status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "sign", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "检查 codesign。", sourceSpanIds: allSpanIDs,
                    status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "launch", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "完成四步后再启动应用。", sourceSpanIds: allSpanIDs,
                    status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
            ],
            corrections: [correction], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "mixed",
                orderedUnitIds: ["header", "test", "build", "package", "sign", "launch"],
                numberedUnitIds: ["test", "build", "package", "sign"]
            )
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        )

        XCTAssertEqual(validated.units[0].finalMeaning, "部署要做四步。")
        XCTAssertEqual(validated.structure.numberedUnitIds, ["test", "build", "package", "sign"])
    }

    func testDeclaredStepCountRepairsToMixedListWithoutNumberingLaunchAction() async throws {
        let source = "部署要做三步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh等一下还有一步要检查codesign所以一共四步最后再启动应用"
        let request = makeRequest(source, scene: .code)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let allSpanIDs = spans.map(\.id)
        let correction = VoicePolishLedgerCorrection(
            subject: "部署步骤数", oldValue: "三步", finalValue: "四步",
            oldSpanIds: allSpanIDs, finalSpanIds: allSpanIDs,
            renderingPolicy: "final_only"
        )
        func unit(_ id: String, _ meaning: String, kind: String = "action")
            -> VoicePolishLedgerUnit {
            VoicePolishLedgerUnit(
                id: id, kind: kind, deliveryRole: "recipient_content",
                finalMeaning: meaning, sourceSpanIds: allSpanIDs,
                status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
            )
        }
        let wrongPlan = VoicePolishIntentLedger(
            audience: [],
            units: [
                unit("old", "部署要做三步", kind: "claim"),
                unit("test", "第一跑 swift test"),
                unit("build", "第二跑 swift build -c release"),
                unit("package", "第三执行 scripts/package-app.sh"),
                unit("sign", "还有一步要检查 codesign"),
                unit("total", "所以一共四步", kind: "claim"),
                unit("launch", "最后再启动应用"),
            ],
            corrections: [correction], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "numbered_list",
                orderedUnitIds: ["old", "test", "build", "package", "sign", "total", "launch"]
            )
        )
        let repairedPlan = VoicePolishIntentLedger(
            audience: [],
            units: [
                unit("header", "部署共四步", kind: "claim"),
                unit("test", "运行 swift test"),
                unit("build", "运行 swift build -c release"),
                unit("package", "执行 scripts/package-app.sh"),
                unit("sign", "检查 codesign"),
                unit("launch", "完成四步后再启动应用"),
                VoicePolishLedgerUnit(
                    id: "process", kind: "style", deliveryRole: "editor_directive",
                    finalMeaning: "删除旧三步声明和补充过程", sourceSpanIds: allSpanIDs,
                    status: "remove", modality: "confirmed", exactTokens: [],
                    surfaceTokens: ["等一下还有一步"]
                ),
            ],
            corrections: [correction], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(
                kind: "mixed",
                orderedUnitIds: ["header", "test", "build", "package", "sign", "launch"],
                numberedUnitIds: ["test", "build", "package", "sign"]
            )
        )
        let draft = VoicePolishLedgerDraftDocument(fragments: [
            VoicePolishLedgerDraftFragment(id: "f_header", unitIds: ["header"], text: "部署共四步："),
            VoicePolishLedgerDraftFragment(id: "f_test", unitIds: ["test"], text: "运行 swift test"),
            VoicePolishLedgerDraftFragment(id: "f_build", unitIds: ["build"], text: "运行 swift build -c release"),
            VoicePolishLedgerDraftFragment(id: "f_package", unitIds: ["package"], text: "执行 scripts/package-app.sh"),
            VoicePolishLedgerDraftFragment(id: "f_sign", unitIds: ["sign"], text: "检查 codesign"),
            VoicePolishLedgerDraftFragment(id: "f_launch", unitIds: ["launch"], text: "完成后再启动应用。"),
        ])
        let client = LedgerScriptedLLM(responses: [
            try encoded(wrongPlan),
            try encoded(repairedPlan),
            try encoded(draft),
            try encoded(passReview()),
        ])

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 4)
        XCTAssertEqual(
            result.text,
            "部署共四步：\n\n1. 运行 swift test\n2. 运行 swift build -c release\n3. 执行 scripts/package-app.sh\n4. 检查 codesign\n\n完成后再启动应用。"
        )
        XCTAssertFalse(result.text.contains("三步"))
        let requests = await client.requests()
        XCTAssertTrue(requests[1].user.contains("declared_count_structure_invalid"))
        XCTAssertTrue((requests[1].system ?? "").contains("numbered_unit_ids"))
    }

    func testAudienceSurfaceTokenAndDirectModeCanBeMechanicallyRecovered() throws {
        let source = "我想给团队发一封完整的交接邮件。"
        let request = makeRequest(source, scene: .email)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = VoicePolishIntentLedger(
            audience: [VoicePolishLedgerAudience(
                text: "团队", sourceSpanIds: spans.map(\.id), surfaceTokens: [],
                deliveryMode: "recipient"
            )],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "向团队发送完整交接邮件", sourceSpanIds: spans.map(\.id),
                status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .email
        )

        XCTAssertEqual(validated.audience.first?.surfaceTokens, ["团队"])
        XCTAssertEqual(validated.audience.first?.deliveryMode, "direct_address")
    }

    func testSupersededOldNumberInstructionBecomesEditorDirective() throws {
        let source = "预算最开始有人提一万六千八，我这里更正一下，不对，最后通过的是一万六，旧数字不要写进纪要。"
        let request = makeRequest(source)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let correction = VoicePolishLedgerCorrection(
            subject: "预算", oldValue: "一万六千八", finalValue: "一万六",
            oldSpanIds: spans.map(\.id), finalSpanIds: spans.map(\.id),
            renderingPolicy: "final_only"
        )
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [
                VoicePolishLedgerUnit(
                    id: "u1", kind: "claim", deliveryRole: "recipient_content",
                    finalMeaning: "最终通过的预算是16000元。",
                    sourceSpanIds: spans.map(\.id), status: "replace", modality: "confirmed",
                    exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "u2", kind: "constraint", deliveryRole: "recipient_content",
                    finalMeaning: "旧数字一万六千八不要写进纪要。",
                    sourceSpanIds: spans.map(\.id), status: "keep", modality: "prohibited",
                    exactTokens: [], surfaceTokens: []
                ),
            ],
            corrections: [correction], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1", "u2"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        )

        XCTAssertEqual(validated.structure.orderedUnitIds, ["u1"])
        XCTAssertEqual(validated.units.first(where: { $0.id == "u2" })?.deliveryRole, "editor_directive")
        XCTAssertEqual(validated.units.first(where: { $0.id == "u1" })?.finalMeaning, "最终通过的预算是16000。")
    }

    func testBackwardCancellationInsideOneSegmentMayUseFinalSubject() throws {
        let spans = [
            VoicePolishEvidenceSpan(
                id: "final", segmentID: "s1", start: 0, end: 12,
                text: "录制安排在周三下午。", digest: "final"
            ),
            VoicePolishEvidenceSpan(
                id: "old", segmentID: "s1", start: 12, end: 30,
                text: "原来说周二录，这个取消。", digest: "old"
            ),
        ]
        let correction = VoicePolishLedgerCorrection(
            subject: "录制安排", oldValue: "周二", finalValue: "周三下午",
            oldSpanIds: ["old"], finalSpanIds: ["final"], renderingPolicy: "final_only"
        )
        let finalUnit = VoicePolishLedgerUnit(
            id: "u1", kind: "claim", deliveryRole: "recipient_content",
            finalMeaning: "录制安排在周三下午。", sourceSpanIds: ["final"],
            status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        let oldUnit = VoicePolishLedgerUnit(
            id: "u2", kind: "claim", deliveryRole: "recipient_content",
            finalMeaning: "原来说周二录，这个取消。", sourceSpanIds: ["old"],
            status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        let plan = VoicePolishIntentLedger(
            audience: [], units: [finalUnit, oldUnit], corrections: [correction], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1", "u2"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .email
        )
        XCTAssertEqual(validated.structure.orderedUnitIds, ["u1"])
        XCTAssertEqual(
            validated.units.first(where: { $0.id == "u2" })?.deliveryRole,
            "editor_directive"
        )

        let crossSegment = [
            spans[0],
            VoicePolishEvidenceSpan(
                id: "old", segmentID: "s2", start: 12, end: 30,
                text: "原来说周二录，这个取消。", digest: "old"
            ),
        ]
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: crossSegment,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .email
        ))
    }

    func testMeasurementCorrectionKeepsSameValueBoundToAnotherSubject() throws {
        let spans = [
            VoicePolishEvidenceSpan(
                id: "old", segmentID: "s1", start: 0, end: 22,
                text: "北京项目工期30天，上海项目工期先按30天。", digest: "old"
            ),
            VoicePolishEvidenceSpan(
                id: "final", segmentID: "s2", start: 22, end: 38,
                text: "不对，上海项目工期最终改为20天。", digest: "final"
            ),
        ]
        let correction = VoicePolishLedgerCorrection(
            subject: "上海项目工期", oldValue: "30天", finalValue: "20天",
            oldSpanIds: ["old"], finalSpanIds: ["final"], renderingPolicy: "final_only"
        )
        func plan(_ finalMeaning: String) -> VoicePolishIntentLedger {
            let unit = VoicePolishLedgerUnit(
                id: "u1", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: finalMeaning, sourceSpanIds: ["old", "final"],
                status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
            )
            return VoicePolishIntentLedger(
                audience: [], units: [unit], corrections: [correction], conditionals: [],
                technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
                structure: VoicePolishLedgerStructure(kind: "paragraphs", orderedUnitIds: ["u1"])
            )
        }

        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan("北京项目工期30天，上海项目工期最终为20天。"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan("上海项目工期最终为20天。"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))
    }

    func testOneEvidenceSpanMaySplitMeasurementsAcrossRecipientUnitsWithoutLosingCoverage() throws {
        let spans = [VoicePolishEvidenceSpan(
            id: "s1", segmentID: "s1", start: 0, end: 14,
            text: "工期30天，预算40元。", digest: "s1"
        )]
        let duration = VoicePolishLedgerUnit(
            id: "duration", kind: "claim", deliveryRole: "recipient_content",
            finalMeaning: "工期为30天。", sourceSpanIds: ["s1"], status: "keep",
            modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        let budget = VoicePolishLedgerUnit(
            id: "budget", kind: "claim", deliveryRole: "recipient_content",
            finalMeaning: "预算为40元。", sourceSpanIds: ["s1"], status: "keep",
            modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        func plan(_ units: [VoicePolishLedgerUnit]) -> VoicePolishIntentLedger {
            VoicePolishIntentLedger(
                audience: [], units: units, corrections: [], conditionals: [],
                technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
                structure: VoicePolishLedgerStructure(
                    kind: "paragraphs",
                    orderedUnitIds: units.map(\.id)
                )
            )
        }

        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan([duration, budget]),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan([duration]),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        ))
    }

    func testExcludedMeasurementDoesNotExemptOtherRecipientFactsInSameSpan() throws {
        let spans = [VoicePolishEvidenceSpan(
            id: "s1", segmentID: "s1", start: 0, end: 34,
            text: "工期30天，预算40元，内部成本50元不要对外披露。", digest: "s1"
        )]
        let excluded = VoicePolishLedgerUnit(
            id: "excluded", kind: "constraint", deliveryRole: "excluded_content",
            finalMeaning: "内部成本50元不得对外披露", sourceSpanIds: ["s1"],
            status: "remove", modality: "prohibited", exactTokens: [],
            surfaceTokens: ["内部成本50元"]
        )
        func plan(_ recipientMeaning: String) -> VoicePolishIntentLedger {
            let recipient = VoicePolishLedgerUnit(
                id: "recipient", kind: "claim", deliveryRole: "recipient_content",
                finalMeaning: recipientMeaning, sourceSpanIds: ["s1"], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )
            return VoicePolishIntentLedger(
                audience: [], units: [recipient, excluded], corrections: [], conditionals: [],
                technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
                structure: VoicePolishLedgerStructure(
                    kind: "paragraphs",
                    orderedUnitIds: ["recipient"]
                )
            )
        }

        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan("工期30天，预算40元。"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .customerSupport
        ))
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan("工期30天。"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .customerSupport
        ))
    }

    func testRepeatedBareMeasurementCannotExcludeRecipientRelation() throws {
        let spans = [VoicePolishEvidenceSpan(
            id: "s1", segmentID: "s1", start: 0, end: 32,
            text: "客户工期30天，内部保留期30天不要对外披露。", digest: "s1"
        )]
        let recipient = VoicePolishLedgerUnit(
            id: "recipient", kind: "claim", deliveryRole: "recipient_content",
            finalMeaning: "已收到。", sourceSpanIds: ["s1"], status: "keep",
            modality: "confirmed", exactTokens: [], surfaceTokens: []
        )
        func plan(excludedToken: String, recipientMeaning: String) -> VoicePolishIntentLedger {
            let recipientUnit = VoicePolishLedgerUnit(
                id: recipient.id, kind: recipient.kind, deliveryRole: recipient.deliveryRole,
                finalMeaning: recipientMeaning, sourceSpanIds: recipient.sourceSpanIds,
                status: recipient.status, modality: recipient.modality,
                exactTokens: recipient.exactTokens, surfaceTokens: recipient.surfaceTokens
            )
            let excluded = VoicePolishLedgerUnit(
                id: "excluded", kind: "constraint", deliveryRole: "excluded_content",
                finalMeaning: "内部保留期30天不得对外披露", sourceSpanIds: ["s1"],
                status: "remove", modality: "prohibited", exactTokens: [],
                surfaceTokens: [excludedToken]
            )
            return VoicePolishIntentLedger(
                audience: [], units: [recipientUnit, excluded], corrections: [],
                conditionals: [], technicalTokenMappings: [], dictatedSymbolMappings: [],
                contextMappings: [],
                structure: VoicePolishLedgerStructure(
                    kind: "paragraphs", orderedUnitIds: ["recipient"]
                )
            )
        }

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(excludedToken: "30天", recipientMeaning: "已收到。"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .customerSupport
        ))
        XCTAssertNoThrow(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(excludedToken: "内部保留期30天", recipientMeaning: "客户工期30天。"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .customerSupport
        ))
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(excludedToken: "内部保留期", recipientMeaning: "客户工期30天。"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .customerSupport
        ))
    }

    func testDateExtractorIgnoresDateLikeSubstringInsideIdentifier() {
        let segments = [RecognitionSegment(
            id: "s1",
            text: "版本标识 build2026-08-28rc1，发布日期2026-08-28已确认。",
            startTimeMs: 0,
            endTimeMs: 1_000,
            confidence: 1,
            isFinal: true
        )]
        let dateFacts = ProtectedFactExtractor.extract(from: segments).filter { $0.kind == .date }

        XCTAssertEqual(dateFacts.count, 1)
        XCTAssertEqual(dateFacts.first?.canonicalValue, "2026-08-28")
    }

    func testInitialPlannerTransientFailureRetriesSameModelOnce() async throws {
        let source = "明天开会，请团队准时参加，不要迟到。"
        let request = makeRequest(source, scene: .workChat)
        let validPlan = ledger(finalMeaning: source, spanIDs: evidenceSpanIDs(for: request))
        let client = LedgerTransientPlannerLLM(responses: [
            try encoded(validPlan),
            try encoded(draft(source)),
            try encoded(passReview()),
        ])
        let selected = LLMConfig(
            apiKey: "test",
            model: "deepseek-v4-flash",
            baseURL: "https://api.deepseek.com"
        )

        let result = await productionLedgerPipeline(client, config: selected).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.llmAttemptCount, 4)
        let requestCount = await client.requestCount()
        let models = await client.models()
        XCTAssertEqual(requestCount, 4)
        XCTAssertEqual(models, Array(repeating: "deepseek-v4-flash", count: 4))
        let requests = await client.requests()
        XCTAssertEqual(requests.first?.options.maxOutputTokens, 8_192)
    }

    func testInitialPlannerRetriesRealTransportAndServerFailuresButNotAuthentication() async throws {
        let source = "明天开会，请团队准时参加，不要迟到。"
        let request = makeRequest(source, scene: .workChat)
        let validPlan = ledger(finalMeaning: source, spanIDs: evidenceSpanIDs(for: request))
        let successfulResponses = [
            try encoded(validPlan),
            try encoded(draft(source)),
            try encoded(passReview()),
        ]

        for failure in [
            LedgerTransientFailure.networkConnectionLost,
            LedgerTransientFailure.requestRejected503,
        ] {
            let client = LedgerTransientPlannerLLM(
                responses: successfulResponses,
                initialFailure: failure
            )
            let result = await productionLedgerPipeline(client).process(request)
            XCTAssertFalse(result.usedFallback)
            XCTAssertEqual(result.llmAttemptCount, 4)
            let requestCount = await client.requestCount()
            XCTAssertEqual(requestCount, 4)
        }

        let unauthorized = LedgerTransientPlannerLLM(
            responses: successfulResponses,
            initialFailure: .requestRejected401
        )
        let failed = await productionLedgerPipeline(unauthorized).process(request)
        XCTAssertTrue(failed.usedFallback)
        XCTAssertEqual(failed.llmAttemptCount, 1)
        let unauthorizedRequestCount = await unauthorized.requestCount()
        XCTAssertEqual(unauthorizedRequestCount, 1)

        let legacyUnauthorized = LedgerTransientPlannerLLM(
            responses: successfulResponses,
            initialFailure: .requestFailed401
        )
        let legacyFailed = await productionLedgerPipeline(legacyUnauthorized).process(request)
        XCTAssertTrue(legacyFailed.usedFallback)
        XCTAssertEqual(legacyFailed.llmAttemptCount, 1)
        let legacyUnauthorizedRequestCount = await legacyUnauthorized.requestCount()
        XCTAssertEqual(legacyUnauthorizedRequestCount, 1)
    }

    func testTransientPlannerRetryStillLeavesRoomForTargetedRepairAndConfirmation() async throws {
        let source = "周五上午先发内部试看，邮件里不要承诺周五对外发布。"
        let wrong = "周五上午先发内部试看，我们不会在周五对外发布。"
        let repaired = "周五上午先发内部试看，邮件里不要承诺周五对外发布。"
        let request = makeRequest(source)
        let unit = VoicePolishLedgerUnit(
            id: "u1",
            kind: "action",
            deliveryRole: "recipient_content",
            finalMeaning: source,
            sourceSpanIds: evidenceSpanIDs(for: request),
            status: "keep",
            modality: "confirmed",
            exactTokens: ["周五上午"],
            surfaceTokens: []
        )
        let client = LedgerTransientPlannerLLM(responses: [
            try encoded(ledger(unit: unit)),
            try encoded(draft(wrong)),
            try encoded(passReview()),
            try encoded(draft(repaired)),
            try encoded(passReview()),
        ], initialFailure: .networkConnectionLost)

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.text, repaired)
        XCTAssertEqual(result.llmAttemptCount, 6)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 6)
    }

    func testTransientPlannerRetryAndSchemaRepairShareOneRecoverySlot() async throws {
        let source = "明天开会，请团队准时参加，不要迟到。"
        let request = makeRequest(source, scene: .workChat)
        let invalidPlan = VoicePolishIntentLedger(
            audience: [], units: [], corrections: [], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: [])
        )
        let client = LedgerTransientPlannerLLM(responses: [try encoded(invalidPlan)])

        let result = await productionLedgerPipeline(client).process(request)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.llmAttemptCount, 2)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(
            result.plannerValidationTrace,
            VoicePolishPlannerValidationTrace(initialCode: "units_empty", repairedCode: nil)
        )
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

    func testLedgerRespectsSelectedModelForGenerationAndReview() {
        let flash = LLMConfig(
            apiKey: "test",
            model: "deepseek-v4-flash",
            baseURL: "https://api.deepseek.com"
        )
        XCTAssertEqual(
            VoicePolishLedgerPipeline.qualityConfig(for: flash).model,
            "deepseek-v4-flash"
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
        XCTAssertEqual(
            VoicePolishLedgerPipeline.reviewConfig(for: custom).model,
            "deepseek-v4-flash"
        )
    }

    func testOfficialDeepSeekKeepsSelectedModelAcrossColdReview() async throws {
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

        let result = await productionLedgerPipeline(client, config: official).process(request)

        XCTAssertFalse(result.usedFallback)
        let models = await client.models()
        XCTAssertEqual(models, Array(repeating: "deepseek-v4-flash", count: 3))
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

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        )
        XCTAssertTrue(validated.technicalTokenMappings.isEmpty)
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
            let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
                ledger,
                spans: spans,
                verifiedMappings: [],
                requiredLogicCues: [],
                scene: .code
            )
            XCTAssertTrue(validated.technicalTokenMappings.isEmpty)
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

    func testLocalTokenMappingsRecoverRealCoreCodeInputsDespitePlannerArrays() throws {
        for (source, finalMeaning, exactTokens) in [
            (
                "记录一个bug在Muse斜杠VoicePolish斜杠VoicePolishPipeline点swift里长文本超过两千零四十八token的时候会回退原文复现命令是swift test双横线filter VoicePolishPipelineTests先别改路径和命令",
                "记录长文本超过2048 token时回退原文的问题，路径为 Muse/VoicePolish/VoicePolishPipeline.swift，复现命令为 swift test --filter VoicePolishPipelineTests。",
                ["Muse/VoicePolish/VoicePolishPipeline.swift", "swift test --filter VoicePolishPipelineTests"]
            ),
            (
                "部署要做四步第一跑swift test第二跑swift build短横线c release第三执行scripts斜杠package短横线app点sh第四检查codesign最后再启动应用",
                "部署检查包括 swift test、swift build -c release、scripts/package-app.sh 和 codesign，完成后再启动应用。",
                ["swift test", "swift build -c release", "scripts/package-app.sh", "codesign"]
            ),
        ] {
            let request = makeRequest(source, scene: .code)
            let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
            let unit = VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: finalMeaning, sourceSpanIds: spans.map(\.id), status: "keep",
                modality: "confirmed", exactTokens: exactTokens, surfaceTokens: []
            )
            let plannerInventedMappings = [VoicePolishLedgerTokenMapping(
                alias: "git status", canonical: "gitstatus",
                sourceSpanIds: spans.map(\.id), transform: "remove_internal_ascii_whitespace"
            )]
            let plan = VoicePolishIntentLedger(
                audience: [], units: [unit], corrections: [], conditionals: [],
                technicalTokenMappings: plannerInventedMappings,
                dictatedSymbolMappings: [], contextMappings: [],
                structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
            )

            let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
                plan,
                spans: spans,
                verifiedMappings: [],
                requiredLogicCues: [],
                scene: .code
            )
            XCTAssertTrue(validated.technicalTokenMappings.isEmpty)
            XCTAssertFalse(validated.dictatedSymbolMappings.isEmpty)
            XCTAssertEqual(validated.units[0].exactTokens, exactTokens)
        }
    }

    func testPartialExactTokensCollapseToFullVerifiedPathAndCommand() throws {
        let source = "记录一个bug在Muse斜杠VoicePolish斜杠VoicePolishPipeline点swift里，复现命令是swift test双横线filter VoicePolishPipelineTests。"
        let request = makeRequest(source, scene: .code)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "在 Muse/VoicePolish/VoicePolishPipeline.swift 中记录问题，并运行 swift test --filter VoicePolishPipelineTests。",
                sourceSpanIds: spans.map(\.id), status: "keep", modality: "confirmed",
                exactTokens: ["VoicePolishPipeline.swift", "--filter"], surfaceTokens: []
            )],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .code
        )

        XCTAssertEqual(Set(validated.units[0].exactTokens), Set([
            "Muse/VoicePolish/VoicePolishPipeline.swift",
            "swift test --filter VoicePolishPipelineTests",
        ]))
    }

    func testAmbiguousPartialExactTokenCannotChooseBetweenTwoCommands() throws {
        let request = makeRequest(
            "先执行swift test双横线filter VoicePolishPipelineTests。再执行swift test双横线filter VoicePolishCoreTests。",
            scene: .code
        )
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        XCTAssertEqual(spans.count, 2)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "依次执行 swift test --filter VoicePolishPipelineTests 和 swift test --filter VoicePolishCoreTests。",
                sourceSpanIds: spans.map(\.id), status: "keep", modality: "confirmed",
                exactTokens: ["--filter"], surfaceTokens: []
            )],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
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

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            invalid,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        )
        XCTAssertEqual(validated.conditionals.map(\.cueIds), cues.map { [$0.id] })
        XCTAssertEqual(validated.conditionals.map(\.operatorKind), cues.map(\.operatorKind))
        XCTAssertEqual(validated.conditionals.map { $0.condition.subject }, cues.map(\.text))
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

        let recovered = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(subject: "老板", predicate: "批准", action: "删除数据库"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        )
        XCTAssertEqual(recovered.conditionals[0].condition.subject, cues[0].text)
        XCTAssertFalse(recovered.conditionals[0].condition.subject.contains("老板"))
        let sourceBound = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan(subject: "客户", predicate: "确认", action: "发布"),
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        )
        XCTAssertEqual(sourceBound.conditionals[0].condition.subject, "客户")
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

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            wrong,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .document
        )
        XCTAssertEqual(validated.conditionals.map(\.operatorKind), ["only_if", "if_then"])
        XCTAssertEqual(validated.conditionals.map { $0.condition.subject }, cues.map(\.text))
    }

    func testAIPromptAddsWriterUnitForSourceBackedConditionalSpanOnly() throws {
        let request = makeRequest(
            "目标是比较工具。如果套餐有地区差异，就分别写清楚。",
            scene: .aiPrompt
        )
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let cues = VoicePolishLedgerIntegrityValidator.requiredLogicCues(
            source: request.input.fallbackText,
            spans: spans
        )
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(cues.count, 1)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: spans[0].text, sourceSpanIds: [spans[0].id], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [],
            conditionals: [VoicePolishLedgerConditional(
                id: "c1", cueIds: [cues[0].id], operatorKind: "if_then",
                condition: VoicePolishLedgerCondition(
                    subject: "套餐", predicate: "有地区差异", polarity: true,
                    sourceSpanIds: [spans[1].id]
                ),
                consequences: [VoicePolishLedgerConsequence(
                    action: "分别写清楚", polarity: true, sourceSpanIds: [spans[1].id]
                )]
            )],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: ["u1"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .aiPrompt
        )

        XCTAssertEqual(validated.units.count, 2)
        let conditionalUnit = try XCTUnwrap(validated.units.first {
            $0.sourceSpanIds == [spans[1].id]
        })
        XCTAssertEqual(conditionalUnit.deliveryRole, "recipient_content")
        XCTAssertEqual(conditionalUnit.finalMeaning, spans[1].text)
        XCTAssertEqual(validated.structure.orderedUnitIds, ["u1", conditionalUnit.id])
        XCTAssertEqual(validated.structure.numberedUnitIds, [])
    }

    func testAIPromptStillRejectsUncoveredNonConditionalSpan() throws {
        let request = makeRequest(
            "目标是比较工具。如果套餐有地区差异，就分别写清楚。另外说明收费方式。",
            scene: .aiPrompt
        )
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let cues = VoicePolishLedgerIntegrityValidator.requiredLogicCues(
            source: request.input.fallbackText,
            spans: spans
        )
        XCTAssertEqual(spans.count, 3)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: spans[0].text, sourceSpanIds: [spans[0].id], status: "keep",
                modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [],
            conditionals: [VoicePolishLedgerConditional(
                id: "c1", cueIds: [cues[0].id], operatorKind: "if_then",
                condition: VoicePolishLedgerCondition(
                    subject: "套餐", predicate: "有地区差异", polarity: true,
                    sourceSpanIds: [spans[1].id]
                ),
                consequences: [VoicePolishLedgerConsequence(
                    action: "分别写清楚", polarity: true, sourceSpanIds: [spans[1].id]
                )]
            )],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: ["u1"])
        )

        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: cues,
            scene: .aiPrompt
        )) { error in
            XCTAssertTrue(String(describing: error).contains("source_spans_without_unit"))
        }
    }

    func testUnitKindCanBeMechanicallyRecoveredButUnsafeRoleStillFails() throws {
        let request = makeRequest("先别开始研究，只整理任务。", scene: .aiPrompt)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let editor = VoicePolishLedgerUnit(
            id: "u1", kind: "editor_directive", deliveryRole: "editor_directive",
            finalMeaning: spans[0].text, sourceSpanIds: [spans[0].id], status: "remove",
            modality: "confirmed", exactTokens: [], surfaceTokens: ["先别开始研究"]
        )
        let validPlan = VoicePolishIntentLedger(
            audience: [], units: [editor], corrections: [], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: [])
        )
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            validPlan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .aiPrompt
        )) { error in
            // 纯 editor 计划仍因没有任何收件人正文而失败，但不再因 kind 枚举失败。
            XCTAssertFalse(String(describing: error).contains("unit_identity_enum"))
        }

        var unsafeUnit = editor
        unsafeUnit.deliveryRole = "internal_note"
        let unsafePlan = VoicePolishIntentLedger(
            audience: [], units: [unsafeUnit], corrections: [], conditionals: [],
            technicalTokenMappings: [], dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "ai_prompt", orderedUnitIds: [])
        )
        XCTAssertThrowsError(try VoicePolishLedgerIntegrityValidator.validatedLedger(
            unsafePlan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .aiPrompt
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unit_identity_enum"))
        }
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

    func testGroupDirectAddressCannotLoseRecipientCompletely() throws {
        let request = makeRequest("跟团队说会议改到周四下午")
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = VoicePolishIntentLedger(
            audience: [VoicePolishLedgerAudience(
                text: "团队", sourceSpanIds: spans.map(\.id), surfaceTokens: ["团队"],
                deliveryMode: "direct_address"
            )],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "会议改到周四下午", sourceSpanIds: spans.map(\.id),
                status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )
        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .workChat
        )

        XCTAssertTrue(VoicePolishLedgerIntegrityValidator.deterministicIssues(
            output: "会议改到周四下午。",
            request: request,
            ledger: validated,
            spans: spans
        ).contains(where: { $0.type == "wrong_relation" }))
        XCTAssertFalse(VoicePolishLedgerIntegrityValidator.deterministicIssues(
            output: "大家，会议改到周四下午。",
            request: request,
            ledger: validated,
            spans: spans
        ).contains(where: { $0.type == "wrong_relation" }))
    }

    func testCustomerDirectAddressRejectsBackstageRelayWording() throws {
        let request = makeRequest("给客户回一下这个功能需要先开权限")
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = VoicePolishIntentLedger(
            audience: [VoicePolishLedgerAudience(
                text: "客户", sourceSpanIds: spans.map(\.id), surfaceTokens: ["客户"],
                deliveryMode: "direct_address"
            )],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "这个功能需要先开权限", sourceSpanIds: spans.map(\.id),
                status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )
        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .customerSupport
        )

        XCTAssertTrue(VoicePolishLedgerIntegrityValidator.deterministicIssues(
            output: "给客户回一下这个功能需要先开权限。",
            request: request,
            ledger: validated,
            spans: spans
        ).contains(where: { $0.type == "task_layer" }))
        XCTAssertTrue(VoicePolishLedgerIntegrityValidator.deterministicIssues(
            output: "这个功能需要先开权限。",
            request: request,
            ledger: validated,
            spans: spans
        ).isEmpty)
    }

    func testRecipientWrongRoleStyleOpinionCannotRejectSendReadyCustomerDraft() async throws {
        let request = makeRequest("给客户回一下这个功能需要先开权限", scene: .customerSupport)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = VoicePolishIntentLedger(
            audience: [VoicePolishLedgerAudience(
                text: "客户", sourceSpanIds: spans.map(\.id), surfaceTokens: ["客户"],
                deliveryMode: "direct_address"
            )],
            units: [VoicePolishLedgerUnit(
                id: "u1", kind: "action", deliveryRole: "recipient_content",
                finalMeaning: "这个功能需要先开权限", sourceSpanIds: spans.map(\.id),
                status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
            )],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )
        let styleOpinion = VoicePolishReviewerResult(
            verdict: "repair",
            issues: [VoicePolishReviewerIssue(
                type: "wrong_role", severity: "major", unitIds: ["u1"],
                sourceSpanIds: spans.map(\.id), draftSpan: "请先开启权限",
                repairInstruction: "把‘请’改成更直接的口吻。"
            )]
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(plan),
            try encoded(draft("请先开启权限。")),
            try encoded(styleOpinion),
        ])

        let result = await VoicePolishLedgerPipeline(client: client, config: config).process(request)

        XCTAssertEqual(result.text, "请先开启权限。")
        XCTAssertEqual(result.attempts, 3)
        XCTAssertNil(result.failureStage)
    }

    func testStructureDropsNonRecipientDirectiveIDsButStillOrdersEveryRecipientUnit() throws {
        let request = makeRequest("整理会议通知，语气自然。")
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [
                VoicePolishLedgerUnit(
                    id: "u1", kind: "action", deliveryRole: "recipient_content",
                    finalMeaning: "整理会议通知", sourceSpanIds: spans.map(\.id),
                    status: "keep", modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "u2", kind: "style", deliveryRole: "style_directive",
                    finalMeaning: "语气自然", sourceSpanIds: spans.map(\.id),
                    status: "keep", modality: "confirmed", exactTokens: [],
                    surfaceTokens: ["语气自然"]
                ),
            ],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1", "u2"])
        )

        let validated = try VoicePolishLedgerIntegrityValidator.validatedLedger(
            plan,
            spans: spans,
            verifiedMappings: [],
            requiredLogicCues: [],
            scene: .document
        )

        XCTAssertEqual(validated.structure.orderedUnitIds, ["u1"])
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

        let result = await productionLedgerPipeline(client).process(request)

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

        let result = await productionLedgerPipeline(client).process(request)

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

    func testReviewerWrongRoleCannotLetRecipientContentDisappearAsEditorDirective() async throws {
        let source = "第一项确认课程定位。第二项请团队周五前提交截图。"
        let request = makeRequest(source, scene: .workChat)
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        XCTAssertEqual(spans.count, 2)
        let plan = VoicePolishIntentLedger(
            audience: [],
            units: [
                VoicePolishLedgerUnit(
                    id: "u1", kind: "claim", deliveryRole: "recipient_content",
                    finalMeaning: spans[0].text, sourceSpanIds: [spans[0].id], status: "keep",
                    modality: "confirmed", exactTokens: [], surfaceTokens: []
                ),
                VoicePolishLedgerUnit(
                    id: "u2", kind: "action", deliveryRole: "editor_directive",
                    finalMeaning: spans[1].text, sourceSpanIds: [spans[1].id], status: "remove",
                    modality: "confirmed", exactTokens: [], surfaceTokens: ["提交截图"]
                ),
            ],
            corrections: [], conditionals: [], technicalTokenMappings: [],
            dictatedSymbolMappings: [], contextMappings: [],
            structure: VoicePolishLedgerStructure(kind: "sentence", orderedUnitIds: ["u1"])
        )
        let wrongRoleReview = VoicePolishReviewerResult(
            verdict: "repair",
            issues: [VoicePolishReviewerIssue(
                type: "wrong_role",
                severity: "major",
                unitIds: ["u2"],
                sourceSpanIds: [spans[1].id],
                draftSpan: nil,
                repairInstruction: "这是面向团队的真实行动要求，不能作为幕后指令删除。"
            )]
        )
        let client = LedgerScriptedLLM(responses: [
            try encoded(plan),
            try encoded(draft("第一项确认课程定位。")),
            try encoded(wrongRoleReview),
            try encoded(draft(source)),
            try encoded(passReview()),
        ])

        let result = await VoicePolishLedgerPipeline(
            client: client,
            config: config
        ).process(request)

        XCTAssertNil(result.text)
        XCTAssertEqual(result.failureStage, .reviewing)
        XCTAssertEqual(result.attempts, 3)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 3)
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

        let result = await productionLedgerPipeline(client).process(request)

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

        let result = await productionLedgerPipeline(client).process(request)

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

private enum LedgerTransientFailure: Sendable {
    case requestFailed503
    case requestFailed401
    case requestRejected503
    case requestRejected401
    case networkConnectionLost
}

private actor LedgerTransientPlannerLLM: LLMClient {
    private var responses: [String]
    private let initialFailure: LedgerTransientFailure
    private var recorded: [LLMRequest] = []
    private var configuredModels: [String] = []
    private var failedOnce = false

    init(
        responses: [String],
        initialFailure: LedgerTransientFailure = .requestFailed503
    ) {
        self.responses = responses
        self.initialFailure = initialFailure
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        recorded.append(request)
        configuredModels.append(config.model)
        if !failedOnce {
            failedOnce = true
            switch initialFailure {
            case .requestFailed503:
                throw LLMError.requestFailed(503)
            case .requestFailed401:
                throw LLMError.requestFailed(401)
            case .requestRejected503:
                throw LLMError.requestRejected(503, "service unavailable")
            case .requestRejected401:
                throw LLMError.requestRejected(401, "unauthorized")
            case .networkConnectionLost:
                throw URLError(.networkConnectionLost)
            }
        }
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

    func requestCount() -> Int { recorded.count }
    func models() -> [String] { configuredModels }
    func requests() -> [LLMRequest] { recorded }
}

private enum LedgerScriptedLLMError: Error {
    case noResponse
}
