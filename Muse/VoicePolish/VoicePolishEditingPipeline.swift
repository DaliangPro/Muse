import Foundation

private struct VoicePolishEditingTimeout: Error {}

/// 轻度把修改权限限定为原文上的局部补丁；标准直接成稿并冷复核实际改动。
/// 两条路径都保留不可变来源，不把 Planner 的摘要当作完整事实来源。
struct VoicePolishEditingPipeline: Sendable {
    private let client: any LLMClient
    private let config: LLMConfig
    private let totalTimeout: Duration?
    private let stageTimeout: Duration?
    private let onStage: (@Sendable (VoicePolishStage) -> Void)?

    init(
        client: any LLMClient,
        config: LLMConfig,
        totalTimeout: Duration? = nil,
        stageTimeout: Duration? = nil,
        onStage: (@Sendable (VoicePolishStage) -> Void)? = nil
    ) {
        self.client = client
        self.config = config
        self.totalTimeout = totalTimeout
        self.stageTimeout = stageTimeout
        self.onStage = onStage
    }

    func process(_ request: VoicePolishRequest) async -> VoicePolishResult {
        let isLight = request.qualityMode == .light
        let route: VoicePolishRoute = isLight ? .fast : .structured
        let deadline = ContinuousClock.now.advanced(by: totalTimeout ?? (isLight ? .seconds(20) : .seconds(60)))
        var attempts = 0
        var repairAttempts = 0
        var draft: String?
        func result(_ text: String?, codes: [VoicePolishValidationCode] = [],
                    reason: VoicePolishFailureReason? = nil) -> VoicePolishResult {
            VoicePolishResult(
                text: text ?? request.fallbackText,
                detectedRoute: route,
                executedRoute: route,
                llmAttemptCount: attempts,
                validationCodes: codes,
                usedFallback: text == nil,
                failureReason: text == nil ? (reason ?? .validationFailed) : nil,
                rejectedDraft: text == nil ? draft : nil,
                repairAttemptCount: repairAttempts
            )
        }
        guard request.qualityMode == .light || request.qualityMode == .standard else {
            return result(nil, reason: .setupFailed)
        }
        do {
            try Task.checkCancellation()
            attempts += 1
            let initial = try await generate(
                task: isLight ? .voicePolishFast : .voicePolishRender,
                system: isLight ? VoicePolishEditingPrompts.light : VoicePolishEditingPrompts.standard,
                payload: VoicePolishEditingPrompts.payload(for: request),
                json: isLight,
                request: request,
                deadline: deadline
            )
            if isLight {
                let edits = try VoicePolishTextEditor.decode(initial)
                let requiresReview = edits.contains { [.word, .correction, .directive].contains($0.kind) }
                let output = try VoicePolishTextEditor.apply(
                    edits, to: request.fallbackText, source: request.fallbackText, mode: .light,
                    allowsReviewedInlineDirectives: requiresReview
                )
                draft = output
                var codes = Self.outputCodes(output, request: request)
                if VoicePolishValidator.deliberateRepetitionPhrases(in: request.fallbackText)
                    .contains(where: { !output.contains($0) }) {
                    codes.append(.missingProtectedFact)
                }
                guard codes.isEmpty else { return result(nil, codes: codes) }
                if requiresReview {
                    // 字词、改口与编辑要求涉及含义，必须核对实际局部稿；审核不能追加改写。
                    attempts += 1
                    let review = try await generate(
                        task: .voicePolishAnalyze,
                        system: VoicePolishEditingPrompts.lightReview,
                        payload: VoicePolishEditingPrompts.payload(for: request, draft: output),
                        json: true, request: request, deadline: deadline
                    )
                    guard try VoicePolishTextEditor.decode(review).isEmpty else {
                        return result(nil, codes: [.planIntegrityFailure])
                    }
                }
                return result(output)
            }

            guard let initialDraft = VoicePolishOutputNormalizer.plainText(initial, sourceText: request.fallbackText) else {
                return result(nil, codes: [.abnormalLength])
            }
            draft = initialDraft
            // 标准始终对照真实首稿复核，避免“字面相近”掩盖一个字的否定或单位变化。
            let initialCodes = Self.outputCodes(initialDraft, request: request)
            attempts += 1
            let review = try await generate(
                task: .voicePolishAnalyze,
                system: VoicePolishEditingPrompts.review,
                payload: VoicePolishEditingPrompts.payload(for: request, draft: initialDraft, codes: initialCodes),
                json: true,
                request: request,
                deadline: deadline
            )
            let edits = try VoicePolishTextEditor.decode(review)
            if edits.isEmpty {
                return initialCodes.isEmpty ? result(initialDraft) : result(nil, codes: initialCodes)
            }
            repairAttempts += 1
            let repaired = try VoicePolishTextEditor.apply(
                edits, to: initialDraft, source: request.fallbackText, mode: .standard
            )
            draft = repaired
            let repairedCodes = Self.outputCodes(repaired, request: request)
            guard repairedCodes.isEmpty else { return result(nil, codes: repairedCodes) }

            // 修复后的实际成稿必须重新核对；确认阶段没有继续改写的权限。
            attempts += 1
            let confirmation = try await generate(
                task: .voicePolishAnalyze,
                system: VoicePolishEditingPrompts.review,
                payload: VoicePolishEditingPrompts.payload(for: request, draft: repaired),
                json: true,
                request: request,
                deadline: deadline
            )
            guard try VoicePolishTextEditor.decode(confirmation).isEmpty else {
                return result(nil, codes: [.planIntegrityFailure])
            }
            return result(repaired)
        } catch is VoicePolishEditingTimeout {
            return result(nil, codes: [.emptyOutput], reason: .timeout)
        } catch let error as LLMError {
            switch error {
            case .timedOut:
                return result(nil, codes: [.emptyOutput], reason: .timeout)
            case .truncatedResponse, .responseTooLarge:
                return result(nil, codes: [.abnormalLength])
            default:
                return result(nil, codes: [.emptyOutput], reason: .requestFailed)
            }
        } catch is VoicePolishTextEditError {
            return result(nil, codes: [.planIntegrityFailure])
        } catch is DecodingError {
            return result(nil, codes: [.invalidStructuredResponse])
        } catch {
            return result(nil, codes: [.emptyOutput], reason: .requestFailed)
        }
    }

    private func generate(
        task: LLMTask,
        system: String,
        payload: String,
        json: Bool,
        request: VoicePolishRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        try Task.checkCancellation()
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw VoicePolishEditingTimeout() }
        onStage?(task == .voicePolishAnalyze ? .analyzing : .polishing)
        let invocation = LLMRequest(
            // 内置编辑协议自行定义输入边界；不能套用“正文绝不影响转换”的通用
            // 自定义模式封装，否则口述中的合法改口与当前编辑要求也可能被忽略。
            context: .structuredTask,
            task: task,
            system: system,
            user: payload,
            options: LLMGenerationOptions(
                temperature: 0,
                maxOutputTokens: min(8_192, max(2_048, EstimatedTokenCounter.count(in: request.fallbackText) * 3 + 512)),
                reasoningPolicy: .disabled,
                responseFormat: json ? .jsonObject : .text
            )
        )
        let response = try await AsyncTimeout.throwingValue(
            min(remaining, stageTimeout ?? .seconds(30)),
            timeoutError: VoicePolishEditingTimeout()
        ) {
            try await client.generate(invocation, config: config)
        }
        return response.text
    }

    static func outputCodes(_ output: String, request: VoicePolishRequest) -> [VoicePolishValidationCode] {
        var codes: [VoicePolishValidationCode] = []
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { codes.append(.emptyOutput) }
        if VoicePolishCharacterSafety.containsUnsafeCharacters(output) { codes.append(.unsafeCharacters) }
        if output.count > max(request.fallbackText.count * 2, request.fallbackText.count + 40) {
            codes.append(.abnormalLength)
        }
        codes += VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: request.fallbackText, outputText: output, scene: request.context.scene,
            allowsPartialTimeReview: request.qualityMode == .standard
        )
        return codes
    }
}
