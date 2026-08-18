import Foundation

private struct VoicePolishLedgerTimeoutError: Error {}
private struct VoicePolishLedgerPlanValidationError: Error {}

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

    /// 核心语义对照中，Flash 在保密边界和技术标识样本上出现安全退出，Pro
    /// 均完成成稿。日常风险短文和约 1K 长文因此在官方 DeepSeek 端点内部
    /// 自动使用 Pro；普通极短文本和 1,800 字以上压力路径仍尊重用户原模型。
    /// 这属于单一“语音润色”模式下的内部策略，不向用户暴露强弱档位。
    static func qualityConfig(for config: LLMConfig) -> LLMConfig {
        guard config.model == "deepseek-v4-flash",
              URLComponents(string: config.baseURL)?.host?.lowercased()
                == "api.deepseek.com" else {
            return config
        }
        return config.withModel("deepseek-v4-pro")
    }

    /// 官方 DeepSeek 链路用 Pro 规划和写作、Flash 冷复核，避免同一个模型
    /// 同时制造并认可自己的语义遗漏。其他 Provider 没有可证明的同源双模型时
    /// 保持用户配置不变。
    static func reviewConfig(for config: LLMConfig) -> LLMConfig {
        guard ["deepseek-v4-flash", "deepseek-v4-pro"].contains(config.model),
              URLComponents(string: config.baseURL)?.host?.lowercased()
                == "api.deepseek.com" else {
            return config
        }
        return config.withModel("deepseek-v4-flash")
    }

    static func shouldUse(
        for request: VoicePolishRequest,
        minimumCharacterCount: Int = 80
    ) -> Bool {
        let text = request.input.fallbackText
        // Ledger 的主场景是日常中长口述。80 字以下继续使用成熟的一次 Fast
        // 成稿与本地硬门禁，避免一句改口承担 Planner JSON 修复和冷复核的
        // 延迟；80～279 字只有出现明确风险才升级，280～1,800 字统一使用。
        // 更长文本仍留给既有有界分片链路，作为压力边界单独演进。
        guard text.count >= max(0, minimumCharacterCount), text.count <= 1_800 else {
            return false
        }
        if text.count >= 280 { return true }
        if !request.resolvedEntities.isEmpty || !request.input.requiredEntityEdits.isEmpty {
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
        let ledger: VoicePolishIntentLedger
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
                maxOutputTokens: outputBudget(source: request.input.fallbackText, baseline: 4_096),
                timeout: .seconds(60),
                deadline: deadline,
                config: generationConfig
            )
            ledger = try decodedAndValidatedLedger(
                rawPlanResponse,
                request: request,
                spans: spans,
                mappings: mappings,
                requiredLogicCues: requiredLogicCues
            )
        } catch is VoicePolishLedgerPlanValidationError {
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
                        error: VoicePolishLedgerPlanValidationError()
                    ),
                    responseFormat: .jsonObject,
                    maxOutputTokens: outputBudget(source: request.input.fallbackText, baseline: 4_096),
                    timeout: .seconds(60),
                    deadline: deadline,
                    config: generationConfig
                )
                ledger = try decodedAndValidatedLedger(
                    repairedPlan,
                    request: request,
                    spans: spans,
                    mappings: mappings,
                    requiredLogicCues: requiredLogicCues
                )
            } catch let finalError {
                let reason: VoicePolishFailureReason
                if finalError is VoicePolishLedgerTimeoutError {
                    reason = .timeout
                } else if finalError is VoicePolishLedgerPlanValidationError {
                    reason = .validationFailed
                } else {
                    reason = .requestFailed
                }
                return .unavailable(
                    stage: .planning,
                    attempts: attempts,
                    codes: [.planIntegrityFailure],
                    reason: reason
                )
            }
        } catch let error {
            return unavailable(
                stage: .planning,
                attempts: attempts,
                code: .invalidStructuredResponse,
                error: error
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
            maxOutputTokens: 3_072,
            timeout: timeout,
            deadline: deadline,
            config: reviewerConfig
        )
        let review = try decode(VoicePolishReviewerResult.self, from: response)
        let allowedVerdicts = Set(["pass", "repair", "unsafe"])
        let allowedTypes = Set([
            "missing", "wrong_relation", "wrong_condition", "wrong_modality",
            "obsolete_retained", "invented", "context_leak", "task_layer",
            "instruction_leak", "style_shift",
        ])
        let validSpanIDs = Set(spans.map(\.id))
        let unitByID = Dictionary(uniqueKeysWithValues: ledger.units.map { ($0.id, $0) })
        let validUnitIDs = Set(unitByID.keys)
        let rendered = renderedText(from: draft, ledger: ledger)
        guard allowedVerdicts.contains(review.verdict),
              review.verdict != "pass" || review.issues.isEmpty,
              review.verdict != "repair" || !review.issues.isEmpty,
              review.issues.allSatisfy({ issue in
                  allowedTypes.contains(issue.type)
                      && ["minor", "major"].contains(issue.severity)
                      && !issue.unitIds.isEmpty
                      && !issue.sourceSpanIds.isEmpty
                      && issue.sourceSpanIds.allSatisfy(validSpanIDs.contains)
                      && issue.unitIds.allSatisfy(validUnitIDs.contains)
                      && issue.unitIds.contains(where: { unitID in
                          guard let unit = unitByID[unitID] else { return false }
                          return !Set(unit.sourceSpanIds).isDisjoint(with: issue.sourceSpanIds)
                      })
                      && ((issue.draftSpan ?? "").isEmpty
                          || rendered.contains(issue.draftSpan ?? ""))
                      && !issue.repairInstruction.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
              }) else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
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
                        reasoningPolicy: .low,
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
        } catch {
            throw VoicePolishLedgerPlanValidationError()
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
        try jsonString([
            "writing_scene": request.context.scene.rawValue,
            "source_spans": try jsonObject(spans),
            "required_logic_cues": try jsonObject(requiredLogicCues),
            "verified_entity_mappings": try jsonObject(mappings),
            "additional_requirements": request.preferences.additionalRequirements,
            "invalid_ledger_response": String(invalidResponse.prefix(24_000)),
            "validation_error": String(describing: error),
        ])
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
            "intent_ledger": try jsonObject(ledger),
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
        guard document.fragments.count == expectedIDs.count else {
            throw VoicePolishLedgerIntegrityError.invalidLedger
        }
        var fragmentByUnitID: [String: VoicePolishLedgerDraftFragment] = [:]
        var fragmentIDs: Set<String> = []
        for fragment in document.fragments {
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
            if ledger.structure.kind == "numbered_list" {
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
                text: text
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
        case "paragraphs", "mixed", "ai_prompt":
            return texts.joined(separator: "\n\n")
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

    private func blockingIssues(
        review: VoicePolishReviewerResult,
        deterministic: [VoicePolishReviewerIssue],
        ledger: VoicePolishIntentLedger,
        validSpanIDs: Set<String>
    ) -> [VoicePolishReviewerIssue] {
        let roleByUnitID = Dictionary(uniqueKeysWithValues: ledger.units.map { ($0.id, $0.deliveryRole) })
        let modelIssues = review.issues.filter { issue in
            guard !issue.repairInstruction.isEmpty,
                  issue.sourceSpanIds.allSatisfy(validSpanIDs.contains) else { return false }
            let onlyNonRecipient = !issue.unitIds.isEmpty && issue.unitIds.allSatisfy {
                guard let role = roleByUnitID[$0] else { return false }
                return role != "recipient_content"
            }
            if onlyNonRecipient,
               issue.type == "missing",
               (issue.draftSpan ?? "").isEmpty {
                return false
            }
            return true
        }
        var seen: Set<String> = []
        return (modelIssues + deterministic).filter {
            let key = [$0.type, $0.unitIds.joined(separator: ","), $0.repairInstruction]
                .joined(separator: "\u{0}")
            return seen.insert(key).inserted
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
        .unavailable(
            stage: stage,
            attempts: attempts,
            codes: [code],
            reason: error is VoicePolishLedgerTimeoutError ? .timeout : .requestFailed,
            rejectedDraft: rejectedDraft
        )
    }
}
