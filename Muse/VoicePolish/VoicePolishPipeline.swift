import Foundation

private struct VoicePolishStageTimeoutError: Error {}

struct VoicePolishPipeline: Sendable {
    private let client: any LLMClient
    private let config: LLMConfig
    private let totalTimeout: Duration
    private let firstRequestTimeout: Duration
    private let analyzeTimeout: Duration
    private let renderTimeout: Duration
    private let repairTimeout: Duration
    private let onStage: (@Sendable (VoicePolishStage) -> Void)?

    init(
        client: any LLMClient,
        config: LLMConfig,
        totalTimeout: Duration = .seconds(45),
        firstRequestTimeout: Duration = .seconds(30),
        analyzeTimeout: Duration = .seconds(15),
        renderTimeout: Duration = .seconds(20),
        repairTimeout: Duration = .seconds(10),
        onStage: (@Sendable (VoicePolishStage) -> Void)? = nil
    ) {
        self.client = client
        self.config = config
        self.totalTimeout = totalTimeout
        self.firstRequestTimeout = firstRequestTimeout
        self.analyzeTimeout = analyzeTimeout
        self.renderTimeout = renderTimeout
        self.repairTimeout = repairTimeout
        self.onStage = onStage
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
            let timeout = try availableTimeout(stageLimit: analyzeTimeout, startedAt: startedAt)
            attempts += 1
            analyzerRaw = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishAnalyze,
                    system: VoicePolishPrompts.analyzer,
                    user: payload,
                    options: LLMGenerationOptions(
                        temperature: 0,
                        maxOutputTokens: 4_096,
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
                let timeout = try availableTimeout(stageLimit: repairTimeout, startedAt: startedAt)
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
                            maxOutputTokens: 4_096,
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
            let timeout = try availableTimeout(stageLimit: renderTimeout, startedAt: startedAt)
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
                        maxOutputTokens: 3_072,
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
            let timeout = try availableTimeout(stageLimit: repairTimeout, startedAt: startedAt)
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
                        maxOutputTokens: 3_072,
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
                stageLimit: firstRequestTimeout,
                startedAt: startedAt
            )
            attempts = 1
            let response = try await generate(
                LLMRequest(
                    context: .processingMode,
                    task: .voicePolishFast,
                    system: VoicePolishPrompts.fast,
                    user: payload,
                    options: LLMGenerationOptions(
                        temperature: 0.2,
                        maxOutputTokens: 2_048,
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
            let validation = VoicePolishValidator.validateFast(
                output: output,
                request: request,
                sourceFacts: sourceFacts
            )
            guard !validation.hasHardFailure else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: validation.codes
                )
            }
            return success(
                text: output,
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
                stageLimit: firstRequestTimeout,
                startedAt: startedAt
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
                        maxOutputTokens: 4_096,
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
                    startedAt: startedAt
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
                            maxOutputTokens: 4_096,
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
                startedAt: startedAt
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
                        maxOutputTokens: 4_096,
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
        let formatted = VoicePolishFallbackFormatter.formatCandidate(
            text,
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
            source: text,
            candidate: candidate,
            expectation: expectation
        ) else {
            return text
        }
        return candidate
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

    private func availableTimeout(
        stageLimit: Duration,
        startedAt: ContinuousClock.Instant
    ) throws -> Duration {
        let elapsed = ContinuousClock.now - startedAt
        let remaining = totalTimeout - elapsed
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
        reason: VoicePolishFailureReason = .validationFailed
    ) -> VoicePolishResult {
        // 回退仍以 canonical transcript 为唯一内容来源；只在本地能证明字符与
        // 顺序完全不变时补上段落/列表结构，避免校验失败后重新退回成一坨文字。
        let expectation = VoicePolishLayoutExpectation.infer(from: request)
        let fallbackCandidate = VoicePolishFallbackFormatter.format(
            request: request,
            expectation: expectation
        )
        let fallbackText: String
        if request.context.scene == .code {
            fallbackText = request.fallbackText
        } else if VoicePolishFallbackFormatter.isStrictlySafeTransformation(
            source: request.fallbackText,
            candidate: fallbackCandidate,
            expectation: expectation
        ) {
            fallbackText = fallbackCandidate
        } else {
            fallbackText = request.fallbackText
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
            failureReason: reason
        )
    }
}
