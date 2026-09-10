import Foundation

private struct VoicePolishLedgerTimeoutError: Error {}
private struct VoicePolishLedgerPlanValidationError: Error, CustomStringConvertible {
    let detail: String

    var description: String { detail }

    var stableDiagnostic: String {
        let candidate = detail.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard !candidate.isEmpty,
              candidate.unicodeScalars.allSatisfy(allowed.contains) else {
            return "ledger_validation_failed"
        }
        return candidate
    }
}

/// 面向日常复杂短文与约 1K 长文的新流水线。它不调用旧语义 Validator，
/// 只使用带来源证据的 Ledger、隔离 Reviewer 和可确定证明的本地安全门。
struct VoicePolishLedgerPipeline: Sendable {
    private static let defaultTotalTimeout: Duration = .seconds(120)
    private static let maximumAttempts = 6
    private static let shortRiskPattern = try! NSRegularExpression(
        pattern: #"不对|说错|发错|更正|改成|应该是|不是不|最终|没确认|未确认|待确认|待定|(?:不要|别|不得|不能|建议|最好|只需|仅需)|(?:跟|给)[^。！？\n]{0,12}说|回复|第一[^。！？\n]{0,80}第二|一共|共\s*[零〇一二两三四五六七八九十百千万\d]+\s*(?:项|条|个|件|步|样)|如果|若是|要是|只要|除非|否则|只有[^。！？；\n]{0,40}才|不能[^。！？；\n]{0,40}就"#
    )
    private let client: any LLMClient
    private let generationConfig: LLMConfig
    private let reviewerConfig: LLMConfig
    private let totalTimeout: Duration
    private let onStage: (@Sendable (VoicePolishStage) -> Void)?

    init(
        client: any LLMClient,
        config: LLMConfig,
        totalTimeout: Duration = VoicePolishLedgerPipeline.defaultTotalTimeout,
        onStage: (@Sendable (VoicePolishStage) -> Void)? = nil
    ) {
        self.client = client
        self.generationConfig = Self.qualityConfig(for: config)
        self.reviewerConfig = Self.reviewConfig(for: config)
        self.totalTimeout = totalTimeout
        self.onStage = onStage
    }

    /// 模型影响一次成稿率和延迟，但不能由语音润色链路擅自替用户切换。
    /// 真实生产跑测已经证明：把用户选择的 Flash 静默升级为 Pro，会让约 1K
    /// 文本的 Planner 连续触发 60 秒超时。Ledger 因此始终尊重当前配置；
    /// 模型能力差异由 Reviewer、确定性门禁和显式失败吸收。
    static func qualityConfig(for config: LLMConfig) -> LLMConfig {
        config
    }

    /// 冷 Reviewer 是隔离调用与独立 Prompt，不要求偷偷更换用户模型。
    /// 若未来支持独立 Reviewer 模型，应成为明确、可审计的产品配置，而不是
    /// 由某个 Provider 名称触发的隐藏策略。
    static func reviewConfig(for config: LLMConfig) -> LLMConfig {
        config
    }

    static func shouldUse(
        for request: VoicePolishRequest,
        minimumCharacterCount: Int = 80
    ) -> Bool {
        let text = request.input.fallbackText
        // 字数不能证明语义简单：一句话也可能包含连续改口或必要条件。
        // 简单短句仍一次成稿；出现既有风险信号时统一交给 Ledger 和冷复核，
        // 避免旧 Fast 校验先误拦正确稿，再把已作废的事实修复回来。
        // 更长文本仍留给既有有界分片链路，作为压力边界单独演进。
        guard !text.isEmpty, text.count <= 1_800 else {
            return false
        }
        if text.count >= 280 { return true }
        if text.count >= max(0, minimumCharacterCount),
           !request.resolvedEntities.isEmpty || !request.input.requiredEntityEdits.isEmpty {
            return true
        }
        if text.count >= 20, request.context.scene == .code || request.context.scene == .aiPrompt {
            return true
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return shortRiskPattern.firstMatch(in: text, range: range) != nil
    }

    func process(
        _ request: VoicePolishRequest,
        startedAt: ContinuousClock.Instant = .now
    ) async -> VoicePolishLedgerRunResult {
        let spans = VoicePolishLedgerIntegrityValidator.evidenceSpans(for: request)
        let mappings = VoicePolishLedgerIntegrityValidator.verifiedMappings(
            request: request,
            spans: spans
        )
        let requiredLogicCues = VoicePolishLedgerIntegrityValidator.requiredLogicCues(
            source: request.input.fallbackText,
            spans: spans
        )
        var attempts = 0
        let deadline = startedAt.advanced(by: totalTimeout)

        var rawPlanResponse = ""
        var plannedLedger: VoicePolishIntentLedger?
        var retriedInitialRequest = false
        planning: while plannedLedger == nil {
            do {
                try reserveAttempt(&attempts)
                rawPlanResponse = try await generate(
                    task: .voicePolishAnalyze,
                    stage: .analyzing,
                    system: VoicePolishLedgerPrompts.planner,
                    user: try plannerPayload(
                        request: request,
                        spans: spans,
                        mappings: mappings,
                        requiredLogicCues: requiredLogicCues
                    ),
                    responseFormat: .jsonObject,
                    // 约 1K、多约束文本的 Ledger 通常显著长于最终成稿。
                    // 规划阶段直接给满受控上限，避免 4096 token 在完整覆盖
                    // source spans 前被截断；总时限与总尝试数仍保持不变。
                    maxOutputTokens: outputBudget(
                        source: request.input.fallbackText,
                        baseline: 8_192
                    ),
                    timeout: .seconds(60),
                    deadline: deadline,
                    config: generationConfig
                )
                plannedLedger = try decodedAndValidatedLedger(
                    rawPlanResponse,
                    request: request,
                    spans: spans,
                    mappings: mappings,
                    requiredLogicCues: requiredLogicCues
                )
            } catch let validationError as VoicePolishLedgerPlanValidationError {
                // 规划阶段总共只有一个恢复槽：首次若已因瞬时网络错误重试，
                // 第二次再产出无效 Ledger 就显式失败，不能继续叠加 schema
                // repair，确保最坏仍不超过 6 次总调用。
                if retriedInitialRequest {
                    return .unavailable(
                        stage: .planning,
                        attempts: attempts,
                        codes: [.planIntegrityFailure],
                        reason: .validationFailed,
                        plannerValidationTrace: VoicePolishPlannerValidationTrace(
                            initialCode: validationError.stableDiagnostic,
                            repairedCode: nil
                        )
                    )
                }
                do {
                    try reserveAttempt(&attempts)
                    let repairedPlan = try await generate(
                        task: .voicePolishAnalyze,
                        stage: .analyzing,
                        system: VoicePolishLedgerPrompts.plannerRepair,
                        user: try plannerRepairPayload(
                            request: request,
                            spans: spans,
                            mappings: mappings,
                            requiredLogicCues: requiredLogicCues,
                            invalidResponse: rawPlanResponse,
                            error: validationError
                        ),
                        responseFormat: .jsonObject,
                        maxOutputTokens: outputBudget(
                            source: request.input.fallbackText,
                            baseline: 8_192
                        ),
                        timeout: .seconds(60),
                        deadline: deadline,
                        config: generationConfig
                    )
                    plannedLedger = try decodedAndValidatedLedger(
                        repairedPlan,
                        request: request,
                        spans: spans,
                        mappings: mappings,
                        requiredLogicCues: requiredLogicCues
                    )
                } catch let finalError {
                    let reason: VoicePolishFailureReason
                    let repairedCode: String?
                    if finalError is VoicePolishLedgerTimeoutError {
                        reason = .timeout
                        repairedCode = nil
                    } else if finalError is VoicePolishLedgerPlanValidationError {
                        reason = .validationFailed
                        repairedCode = (finalError as? VoicePolishLedgerPlanValidationError)?
                            .stableDiagnostic
                    } else {
                        reason = .requestFailed
                        repairedCode = nil
                    }
                    return .unavailable(
                        stage: .planning,
                        attempts: attempts,
                        codes: [.planIntegrityFailure],
                        reason: reason,
                        plannerValidationTrace: VoicePolishPlannerValidationTrace(
                            initialCode: validationError.stableDiagnostic,
                            repairedCode: repairedCode
                        )
                    )
                }
            } catch let error {
                if !retriedInitialRequest, shouldRetryInitialPlannerRequest(error) {
                    retriedInitialRequest = true
                    continue planning
                }
                return unavailable(
                    stage: .planning,
                    attempts: attempts,
                    code: .invalidStructuredResponse,
                    error: error
                )
            }
        }
        guard let ledger = plannedLedger else {
            return .unavailable(
                stage: .planning,
                attempts: attempts,
                codes: [.planIntegrityFailure],
                reason: .validationFailed
            )
        }

        let initialDocument: VoicePolishLedgerDraftDocument
        let initialDraft: String
        do {
            try reserveAttempt(&attempts)
            let response = try await generate(
                task: .voicePolishRender,
                stage: .rendering,
                system: VoicePolishLedgerPrompts.writer,
                user: try writerPayload(
                    request: request,
                    spans: spans,
                    ledger: ledger,
                    mappings: mappings
                ),
                responseFormat: .jsonObject,
                maxOutputTokens: outputBudget(source: request.input.fallbackText, baseline: 3_072),
                timeout: .seconds(90),
                deadline: deadline,
                config: generationConfig
            )
            let decoded = try decode(VoicePolishLedgerDraftDocument.self, from: response)
            initialDocument = try normalizedDraftDocument(
                decoded,
                request: request,
                ledger: ledger
            )
            initialDraft = renderedText(from: initialDocument, ledger: ledger)
            guard !initialDraft.isEmpty else { throw VoicePolishLedgerIntegrityError.invalidLedger }
        } catch {
            return unavailable(
                stage: .writing,
                attempts: attempts,
                code: .emptyOutput,
                error: error
            )
        }

        let initialReview: VoicePolishReviewerResult
        do {
            try reserveAttempt(&attempts)
            initialReview = try await review(
                request: request,
                spans: spans,
                ledger: ledger,
                mappings: mappings,
                draft: initialDocument,
                timeout: .seconds(60),
                deadline: deadline
            )
        } catch {
            return unavailable(
                stage: .reviewing,
                attempts: attempts,
                code: .invalidStructuredResponse,
                error: error,
                rejectedDraft: initialDraft
            )
        }

        let initialIssues = blockingIssues(
            review: initialReview,
            deterministic: VoicePolishLedgerIntegrityValidator.deterministicIssues(
                output: initialDraft,
                request: request,
                ledger: ledger,
                spans: spans
            ) + VoicePolishLedgerIntegrityValidator.fragmentBindingIssues(
                document: initialDocument, ledger: ledger
            ),
            ledger: ledger,
            validSpanIDs: Set(spans.map(\.id))
        )
        if initialReview.verdict != "unsafe", initialIssues.isEmpty {
            return .polished(initialDraft, attempts: attempts)
        }
        guard initialReview.verdict != "unsafe" else {
            return .unavailable(
                stage: .reviewing,
                attempts: attempts,
                codes: [.semanticDecisionUnverified],
                reason: .validationFailed,
                rejectedDraft: initialDraft
            )
        }
        // wrong_role 说明 Planner 把真实正文误标成 editor/remove/excluded。
        // Draft Repair 只能改成稿 fragment，不能纠正 Ledger 的角色与结构；
        // 继续修稿会让同一错误 Ledger 在确认阶段被误放行，因此必须显式
        // 停止并让用户重试一次完整规划。
        if initialIssues.contains(where: {
            issueRequiresLedgerReplan($0, ledger: ledger)
        }) {
            return .unavailable(
                stage: .reviewing,
                attempts: attempts,
                codes: [.semanticDecisionUnverified],
                reason: .validationFailed,
                rejectedDraft: initialDraft
            )
        }

        let repairedDocument: VoicePolishLedgerDraftDocument
        let repairedDraft: String
        do {
            let affectedFragmentIDs = affectedFragments(
                in: initialDocument,
                issues: initialIssues
            )
            guard !affectedFragmentIDs.isEmpty else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
            try reserveAttempt(&attempts)
            let response = try await generate(
                task: .voicePolishRepair,
                stage: .repairing,
                system: VoicePolishLedgerPrompts.repair,
                user: try repairPayload(
                    request: request,
                    spans: spans,
                    ledger: ledger,
                    mappings: mappings,
                    draft: initialDocument,
                    issues: initialIssues,
                    affectedFragmentIDs: affectedFragmentIDs
                ),
                responseFormat: .jsonObject,
                maxOutputTokens: outputBudget(source: request.input.fallbackText, baseline: 3_072),
                timeout: .seconds(90),
                deadline: deadline,
                config: generationConfig
            )
            let patch = try decode(VoicePolishLedgerDraftDocument.self, from: response)
            repairedDocument = try applyingPatch(
                patch,
                to: initialDocument,
                affectedFragmentIDs: affectedFragmentIDs,
                request: request,
                ledger: ledger
            )
            repairedDraft = renderedText(from: repairedDocument, ledger: ledger)
            guard !repairedDraft.isEmpty else { throw VoicePolishLedgerIntegrityError.invalidLedger }
        } catch {
            return unavailable(
                stage: .repairing,
                attempts: attempts,
                code: .emptyOutput,
                error: error,
                rejectedDraft: initialDraft
            )
        }

        let confirmation: VoicePolishReviewerResult
        do {
            try reserveAttempt(&attempts)
            confirmation = try await review(
                request: request,
                spans: spans,
                ledger: ledger,
                mappings: mappings,
                draft: repairedDocument,
                timeout: .seconds(60),
                deadline: deadline
            )
        } catch {
            return unavailable(
                stage: .confirming,
                attempts: attempts,
                code: .invalidStructuredResponse,
                error: error,
                rejectedDraft: repairedDraft
            )
        }
        let confirmationIssues = blockingIssues(
            review: confirmation,
            deterministic: VoicePolishLedgerIntegrityValidator.deterministicIssues(
                output: repairedDraft,
                request: request,
                ledger: ledger,
                spans: spans
            ) + VoicePolishLedgerIntegrityValidator.fragmentBindingIssues(
                document: repairedDocument, ledger: ledger
            ),
            ledger: ledger,
            validSpanIDs: Set(spans.map(\.id))
        )
        guard confirmation.verdict != "unsafe", confirmationIssues.isEmpty else {
            return .unavailable(
                stage: .confirming,
                attempts: attempts,
                codes: [.semanticDecisionUnverified],
                reason: .validationFailed,
                rejectedDraft: repairedDraft
            )
        }
        return .polished(repairedDraft, attempts: attempts)
    }

    private func review(
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan],
        ledger: VoicePolishIntentLedger,
        mappings: [VoicePolishLedgerContextMapping],
        draft: VoicePolishLedgerDraftDocument,
        timeout: Duration,
        deadline: ContinuousClock.Instant
    ) async throws -> VoicePolishReviewerResult {
        let response = try await generate(
            task: .voicePolishAnalyze,
            stage: .analyzing,
            system: VoicePolishLedgerPrompts.reviewer,
            user: try reviewerPayload(
                request: request,
                spans: spans,
                ledger: ledger,
                mappings: mappings,
                draft: draft
            ),
            responseFormat: .jsonObject,
            maxOutputTokens: outputBudget(
                source: try encodedJSONString(ledger.pendingSemanticChecks ?? []), baseline: 3_072),
            timeout: timeout,
            deadline: deadline,
            config: reviewerConfig
        )
        let decodedReview = try decode(VoicePolishReviewerResult.self, from: response)
        let allowedVerdicts = Set(["pass", "repair", "unsafe"])
        let allowedTypes = Set([
            "missing", "wrong_relation", "wrong_condition", "wrong_modality",
            "obsolete_retained", "invented", "context_leak", "task_layer",
            "instruction_leak", "style_shift", "wrong_role",
        ])
        let validSpanIDs = Set(spans.map(\.id))
        let unitByID = Dictionary(uniqueKeysWithValues: ledger.units.map { ($0.id, $0) })
        let validUnitIDs = Set(unitByID.keys)
        let rendered = renderedText(from: draft, ledger: ledger)
        // 轻微排版建议有时用省略号概括整段。只去掉这类建议的不实引文，
        // 保留问题及其单元/来源定位，仍须修复并重新确认；事实类引文继续严格校验。
        let review = VoicePolishReviewerResult(
            verdict: decodedReview.verdict,
            issues: decodedReview.issues.map { issue in
                guard issue.type == "style_shift", issue.severity == "minor",
                      let quote = issue.draftSpan, !quote.isEmpty, !rendered.contains(quote)
                else { return issue }
                return VoicePolishReviewerIssue(
                    type: issue.type, severity: issue.severity, unitIds: issue.unitIds,
                    sourceSpanIds: issue.sourceSpanIds, draftSpan: nil,
                    repairInstruction: issue.repairInstruction
                )
            },
            semanticChecks: decodedReview.semanticChecks
        )
        let issuesAreValid = review.issues.allSatisfy { issue -> Bool in
            guard allowedTypes.contains(issue.type),
                  ["minor", "major"].contains(issue.severity),
                  !issue.unitIds.isEmpty, !issue.sourceSpanIds.isEmpty,
                  issue.sourceSpanIds.allSatisfy(validSpanIDs.contains),
                  issue.unitIds.allSatisfy(validUnitIDs.contains),
                  !issue.repairInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            let sharesSource = issue.unitIds.contains { unitID in
                guard let unit = unitByID[unitID] else { return false }
                return !Set(unit.sourceSpanIds).isDisjoint(with: issue.sourceSpanIds)
            }
            let draftSpan = issue.draftSpan ?? ""
            return sharesSource && (draftSpan.isEmpty || rendered.contains(draftSpan))
        }
        guard allowedVerdicts.contains(review.verdict),
              review.verdict != "pass" || review.issues.isEmpty,
              review.verdict != "repair" || !review.issues.isEmpty,
              issuesAreValid else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        try VoicePolishLedgerIntegrityValidator.validateSemanticReview(
            review, ledger: ledger, spans: spans, allowRepairFindings: true
        )
        return review
    }

    private func generate(
        task: LLMTask,
        stage: VoicePolishStage,
        system: String,
        user: String,
        responseFormat: LLMResponseFormat,
        maxOutputTokens: Int,
        timeout: Duration,
        deadline: ContinuousClock.Instant,
        config: LLMConfig
    ) async throws -> String {
        try Task.checkCancellation()
        onStage?(stage)
        let remaining = deadline - ContinuousClock.now
        guard remaining >= .seconds(2) else {
            throw VoicePolishLedgerTimeoutError()
        }
        return try await AsyncTimeout.throwingValue(
            min(timeout, remaining),
            timeoutError: VoicePolishLedgerTimeoutError()
        ) {
            try await client.generate(
                LLMRequest(
                    context: .structuredTask,
                    task: task,
                    system: system,
                    user: user,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: maxOutputTokens,
                        // Planner、Writer 与 Reviewer 都只需按来源证据输出可验证
                        // JSON。启用 thinking 会让 DeepSeek Flash/Pro 在真实链路中
                        // 连续耗尽 60 秒阶段预算；架构实验也一直显式关闭 thinking。
                        reasoningPolicy: .disabled,
                        responseFormat: responseFormat
                    )
                ),
                config: config
            ).text
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: String) throws -> T {
        try StructuredLLMDecoder.decode(type, from: response)
    }

    private func decodedAndValidatedLedger(
        _ response: String,
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan],
        mappings: [VoicePolishLedgerContextMapping],
        requiredLogicCues: [VoicePolishLogicCue]
    ) throws -> VoicePolishIntentLedger {
        do {
            let decoded = try decode(VoicePolishIntentLedger.self, from: response)
            return try VoicePolishLedgerIntegrityValidator.validatedLedger(
                decoded,
                spans: spans,
                verifiedMappings: mappings,
                requiredLogicCues: requiredLogicCues,
                scene: request.context.scene
            )
        } catch let error as VoicePolishLedgerIntegrityError {
            throw VoicePolishLedgerPlanValidationError(detail: error.description)
        } catch is StructuredLLMDecoderError {
            throw VoicePolishLedgerPlanValidationError(detail: "ledger_json_decode_failed")
        } catch {
            throw VoicePolishLedgerPlanValidationError(detail: "ledger_validation_failed")
        }
    }

    private func plannerPayload(
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan],
        mappings: [VoicePolishLedgerContextMapping],
        requiredLogicCues: [VoicePolishLogicCue]
    ) throws -> String {
        try jsonString([
            "writing_scene": request.context.scene.rawValue,
            "source_spans": try jsonObject(spans),
            "required_logic_cues": try jsonObject(requiredLogicCues),
            "verified_entity_mappings": try jsonObject(mappings),
            "additional_requirements": request.preferences.additionalRequirements,
        ])
    }

    private func plannerRepairPayload(
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan],
        mappings: [VoicePolishLedgerContextMapping],
        requiredLogicCues: [VoicePolishLogicCue],
        invalidResponse: String,
        error: Error
    ) throws -> String {
        // 修复请求本身不能再是一个与目标 Ledger 外形相近的大 JSON。真实模型
        // 曾把整个请求对象原样回显，导致第二次稳定解码失败。用明确的只读分区
        // 隔离证据、错误和旧响应，系统 Prompt 仍要求最终只返回 Ledger JSON。
        let sourceSpans = try encodedJSONString(spans)
        let logicCues = try encodedJSONString(requiredLogicCues)
        let verifiedMappings = try encodedJSONString(mappings)
        return """
        REPAIR_TARGET: VOICE_POLISH_INTENT_LEDGER
        WRITING_SCENE:
        \(request.context.scene.rawValue)

        VALIDATION_ERROR:
        \(String(describing: error))

        ADDITIONAL_REQUIREMENTS:
        \(request.preferences.additionalRequirements)

        REQUIRED_LOGIC_CUES_JSON:
        \(logicCues)

        VERIFIED_ENTITY_MAPPINGS_JSON:
        \(verifiedMappings)

        SOURCE_SPANS_JSON:
        \(sourceSpans)

        INVALID_LEDGER_JSON:
        \(String(invalidResponse.prefix(24_000)))

        OUTPUT_REQUIREMENT:
        只返回修复后的 VoicePolishIntentLedger JSON 对象。不得回显上述分区、字段标签或输入载荷。
        """
    }

    private func writerPayload(
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan],
        ledger: VoicePolishIntentLedger,
        mappings: [VoicePolishLedgerContextMapping]
    ) throws -> String {
        try jsonString([
            "writing_scene": request.context.scene.rawValue,
            "source_spans": try jsonObject(spans),
            "intent_ledger": try jsonObject(ledger),
            "verified_entity_mappings": try jsonObject(mappings),
            "additional_requirements": request.preferences.additionalRequirements,
        ])
    }

    private func reviewerPayload(
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan],
        ledger: VoicePolishIntentLedger,
        mappings: [VoicePolishLedgerContextMapping],
        draft: VoicePolishLedgerDraftDocument
    ) throws -> String {
        try jsonString([
            "writing_scene": request.context.scene.rawValue,
            "source_spans": try jsonObject(spans),
            "source_unit_index": ledger.units.map {
                ["unit_id": $0.id, "source_span_ids": $0.sourceSpanIds] as [String: Any]
            },
            "pending_semantic_checks": try jsonObject(ledger.pendingSemanticChecks ?? []),
            "verified_entity_mappings": try jsonObject(mappings),
            "draft_document": try jsonObject(draft),
            "rendered_text": renderedText(from: draft, ledger: ledger),
        ])
    }

    private func repairPayload(
        request: VoicePolishRequest,
        spans: [VoicePolishEvidenceSpan],
        ledger: VoicePolishIntentLedger,
        mappings: [VoicePolishLedgerContextMapping],
        draft: VoicePolishLedgerDraftDocument,
        issues: [VoicePolishReviewerIssue],
        affectedFragmentIDs: Set<String>
    ) throws -> String {
        try jsonString([
            "writing_scene": request.context.scene.rawValue,
            "source_spans": try jsonObject(spans),
            "intent_ledger": try jsonObject(ledger),
            "verified_entity_mappings": try jsonObject(mappings),
            "current_draft_document": try jsonObject(draft),
            "rendered_text": renderedText(from: draft, ledger: ledger),
            "review_issues": try jsonObject(issues),
            "allowed_fragment_ids": affectedFragmentIDs.sorted(),
        ])
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        return string
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        return string
    }

    private func normalizedDraftDocument(
        _ document: VoicePolishLedgerDraftDocument,
        request: VoicePolishRequest,
        ledger: VoicePolishIntentLedger
    ) throws -> VoicePolishLedgerDraftDocument {
        let activeUnits: [String: VoicePolishLedgerUnit] = Dictionary(
            uniqueKeysWithValues: ledger.units.compactMap { unit -> (String, VoicePolishLedgerUnit)? in
            guard unit.deliveryRole == "recipient_content", unit.status != "remove" else {
                return nil
            }
            return (unit.id, unit)
        })
        let expectedIDs = ledger.structure.orderedUnitIds
        let knownRemovedUnitIDs = Set(ledger.units.filter {
            $0.deliveryRole != "recipient_content" || $0.status == "remove"
        }.map(\.id))
        let recipientFragments = document.fragments.filter { fragment in
            guard fragment.unitIds.count == 1, let id = fragment.unitIds.first,
                  fragment.id == "f_\(id)" else { return true }
            return !knownRemovedUnitIDs.contains(id)
        }
        // Writer 偶尔也返回 Ledger 明确排除的片段，程序只丢弃这些已知 ID。
        // 未知 ID、重复正文和缺失正文仍失败；Reviewer 继续核对 Planner 的角色。
        guard recipientFragments.count == expectedIDs.count else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        var fragmentByUnitID: [String: VoicePolishLedgerDraftFragment] = [:]
        var fragmentIDs: Set<String> = []
        let numberedUnitIDs = Set(ledger.structure.numberedUnitIds ?? [])
        for fragment in recipientFragments {
            guard fragment.unitIds.count == 1,
                  let unitID = fragment.unitIds.first,
                  let unit = activeUnits[unitID],
                  fragment.id == "f_\(unitID)",
                  fragmentIDs.insert(fragment.id).inserted,
                  fragmentByUnitID[unitID] == nil,
                  var text = VoicePolishOutputNormalizer.plainText(
                    fragment.text,
                    sourceText: request.input.fallbackText
                  ) else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
            if ledger.structure.kind == "numbered_list"
                || numberedUnitIDs.contains(unitID) {
                text = text.replacingOccurrences(
                    of: #"^\s*(?:\d{1,3}[\.、）)]|[-*•])\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            let unitSpans = Set(unit.sourceSpanIds)
            let tokenMappings = ledger.technicalTokenMappings + ledger.dictatedSymbolMappings
            for mapping in tokenMappings
            where !unitSpans.isDisjoint(with: mapping.sourceSpanIds) {
                text = text.replacingOccurrences(of: mapping.alias, with: mapping.canonical)
            }
            for mapping in ledger.contextMappings
            where !unitSpans.isDisjoint(with: mapping.sourceSpanIds) {
                text = text.replacingOccurrences(of: mapping.alias, with: mapping.canonical)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw VoicePolishLedgerIntegrityError.invalidLedger }
            fragmentByUnitID[unitID] = VoicePolishLedgerDraftFragment(
                id: fragment.id,
                unitIds: [unitID],
                text: text,
                paragraphBreakBefore: fragment.paragraphBreakBefore
            )
        }
        guard Set(fragmentByUnitID.keys) == Set(expectedIDs) else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        return VoicePolishLedgerDraftDocument(
            fragments: expectedIDs.compactMap { fragmentByUnitID[$0] }
        )
    }

    private func renderedText(
        from document: VoicePolishLedgerDraftDocument,
        ledger: VoicePolishIntentLedger
    ) -> String {
        let texts = document.fragments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !texts.contains(where: \.isEmpty) else { return "" }
        switch ledger.structure.kind {
        case "numbered_list":
            return texts.enumerated().map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        case "sentence":
            var result = texts.dropFirst().reduce(texts[0]) { partial, next in
                let needsSpace = partial.unicodeScalars.last.map(Self.isASCIIWordScalar) == true
                    && next.unicodeScalars.first.map(Self.isASCIIWordScalar) == true
                return partial + (needsSpace ? " " : "") + next
            }
            if result.range(of: #"[。！？!?…]$"#, options: .regularExpression) == nil {
                let question = ledger.units.contains {
                    $0.deliveryRole == "recipient_content" && $0.kind == "question"
                }
                result += question ? "？" : "。"
            }
            return result
        case "mixed":
            let numberedUnitIDs = Set(ledger.structure.numberedUnitIds ?? [])
            var nextNumber = 1
            var blocks: [String] = []
            var numberedBlock: [String] = []
            for (fragment, text) in zip(document.fragments, texts) {
                let unitID = fragment.unitIds.first ?? ""
                if numberedUnitIDs.contains(unitID) {
                    numberedBlock.append("\(nextNumber). \(text)")
                    nextNumber += 1
                } else {
                    if !numberedBlock.isEmpty {
                        blocks.append(numberedBlock.joined(separator: "\n"))
                        numberedBlock.removeAll(keepingCapacity: true)
                    }
                    blocks.append(text)
                }
            }
            if !numberedBlock.isEmpty {
                blocks.append(numberedBlock.joined(separator: "\n"))
            }
            return blocks.joined(separator: "\n\n")
        case "paragraphs", "ai_prompt":
            var result = texts[0]
            for (fragment, text) in zip(document.fragments.dropFirst(), texts.dropFirst()) {
                if fragment.paragraphBreakBefore ?? true {
                    result += "\n\n"
                } else if result.unicodeScalars.last.map(Self.isASCIIWordScalar) == true
                            && text.unicodeScalars.first.map(Self.isASCIIWordScalar) == true {
                    result += " "
                }
                result += text
            }
            return result
        default:
            return ""
        }
    }

    private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return scalar == "_"
        }
    }

    private func affectedFragments(
        in document: VoicePolishLedgerDraftDocument,
        issues: [VoicePolishReviewerIssue]
    ) -> Set<String> {
        var result: Set<String> = []
        for issue in issues {
            let issueUnitIDs = Set(issue.unitIds)
            for fragment in document.fragments
            where !issueUnitIDs.isDisjoint(with: fragment.unitIds) {
                result.insert(fragment.id)
            }
            if let draftSpan = issue.draftSpan,
               !draftSpan.isEmpty {
                for fragment in document.fragments where fragment.text.contains(draftSpan) {
                    result.insert(fragment.id)
                }
            }
        }
        return result.isEmpty ? Set(document.fragments.map(\.id)) : result
    }

    private func applyingPatch(
        _ patch: VoicePolishLedgerDraftDocument,
        to original: VoicePolishLedgerDraftDocument,
        affectedFragmentIDs: Set<String>,
        request: VoicePolishRequest,
        ledger: VoicePolishIntentLedger
    ) throws -> VoicePolishLedgerDraftDocument {
        guard Set(patch.fragments.map(\.id)) == affectedFragmentIDs,
              patch.fragments.count == affectedFragmentIDs.count else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        let originalByID = Dictionary(uniqueKeysWithValues: original.fragments.map { ($0.id, $0) })
        for fragment in patch.fragments {
            guard let prior = originalByID[fragment.id], fragment.unitIds == prior.unitIds else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
        }
        let patchDocument = try normalizedDraftDocument(
            VoicePolishLedgerDraftDocument(fragments: original.fragments.map { prior in
                patch.fragments.first(where: { $0.id == prior.id }) ?? prior
            }),
            request: request,
            ledger: ledger
        )
        for fragment in patchDocument.fragments where !affectedFragmentIDs.contains(fragment.id) {
            guard fragment == originalByID[fragment.id] else {
                throw VoicePolishLedgerIntegrityError.invalidLedger
            }
        }
        return patchDocument
    }

    private func reserveAttempt(_ attempts: inout Int) throws {
        guard attempts < Self.maximumAttempts else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        attempts += 1
    }

    /// 只对首次 Planner 的瞬时 Provider 失败做一次同模型重试；鉴权、地址、
    /// 响应过大和本地总超时都不会重试。总调用上限仍由 maximumAttempts 统一
    /// 约束，因此不会形成循环，也不会偷偷切换用户选择的模型。
    private func shouldRetryInitialPlannerRequest(_ error: Error) -> Bool {
        guard !(error is VoicePolishLedgerTimeoutError),
              !(error is CancellationError) else { return false }
        if let urlError = error as? URLError {
            return [
                .timedOut, .cannotFindHost, .cannotConnectToHost,
                .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
                .resourceUnavailable,
            ].contains(urlError.code)
        }
        guard let llmError = error as? LLMError else { return false }
        switch llmError {
        case .requestFailed(let statusCode):
            return statusCode == 0
                || statusCode == 408
                || statusCode == 425
                || (500...599).contains(statusCode)
        case .emptyResponse, .truncatedResponse:
            return true
        case .requestRejected(let statusCode, _):
            return statusCode == 408
                || statusCode == 425
                || (500...599).contains(statusCode)
        case .invalidURL, .responseTooLarge, .timedOut:
            return false
        }
    }

    private func blockingIssues(
        review: VoicePolishReviewerResult,
        deterministic: [VoicePolishReviewerIssue],
        ledger: VoicePolishIntentLedger,
        validSpanIDs: Set<String>
    ) -> [VoicePolishReviewerIssue] {
        let modelIssues = review.issues.filter { issue in
            !issue.repairInstruction.isEmpty
                && issue.sourceSpanIds.allSatisfy(validSpanIDs.contains)
        }
        // Reviewer 不接收候选角色，不能因 Planner 标了 remove 就吞掉 missing。
        var seen: Set<String> = []
        return (modelIssues + deterministic).filter {
            let key = [$0.type, $0.unitIds.joined(separator: ","), $0.repairInstruction]
                .joined(separator: "\u{0}")
            return seen.insert(key).inserted
        }
    }

    /// 冷复核发现被错误排除的正文时需要重规划，不能在没有 fragment 的单元上
    /// 局部修补。正文已有片段的角色或遗漏问题仍可进入局部修复。
    private func issueRequiresLedgerReplan(
        _ issue: VoicePolishReviewerIssue,
        ledger: VoicePolishIntentLedger
    ) -> Bool {
        guard ["wrong_role", "missing"].contains(issue.type), !issue.unitIds.isEmpty else { return false }
        let unitByID = Dictionary(uniqueKeysWithValues: ledger.units.map { ($0.id, $0) })
        return issue.unitIds.contains {
            guard let unit = unitByID[$0] else { return true }
            return unit.deliveryRole != "recipient_content" || unit.status == "remove"
        }
    }

    private func outputBudget(source: String, baseline: Int) -> Int {
        min(8_192, max(baseline, EstimatedTokenCounter.count(in: source) * 2 + 1_024))
    }

    private func unavailable(
        stage: VoicePolishLedgerFailureStage,
        attempts: Int,
        code: VoicePolishValidationCode,
        error: Error,
        rejectedDraft: String? = nil
    ) -> VoicePolishLedgerRunResult {
        if case VoicePolishLedgerIntegrityError.invalidLedgerReason(let reason) = error,
           reason.hasPrefix("semantic_") {
            return .unavailable(stage: stage, attempts: attempts,
                codes: [.semanticDecisionUnverified], reason: .validationFailed, rejectedDraft: rejectedDraft)
        }
        return .unavailable(
            stage: stage,
            attempts: attempts,
            codes: [code],
            reason: error is VoicePolishLedgerTimeoutError ? .timeout : .requestFailed,
            rejectedDraft: rejectedDraft
        )
    }
}
