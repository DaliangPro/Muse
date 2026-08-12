import Foundation

private struct VoicePolishStageTimeoutError: Error {}

struct VoicePolishPipeline: Sendable {
    private static let baselineFirstRequestTimeout: Duration = .seconds(30)
    private static let baselineTotalTimeout: Duration = .seconds(45)
    private static let maximumFirstRequestTimeout: Int64 = 90
    private static let maximumTotalTimeout: Int64 = 105
    private static let maximumOutputTokens = 8_192

    private let client: any LLMClient
    private let config: LLMConfig
    private let totalTimeout: Duration
    private let firstRequestTimeout: Duration
    private let usesAdaptiveTotalTimeout: Bool
    private let usesAdaptiveFirstRequestTimeout: Bool
    private let analyzeTimeout: Duration
    private let renderTimeout: Duration
    private let repairTimeout: Duration
    private let onStage: (@Sendable (VoicePolishStage) -> Void)?

    init(
        client: any LLMClient,
        config: LLMConfig,
        totalTimeout: Duration? = nil,
        firstRequestTimeout: Duration? = nil,
        analyzeTimeout: Duration = .seconds(15),
        renderTimeout: Duration = .seconds(20),
        repairTimeout: Duration = .seconds(10),
        onStage: (@Sendable (VoicePolishStage) -> Void)? = nil
    ) {
        self.client = client
        self.config = config
        self.totalTimeout = totalTimeout ?? Self.baselineTotalTimeout
        self.firstRequestTimeout = firstRequestTimeout ?? Self.baselineFirstRequestTimeout
        self.usesAdaptiveTotalTimeout = totalTimeout == nil
        self.usesAdaptiveFirstRequestTimeout = firstRequestTimeout == nil
        self.analyzeTimeout = analyzeTimeout
        self.renderTimeout = renderTimeout
        self.repairTimeout = repairTimeout
        self.onStage = onStage
    }

    /// 长内容的成稿通常接近原文长度。固定 2048 tokens 会让 Provider 正常地
    /// 以长度上限结束，随后被事实校验回退成原文。预算按 canonical 正文估算，
    /// 但统一封顶，避免异常输入把单次请求无限放大。
    static func outputTokenBudget(
        for request: VoicePolishRequest,
        task: LLMTask
    ) -> Int {
        let sourceTokens = min(
            EstimatedTokenCounter.count(in: request.fallbackText),
            maximumOutputTokens
        )
        let baseline: Int
        let estimated: Int
        switch task {
        case .voicePolishFast:
            baseline = 2_048
            estimated = sourceTokens * 3 / 2 + 512
        case .voicePolishRender:
            baseline = 3_072
            estimated = sourceTokens * 3 / 2 + 512
        case .voicePolishAnalyze, .voicePolishStructured, .voicePolishRepair:
            baseline = 4_096
            estimated = sourceTokens * 2 + 1_024
        case .generic:
            return 2_048
        }
        return min(maximumOutputTokens, max(baseline, estimated))
    }

    /// 默认预算才随正文增长；测试或特殊调用显式注入的短超时必须原样保留。
    /// 按每秒约 96 个输出 tokens 预留增量，且用户仍可通过 HUD 主动使用原文。
    static func defaultFirstRequestTimeout(for request: VoicePolishRequest) -> Duration {
        let outputTokens = outputTokenBudget(for: request, task: .voicePolishFast)
        let extraTokens = max(0, outputTokens - 2_048)
        let extraSeconds = Int64((extraTokens + 95) / 96)
        return .seconds(min(maximumFirstRequestTimeout, 30 + extraSeconds))
    }

    private static func defaultTotalTimeout(for request: VoicePolishRequest) -> Duration {
        let firstSeconds = defaultFirstRequestTimeout(for: request).components.seconds
        return .seconds(min(maximumTotalTimeout, max(45, firstSeconds + 15)))
    }

    func process(
        _ request: VoicePolishRequest,
        startedAt suppliedStart: ContinuousClock.Instant? = nil
    ) async -> VoicePolishResult {
        let startedAt = suppliedStart ?? ContinuousClock.now
        let sourceFactSegments = request.context.scene == .code
            ? request.input.segments
            : VoicePolishNumbering.removingContinuousNumberedLineMarkers(
                from: request.input.segments
            )
        let sourceFacts = ProtectedFactExtractor.extract(from: sourceFactSegments)
            + request.resolvedEntities.map {
                SourceFactCandidate(
                    sourceText: $0.surfaceText,
                    canonicalValue: $0.canonical,
                    kind: .lexiconEntity,
                    sourceSegmentIDs: $0.sourceSegmentIDs
                )
            }
        let decision = VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: sourceFacts
        )
        let executedRoute = VoicePolishComplexityRouter.executedRoute(
            for: decision,
            request: request
        )
        let maximumAttempts: Int
        switch executedRoute {
        case .fast:
            maximumAttempts = 1
        case .structured:
            maximumAttempts = request.qualityMode == .fast ? 1 : 2
        case .deep:
            maximumAttempts = 3
        }

        DebugFileLogger.log(
            "voice polish start route=\(decision.route.rawValue) executed=\(executedRoute.rawValue) quality=\(request.qualityMode.rawValue) input=\(request.fallbackText.count)chars facts=\(sourceFacts.count)"
        )

        do {
            let payload = try VoicePolishPrompts.payload(
                for: request,
                sourceFacts: sourceFacts,
                deepDeferred: false
            )
            if executedRoute == .fast {
                return await runFast(
                    request: request,
                    payload: payload,
                    sourceFacts: sourceFacts,
                    detectedRoute: decision.route,
                    startedAt: startedAt
                )
            }
            if executedRoute == .deep {
                return await runDeep(
                    request: request,
                    payload: payload,
                    sourceFacts: sourceFacts,
                    detectedRoute: decision.route,
                    startedAt: startedAt
                )
            }
            return await runStructured(
                request: request,
                payload: payload,
                sourceFacts: sourceFacts,
                detectedRoute: decision.route,
                maximumAttempts: maximumAttempts,
                startedAt: startedAt
            )
        } catch {
            return fallback(
                request: request,
                detectedRoute: decision.route,
                executedRoute: executedRoute,
                attempts: 0,
                codes: [.emptyOutput],
                reason: .setupFailed
            )
        }
    }

    private func runDeep(
        request: VoicePolishRequest,
        payload: String,
        sourceFacts: [SourceFactCandidate],
        detectedRoute: VoicePolishRoute,
        startedAt: ContinuousClock.Instant
    ) async -> VoicePolishResult {
        var attempts = 0
        let analyzerRaw: String
        do {
            let timeout = try availableTimeout(
                stageLimit: analyzeTimeout,
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            analyzerRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishAnalyze,
                    system: VoicePolishPrompts.analyzer,
                    user: payload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishAnalyze
                        ),
                        reasoningPolicy: .low,
                        responseFormat: .jsonObject
                    )
                ),
                timeout: timeout
            ).text
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [.invalidStructuredResponse],
                reason: failureReason(for: error)
            )
        }

        var plan: VoicePolishPlan
        do {
            plan = try StructuredLLMDecoder.decode(VoicePolishPlan.self, from: analyzerRaw)
        } catch {
            let decodeCode = validationCode(for: error)
            guard analyzerRaw.utf8.count <= VoicePolishOutputNormalizer.maximumResponseBytes else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .deep,
                    attempts: attempts,
                    codes: [decodeCode]
                )
            }
            do {
                let timeout = try availableTimeout(
                    stageLimit: repairTimeout,
                    startedAt: startedAt,
                    request: request
                )
                attempts += 1
                let repairPayload = try VoicePolishPrompts.repairPayload(
                    originalPayload: payload,
                    rawResponse: analyzerRaw,
                    validationCodes: [decodeCode]
                )
                let repairedRaw = try await generate(
                    LLMRequest(
                        context: .processingMode,
                        task: .voicePolishRepair,
                        system: VoicePolishPrompts.planFormatRepair,
                        user: repairPayload,
                        options: LLMGenerationOptions(
                            temperature: 0,
                            maxOutputTokens: Self.outputTokenBudget(
                                for: request,
                                task: .voicePolishRepair
                            ),
                            reasoningPolicy: .disabled,
                            responseFormat: .jsonObject
                        )
                    ),
                    timeout: timeout
                ).text
                plan = try StructuredLLMDecoder.decode(VoicePolishPlan.self, from: repairedRaw)
            } catch {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .deep,
                    attempts: attempts,
                    codes: [validationCode(for: error)],
                    reason: failureReason(for: error)
                )
            }
        }
        plan = normalizedPlanLayout(plan, request: request)

        let planValidation = VoicePolishValidator.validatePlan(
            plan,
            request: request,
            sourceFacts: sourceFacts
        )
        guard !planValidation.hasHardFailure else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: planValidation.codes
            )
        }

        let renderPayload: String
        let renderRaw: String
        do {
            let timeout = try availableTimeout(
                stageLimit: renderTimeout,
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            renderPayload = try VoicePolishPrompts.renderPayload(
                for: request,
                plan: plan
            )
            renderRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishRender,
                    system: VoicePolishPrompts.renderer,
                    user: renderPayload,
                    options: LLMGenerationOptions(
                        temperature: 0.2,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishRender
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            ).text
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [.emptyOutput],
                reason: failureReason(for: error)
            )
        }

        guard let renderedDraft = VoicePolishOutputNormalizer.plainText(
            renderRaw,
            sourceText: request.fallbackText
        ) else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [.abnormalLength]
            )
        }
        let rendered = normalizedLayoutText(renderedDraft, request: request)
        let validation = VoicePolishValidator.validateStructured(
            response: StructuredVoicePolishResponse(plan: plan, finalText: rendered),
            request: request,
            sourceFacts: sourceFacts
        )
        guard validation.hasHardFailure else {
            return success(
                text: rendered,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: validation.codes
            )
        }

        // Analyzer 曾使用格式修复时已消耗三次预算，Renderer 失败直接回退。
        guard attempts < 3 else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: validation.codes
            )
        }
        do {
            let timeout = try availableTimeout(
                stageLimit: repairTimeout,
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            let repairPayload = try VoicePolishPrompts.renderRepairPayload(
                validatedRenderPayload: renderPayload,
                rawResponse: renderRaw,
                validationCodes: validation.codes.filter(\.isHardFailure)
            )
            let repairedRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishRepair,
                    system: VoicePolishPrompts.renderRepair,
                    user: repairPayload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishRepair
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            ).text
            guard let repairedDraft = VoicePolishOutputNormalizer.plainText(
                repairedRaw,
                sourceText: request.fallbackText
            ) else {
                throw StructuredLLMDecoderError.invalidJSON
            }
            let repaired = normalizedLayoutText(repairedDraft, request: request)
            let repairedValidation = VoicePolishValidator.validateStructured(
                response: StructuredVoicePolishResponse(plan: plan, finalText: repaired),
                request: request,
                sourceFacts: sourceFacts
            )
            guard !repairedValidation.hasHardFailure else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .deep,
                    attempts: attempts,
                    codes: repairedValidation.codes
                )
            }
            return success(
                text: repaired,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: repairedValidation.codes
            )
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .deep,
                attempts: attempts,
                codes: [validationCode(for: error)],
                reason: failureReason(for: error)
            )
        }
    }

    private func runFast(
        request: VoicePolishRequest,
        payload: String,
        sourceFacts: [SourceFactCandidate],
        detectedRoute: VoicePolishRoute,
        startedAt: ContinuousClock.Instant
    ) async -> VoicePolishResult {
        var attempts = 0
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveFirstRequestTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts = 1
            let response = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishFast,
                    system: VoicePolishPrompts.fast,
                    user: payload,
                    options: LLMGenerationOptions(
                        // 语音成稿追求同输入稳定收敛，创意随机性只会放大漏约束、
                        // 旧改口残留和幕后指令泄漏的概率。
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishFast
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            )
            guard let outputDraft = VoicePolishOutputNormalizer.plainText(
                response.text,
                sourceText: request.fallbackText
            ) else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: [.abnormalLength]
                )
            }
            let output = normalizedLayoutText(outputDraft, request: request)
            var finalOutput = VoicePolishValidator.removingDeterministicDraftArtifacts(
                from: output,
                request: request
            ) ?? output
            var validation = VoicePolishValidator.validateFast(
                output: finalOutput,
                request: request,
                sourceFacts: sourceFacts
            )
            if validation.codes.contains(.supersededFactRetained),
               let cleaned = VoicePolishValidator.removingParentheticalSupersededFacts(
                   from: finalOutput,
                   request: request,
                   sourceFacts: sourceFacts
               ) {
                let cleanedValidation = VoicePolishValidator.validateFast(
                    output: cleaned,
                    request: request,
                    sourceFacts: sourceFacts
                )
                if !cleanedValidation.hasHardFailure {
                    finalOutput = cleaned
                    validation = cleanedValidation
                }
            }
            let repairableFastCodes: Set<VoicePolishValidationCode> = [
                .explanationOnly,
                .promptLeakage,
                .missingProtectedFact,
                .supersededFactRetained,
                .excludedSideNoteLeaked,
                .planIntegrityFailure,
                .layoutRequirementUnmet,
            ]
            let hardCodes = validation.codes.filter(\.isHardFailure)
            if !hardCodes.isEmpty,
               hardCodes.allSatisfy(repairableFastCodes.contains) {
                do {
                    let timeout = try availableTimeout(
                        stageLimit: repairTimeout,
                        startedAt: startedAt,
                        request: request
                    )
                    attempts += 1
                    let repairPayload = try VoicePolishPrompts.fastRepairPayload(
                        originalPayload: payload,
                        rawResponse: finalOutput,
                        validationCodes: validation.codes.filter(\.isHardFailure),
                        request: request,
                        sourceFacts: sourceFacts
                    )
                    let repairedRaw = try await generate(
                        LLMRequest(
                            context: .processingMode,
                            task: .voicePolishRepair,
                            system: VoicePolishPrompts.fastContentRepair,
                            user: repairPayload,
                            options: LLMGenerationOptions(
                                temperature: 0,
                                maxOutputTokens: Self.outputTokenBudget(
                                    for: request,
                                    task: .voicePolishRepair
                                ),
                                reasoningPolicy: .disabled,
                                responseFormat: .text
                            )
                        ),
                        timeout: timeout
                    ).text
                    guard let repairedDraft = VoicePolishOutputNormalizer.plainText(
                        repairedRaw,
                        sourceText: request.fallbackText
                    ) else {
                        throw StructuredLLMDecoderError.invalidJSON
                    }
                    let repaired = normalizedLayoutText(repairedDraft, request: request)
                    let repairedValidation = VoicePolishValidator.validateFast(
                        output: repaired,
                        request: request,
                        sourceFacts: sourceFacts
                    )
                    guard !repairedValidation.hasHardFailure else {
                        return fallback(
                            request: request,
                            detectedRoute: detectedRoute,
                            executedRoute: .fast,
                            attempts: attempts,
                            codes: repairedValidation.codes,
                            rejectedDraft: repaired
                        )
                    }
                    return success(
                        text: repaired,
                        detectedRoute: detectedRoute,
                        executedRoute: .fast,
                        attempts: attempts,
                        codes: repairedValidation.codes
                    )
                } catch {
                    return fallback(
                        request: request,
                        detectedRoute: detectedRoute,
                        executedRoute: .fast,
                        attempts: attempts,
                        codes: validation.codes,
                        reason: failureReason(for: error),
                        rejectedDraft: finalOutput
                    )
                }
            }
            guard !validation.hasHardFailure else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: validation.codes,
                    rejectedDraft: finalOutput
                )
            }
            return success(
                text: finalOutput,
                detectedRoute: detectedRoute,
                executedRoute: .fast,
                attempts: attempts,
                codes: validation.codes
            )
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .fast,
                attempts: attempts,
                codes: [.emptyOutput],
                reason: failureReason(for: error)
            )
        }
    }

    private func runStructured(
        request: VoicePolishRequest,
        payload: String,
        sourceFacts: [SourceFactCandidate],
        detectedRoute: VoicePolishRoute,
        maximumAttempts: Int,
        startedAt: ContinuousClock.Instant
    ) async -> VoicePolishResult {
        var attempts = 0
        let firstRaw: String
        do {
            let timeout = try availableTimeout(
                stageLimit: effectiveFirstRequestTimeout(for: request),
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            firstRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishStructured,
                    system: VoicePolishPrompts.structured,
                    user: payload,
                    options: LLMGenerationOptions(
                        temperature: 0.1,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishStructured
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .jsonObject
                    )
                ),
                timeout: timeout
            ).text
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: [.invalidStructuredResponse],
                reason: failureReason(for: error)
            )
        }

        let decoded: StructuredVoicePolishResponse
        do {
            decoded = try StructuredLLMDecoder.decode(
                StructuredVoicePolishResponse.self,
                from: firstRaw
            )
        } catch {
            let decodeCode = validationCode(for: error)
            guard attempts < maximumAttempts,
                  firstRaw.utf8.count <= VoicePolishOutputNormalizer.maximumResponseBytes else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: [decodeCode]
                )
            }
            do {
                let timeout = try availableTimeout(
                    stageLimit: repairTimeout,
                    startedAt: startedAt,
                    request: request
                )
                attempts += 1
                let repairPayload = try VoicePolishPrompts.repairPayload(
                    originalPayload: payload,
                    rawResponse: firstRaw,
                    validationCodes: [decodeCode]
                )
                let repairedRaw = try await generate(
                    LLMRequest(
                        context: .processingMode,
                        task: .voicePolishRepair,
                        system: VoicePolishPrompts.formatRepair,
                        user: repairPayload,
                        options: LLMGenerationOptions(
                            temperature: 0,
                            maxOutputTokens: Self.outputTokenBudget(
                                for: request,
                                task: .voicePolishRepair
                            ),
                            reasoningPolicy: .disabled,
                            responseFormat: .jsonObject
                        )
                    ),
                    timeout: timeout
                ).text
                let repairedDraft = try StructuredLLMDecoder.decode(
                    StructuredVoicePolishResponse.self,
                    from: repairedRaw
                )
                let repaired = normalizedStructuredResponse(repairedDraft, request: request)
                let validation = VoicePolishValidator.validateStructured(
                    response: repaired,
                    request: request,
                    sourceFacts: sourceFacts
                )
                guard !validation.hasHardFailure else {
                    return fallback(
                        request: request,
                        detectedRoute: detectedRoute,
                        executedRoute: .structured,
                        attempts: attempts,
                        codes: validation.codes
                    )
                }
                return success(
                    text: repaired.finalText,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: validation.codes
                )
            } catch {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: [validationCode(for: error)],
                    reason: failureReason(for: error)
                )
            }
        }

        let normalizedDecoded = normalizedStructuredResponse(decoded, request: request)
        let validation = VoicePolishValidator.validateStructured(
            response: normalizedDecoded,
            request: request,
            sourceFacts: sourceFacts
        )
        guard validation.hasHardFailure else {
            return success(
                text: normalizedDecoded.finalText,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: validation.codes
            )
        }
        guard attempts < maximumAttempts else {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: validation.codes
            )
        }

        // 内容 Repair 与格式 Repair 共享最后一次预算；当前分支只在首次 JSON
        // 已有效时进入，因此不会出现“格式修复后再内容修复”的第三次调用。
        do {
            let timeout = try availableTimeout(
                stageLimit: repairTimeout,
                startedAt: startedAt,
                request: request
            )
            attempts += 1
            let repairPayload = try VoicePolishPrompts.repairPayload(
                originalPayload: payload,
                rawResponse: firstRaw,
                validationCodes: validation.codes.filter(\.isHardFailure)
            )
            let repairedRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishRepair,
                    system: VoicePolishPrompts.contentRepair,
                    user: repairPayload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: Self.outputTokenBudget(
                            for: request,
                            task: .voicePolishRepair
                        ),
                        reasoningPolicy: .disabled,
                        responseFormat: .jsonObject
                    )
                ),
                timeout: timeout
            ).text
            let repairedDraft = try StructuredLLMDecoder.decode(
                StructuredVoicePolishResponse.self,
                from: repairedRaw
            )
            let repaired = normalizedStructuredResponse(repairedDraft, request: request)
            let repairedValidation = VoicePolishValidator.validateStructured(
                response: repaired,
                request: request,
                sourceFacts: sourceFacts
            )
            guard !repairedValidation.hasHardFailure else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .structured,
                    attempts: attempts,
                    codes: repairedValidation.codes
                )
            }
            return success(
                text: repaired.finalText,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: repairedValidation.codes
            )
        } catch {
            return fallback(
                request: request,
                detectedRoute: detectedRoute,
                executedRoute: .structured,
                attempts: attempts,
                codes: [validationCode(for: error)],
                reason: failureReason(for: error)
            )
        }
    }

    private func generate(
        _ request: LLMRequest,
        timeout: Duration
    ) async throws -> LLMResponse {
        try Task.checkCancellation()
        onStage?(stage(for: request.task))
        let startedAt = ContinuousClock.now
        do {
            let response = try await AsyncTimeout.throwingValue(
                timeout,
                timeoutError: VoicePolishStageTimeoutError()
            ) {
                try await client.generate(request, config: config)
            }
            DebugFileLogger.log(
                "voice polish stage task=\(request.task.rawValue) elapsed_ms=\(milliseconds(ContinuousClock.now - startedAt)) outcome=success"
            )
            return response
        } catch {
            DebugFileLogger.log(
                "voice polish stage task=\(request.task.rawValue) elapsed_ms=\(milliseconds(ContinuousClock.now - startedAt)) outcome=failure"
            )
            throw error
        }
    }

    /// 在事实校验前执行可逆、确定性的纯版式整理。只有成稿自身已经存在明确的
    /// 句界、分号边界或连续列表边界时才补换行；代码场景不按分号拆分，避免破坏
    /// 语法。用户明确要求中文编号时保留中文样式。
    private func normalizedLayoutText(
        _ text: String,
        request: VoicePolishRequest
    ) -> String {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        if request.context.scene == .code {
            return text
        }
        let punctuationRepaired = VoicePolishPunctuationRepair.normalize(text)
        let formatted = VoicePolishFallbackFormatter.formatCandidate(
            punctuationRepaired,
            expectation: expectation
        )
        let candidate: String
        if expectation.numberingPreference == .chinese {
            candidate = formatted
        } else {
            candidate = VoicePolishNumbering.normalizeExistingList(
                in: formatted,
                as: expectation.kind
            )
        }
        // 编号归一也属于本地改写，必须与 Formatter 一起包在最终安全门内。
        // 无法证明只改变空白和完整列表标记时，保留模型原成稿并交给 Validator。
        guard VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: punctuationRepaired,
            candidate: candidate,
            expectation: expectation
        ) else {
            return punctuationRepaired
        }
        // 总数同步是独立于通用纯版式门禁的窄规则：仅当本地能证明
        // “原 N 项 + 明确新增 1 项 = 连续 N+1 项”时，定点修正唯一声明数字。
        return VoicePolishListCountConsistency
            .synchronizeDeclaredCountForProvenTrailingAddition(
                in: candidate,
                canonicalSource: request.fallbackText
            )
    }

    private func normalizedStructuredResponse(
        _ response: StructuredVoicePolishResponse,
        request: VoicePolishRequest
    ) -> StructuredVoicePolishResponse {
        StructuredVoicePolishResponse(
            plan: normalizedPlanLayout(response.plan, request: request),
            finalText: normalizedLayoutText(response.finalText, request: request)
        )
    }

    /// output_format 是本地版式契约的镜像，不属于模型需要自主判断的事实。
    /// 统一覆盖它可以避免 Analyzer/Structured 仅因自报格式错误浪费一次请求；
    /// 最终正文仍由独立 Validator 按真实换行与列表项逐项验收。
    private func normalizedPlanLayout(
        _ plan: VoicePolishPlan,
        request: VoicePolishRequest
    ) -> VoicePolishPlan {
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        let expectedListCount: Int?
        switch expectation.kind {
        case .numberedList, .bulletList:
            if let exact = expectation.expectedListItemCount {
                expectedListCount = exact
            } else {
                // minimum-only 契约不能把模型猜测的数量升级成硬约束，否则
                // Structured/Deep 会比 Fast 多出无依据的精确项数要求。
                expectedListCount = nil
            }
        case .sentence, .paragraphs:
            expectedListCount = nil
        }

        return VoicePolishPlan(
            version: plan.version,
            language: plan.language,
            scene: plan.scene,
            finalIntent: plan.finalIntent,
            orderedBlocks: plan.orderedBlocks,
            discardedFragments: plan.discardedFragments,
            corrections: plan.corrections,
            sideNotes: plan.sideNotes,
            facts: plan.facts,
            uncertainEntities: plan.uncertainEntities,
            outputFormat: VoiceOutputFormat(
                kind: expectation.kind,
                expectedListCount: expectedListCount
            ),
            confidence: plan.confidence
        )
    }

    private func stage(for task: LLMTask) -> VoicePolishStage {
        switch task {
        case .voicePolishAnalyze:
            return .analyzing
        case .voicePolishRender:
            return .rendering
        case .voicePolishRepair:
            return .repairing
        case .voicePolishFast, .voicePolishStructured:
            return .polishing
        default:
            return .polishing
        }
    }

    private func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000
            + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func effectiveFirstRequestTimeout(for request: VoicePolishRequest) -> Duration {
        usesAdaptiveFirstRequestTimeout
            ? Self.defaultFirstRequestTimeout(for: request)
            : firstRequestTimeout
    }

    private func effectiveTotalTimeout(for request: VoicePolishRequest) -> Duration {
        usesAdaptiveTotalTimeout
            ? Self.defaultTotalTimeout(for: request)
            : totalTimeout
    }

    private func availableTimeout(
        stageLimit: Duration,
        startedAt: ContinuousClock.Instant,
        request: VoicePolishRequest
    ) throws -> Duration {
        let elapsed = ContinuousClock.now - startedAt
        let remaining = effectiveTotalTimeout(for: request) - elapsed
        guard remaining >= .seconds(2) else {
            throw VoicePolishStageTimeoutError()
        }
        return min(stageLimit, remaining)
    }

    private func validationCode(for error: Error) -> VoicePolishValidationCode {
        if let decoderError = error as? StructuredLLMDecoderError {
            switch decoderError {
            case .ambiguousJSONObjects:
                return .ambiguousStructuredResponse
            case .responseTooLarge:
                return .abnormalLength
            case .noJSONObject, .invalidJSON:
                return .invalidStructuredResponse
            }
        }
        return .invalidStructuredResponse
    }

    private func failureReason(for error: Error) -> VoicePolishFailureReason {
        if error is VoicePolishStageTimeoutError || error is CancellationError {
            return .timeout
        }
        if error is StructuredLLMDecoderError {
            return .validationFailed
        }
        return .requestFailed
    }

    private func success(
        text: String,
        detectedRoute: VoicePolishRoute,
        executedRoute: VoicePolishRoute,
        attempts: Int,
        codes: [VoicePolishValidationCode]
    ) -> VoicePolishResult {
        DebugFileLogger.log(
            "voice polish done route=\(detectedRoute.rawValue) executed=\(executedRoute.rawValue) attempts=\(attempts) output=\(text.count)chars codes=\(codes.map(\.rawValue).joined(separator: ",")) fallback=false"
        )
        return VoicePolishResult(
            text: text,
            detectedRoute: detectedRoute,
            executedRoute: executedRoute,
            llmAttemptCount: attempts,
            validationCodes: codes,
            usedFallback: false,
            failureReason: nil
        )
    }

    private func fallback(
        request: VoicePolishRequest,
        detectedRoute: VoicePolishRoute,
        executedRoute: VoicePolishRoute,
        attempts: Int,
        codes: [VoicePolishValidationCode],
        reason: VoicePolishFailureReason = .validationFailed,
        rejectedDraft: String? = nil
    ) -> VoicePolishResult {
        // 回退仍以 canonical transcript 为唯一内容来源；先只移除可证明错误的
        // ASR 标点/空白，再在字符与顺序不变的前提下补段落或列表结构，避免
        // 校验失败后重新退回错误断句或一坨文字。
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        let fallbackText: String
        if request.context.scene == .code {
            fallbackText = request.fallbackText
        } else {
            let punctuationRepaired = VoicePolishPunctuationRepair.normalize(
                request.fallbackText
            )
            let fallbackCandidate = VoicePolishFallbackFormatter.formatCandidate(
                punctuationRepaired,
                expectation: expectation
            )
            if VoicePolishFallbackFormatter.isStrictlySafeTransformation(
                source: punctuationRepaired,
                candidate: fallbackCandidate,
                expectation: expectation
            ) {
                fallbackText = VoicePolishListCountConsistency
                    .synchronizeDeclaredCountForProvenTrailingAddition(
                        in: fallbackCandidate,
                        canonicalSource: request.fallbackText
                    )
            } else {
                fallbackText = punctuationRepaired
            }
        }
        DebugFileLogger.log(
            "voice polish done route=\(detectedRoute.rawValue) executed=\(executedRoute.rawValue) attempts=\(attempts) output=\(fallbackText.count)chars codes=\(codes.map(\.rawValue).joined(separator: ",")) fallback=true"
        )
        return VoicePolishResult(
            text: fallbackText,
            detectedRoute: detectedRoute,
            executedRoute: executedRoute,
            llmAttemptCount: attempts,
            validationCodes: codes,
            usedFallback: true,
            failureReason: reason,
            rejectedDraft: rejectedDraft
        )
    }
}
