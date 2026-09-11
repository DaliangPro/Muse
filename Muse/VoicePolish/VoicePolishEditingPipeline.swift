import Foundation
import os

private struct VoicePolishEditingTimeout: Error {}

/// 只在实际进入客户端调用时计数；结果冻结后，迟到的超时任务不能再增加次数。
private final class VoicePolishEditingAttempts: Sendable {
    private struct State { var count = 0; var finished = false }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin() throws {
        try state.withLock { value in
            guard !value.finished else { throw CancellationError() }
            value.count += 1
        }
    }

    func finish() -> Int {
        state.withLock { value in
            value.finished = true
            return value.count
        }
    }
}

/// 两档内容修正都使用受限局部补丁；标准额外组织完整来源片段，布局无正文改写权限。
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
        let attempts = VoicePolishEditingAttempts()
        var repairAttempts = 0
        var draft: String?
        func result(_ text: String?, codes: [VoicePolishValidationCode] = [],
                    reason: VoicePolishFailureReason? = nil) -> VoicePolishResult {
            VoicePolishResult(
                text: text ?? request.fallbackText,
                detectedRoute: route,
                executedRoute: route,
                llmAttemptCount: attempts.finish(),
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
            let initial = try await generate(
                task: isLight ? .voicePolishFast : .voicePolishRender,
                system: isLight ? VoicePolishEditingPrompts.light : VoicePolishEditingPrompts.standard,
                payload: VoicePolishEditingPrompts.payload(for: request),
                json: true,
                request: request,
                deadline: deadline, attempts: attempts
            )
            if isLight {
                let edits = try VoicePolishTextEditor.decode(initial)
                let requiresReview = VoicePolishEditingReview.hasSourceReviewRisk(request.fallbackText)
                    || VoicePolishTextEditor.requiresSemanticReview(edits, in: request.fallbackText)
                let output = try VoicePolishTextEditor.apply(
                    edits, to: request.fallbackText, source: request.fallbackText, mode: .light,
                    allowsReviewedInlineDirectives: requiresReview,
                    allowsReviewedSourceCorrections: requiresReview
                )
                draft = output
                var codes = Self.outputCodes(output, request: request)
                if VoicePolishValidator.deliberateRepetitionPhrases(in: request.fallbackText)
                    .contains(where: { !output.contains($0) }) {
                    codes.append(.missingProtectedFact)
                }
                guard codes.isEmpty else { return result(nil, codes: codes) }
                if requiresReview {
                    // 原文有风险时，空补丁也须核对；模型不能同时决定漏改和免审。
                    let review = try await generate(
                        task: .voicePolishAnalyze,
                        system: VoicePolishEditingPrompts.lightReview,
                        payload: VoicePolishEditingPrompts.payload(for: request, draft: output),
                        json: true, request: request, deadline: deadline, attempts: attempts
                    )
                    let assessment = try VoicePolishEditingReview.decode(review, source: request.fallbackText)
                    if assessment.edits.isEmpty {
                        return assessment.containsUnappliedEditorInstruction(in: output)
                            ? result(nil, codes: [.planIntegrityFailure]) : result(output)
                    }
                    // 只修一次实际稿上的局部问题，继续使用轻度权限；不得转入标准重写。
                    repairAttempts += 1
                    let repaired = try VoicePolishTextEditor.apply(
                        assessment.edits, to: output, source: request.fallbackText, mode: .light,
                        allowsReviewedInlineDirectives: true, allowsReviewedSourceCorrections: true
                    )
                    draft = repaired
                    var repairedCodes = Self.outputCodes(repaired, request: request)
                    if assessment.containsUnappliedEditorInstruction(in: repaired) {
                        repairedCodes.append(.planIntegrityFailure)
                    }
                    if VoicePolishValidator.deliberateRepetitionPhrases(in: request.fallbackText)
                        .contains(where: { !repaired.contains($0) }) {
                        repairedCodes.append(.missingProtectedFact)
                    }
                    guard repairedCodes.isEmpty else { return result(nil, codes: repairedCodes) }
                    let confirmation = try await generate(
                        task: .voicePolishAnalyze, system: VoicePolishEditingPrompts.lightReview,
                        payload: VoicePolishEditingPrompts.payload(for: request, draft: repaired),
                        json: true, request: request, deadline: deadline, attempts: attempts
                    )
                    let finalAssessment = try VoicePolishEditingReview.decode(confirmation, source: request.fallbackText)
                    guard finalAssessment.edits.isEmpty,
                          !finalAssessment.containsUnappliedEditorInstruction(in: repaired) else {
                        return result(nil, codes: [.planIntegrityFailure])
                    }
                    return result(repaired)
                }
                return result(output)
            }

            let initialDraft = try VoicePolishTextEditor.applyContentEdits(
                VoicePolishTextEditor.decode(initial), to: request.fallbackText, source: request.fallbackText,
                allowsReviewedInlineDirectives: true, allowsReviewedSourceCorrections: true
            )
            draft = initialDraft
            let initialCodes = Self.contentCodes(initialDraft, request: request)
            let initialSegments = try VoicePolishStructurePlan.segments(in: initialDraft)
            let review = try await generate(
                task: .voicePolishAnalyze,
                system: VoicePolishEditingPrompts.review,
                payload: VoicePolishEditingPrompts.payload(for: request, draft: initialDraft, codes: initialCodes),
                json: true,
                request: request,
                deadline: deadline, attempts: attempts
            )
            let assessment = try VoicePolishEditingReview.decode(
                review, source: request.fallbackText, structureSegments: initialSegments
            )
            let edits = assessment.edits
            if edits.isEmpty {
                guard !assessment.containsUnappliedEditorInstruction(in: initialDraft) else {
                    return result(nil, codes: [.planIntegrityFailure])
                }
                guard initialCodes.isEmpty, let layout = assessment.layout else {
                    return result(nil, codes: initialCodes.isEmpty ? [.planIntegrityFailure] : initialCodes)
                }
                let output = try VoicePolishStructurePlan.render(layout, segments: initialSegments)
                draft = output
                let content = try VoicePolishStructurePlan.render(layout, segments: initialSegments, includesMarkers: false)
                let codes = Self.outputCodes(output, request: request, contentForValidation: content)
                return codes.isEmpty ? result(output) : result(nil, codes: codes)
            }
            repairAttempts += 1
            let repaired = try VoicePolishTextEditor.applyContentEdits(
                edits, to: initialDraft, source: request.fallbackText,
                allowsReviewedInlineDirectives: true, allowsReviewedSourceCorrections: true
            )
            draft = repaired
            var repairedCodes = Self.contentCodes(repaired, request: request)
            if assessment.containsUnappliedEditorInstruction(in: repaired) {
                repairedCodes.append(.planIntegrityFailure)
            }
            guard repairedCodes.isEmpty else { return result(nil, codes: repairedCodes) }
            let repairedSegments = try VoicePolishStructurePlan.segments(in: repaired)

            // 修复后的实际成稿必须重新核对；确认阶段没有继续改写的权限。
            let confirmation = try await generate(
                task: .voicePolishAnalyze,
                system: VoicePolishEditingPrompts.review,
                payload: VoicePolishEditingPrompts.payload(for: request, draft: repaired),
                json: true,
                request: request,
                deadline: deadline, attempts: attempts
            )
            let finalAssessment = try VoicePolishEditingReview.decode(
                confirmation, source: request.fallbackText, structureSegments: repairedSegments
            )
            guard finalAssessment.edits.isEmpty,
                  !finalAssessment.containsUnappliedEditorInstruction(in: repaired),
                  let layout = finalAssessment.layout else {
                return result(nil, codes: [.planIntegrityFailure])
            }
            let output = try VoicePolishStructurePlan.render(layout, segments: repairedSegments)
            draft = output
            let content = try VoicePolishStructurePlan.render(layout, segments: repairedSegments, includesMarkers: false)
            let codes = Self.outputCodes(output, request: request, contentForValidation: content)
            return codes.isEmpty ? result(output) : result(nil, codes: codes)
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
        } catch is VoicePolishEditingReviewError {
            return result(nil, codes: [.invalidStructuredResponse])
        } catch is VoicePolishTextEditError {
            return result(nil, codes: [.planIntegrityFailure])
        } catch is VoicePolishStructurePlanError {
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
        deadline: ContinuousClock.Instant,
        attempts: VoicePolishEditingAttempts
    ) async throws -> String {
        try Task.checkCancellation()
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw VoicePolishEditingTimeout() }
        onStage?(task == .voicePolishAnalyze ? .analyzing : .polishing)
        let sourceTokens = EstimatedTokenCounter.count(in: request.fallbackText)
        // 复核返回短编辑摘录与局部补丁，沿用受控输出容量与总时限。
        let outputBudget: Int
        if task == .voicePolishAnalyze {
            outputBudget = min(8_192, max(4_096, sourceTokens * 4 + 1_024))
        } else if request.qualityMode == .standard {
            // JSON 同时携带修改前后的短锚点，比自由正文需要更多输出容量。
            outputBudget = min(8_192, max(4_096, sourceTokens * 6 + 1_024))
        } else {
            outputBudget = min(8_192, max(2_048, sourceTokens * 3 + 512))
        }
        let invocation = LLMRequest(
            // 内置编辑协议自行定义输入边界；不能套用“正文绝不影响转换”的通用
            // 自定义模式封装，否则口述中的合法改口与当前编辑要求也可能被忽略。
            context: .structuredTask,
            task: task,
            system: system,
            user: payload,
            options: LLMGenerationOptions(
                temperature: 0,
                maxOutputTokens: outputBudget,
                reasoningPolicy: .disabled,
                responseFormat: json ? .jsonObject : .text
            )
        )
        let response = try await AsyncTimeout.throwingValue(
            min(remaining, stageTimeout ?? .seconds(30)),
            timeoutError: VoicePolishEditingTimeout()
        ) {
            try Task.checkCancellation()
            guard deadline > ContinuousClock.now else { throw VoicePolishEditingTimeout() }
            try attempts.begin()
            return try await client.generate(invocation, config: config)
        }
        return response.text
    }

    private static func contentCodes(_ output: String, request: VoicePolishRequest) -> [VoicePolishValidationCode] {
        var codes = outputCodes(output, request: request)
        if VoicePolishValidator.deliberateRepetitionPhrases(in: request.fallbackText)
            .contains(where: { !output.contains($0) }) {
            codes.append(.missingProtectedFact)
        }
        return codes
    }

    static func outputCodes(
        _ output: String, request: VoicePolishRequest, contentForValidation: String? = nil
    ) -> [VoicePolishValidationCode] {
        var codes: [VoicePolishValidationCode] = []
        // 正文视图只能由已验证布局逐字拼装，不能从模型输出用正则猜掉数字。
        let content = contentForValidation ?? output
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { codes.append(.emptyOutput) }
        if VoicePolishCharacterSafety.containsUnsafeCharacters(output) { codes.append(.unsafeCharacters) }
        if output.utf8.count > VoicePolishOutputNormalizer.maximumResponseBytes
            || content.count > max(request.fallbackText.count * 2, request.fallbackText.count + 40) {
            codes.append(.abnormalLength)
        }
        codes += VoicePolishLedgerIntegrityValidator.sourceBackedDraftCodes(
            sourceText: request.fallbackText, outputText: content, scene: request.context.scene,
            allowsPartialTimeReview: request.qualityMode == .standard
        )
        return codes
    }
}
