import Foundation

private struct VoicePolishStageTimeoutError: Error {}

struct VoicePolishPipeline: Sendable {
    private let client: any LLMClient
    private let config: LLMConfig
    private let totalTimeout: Duration
    private let firstRequestTimeout: Duration
    private let repairTimeout: Duration

    init(
        client: any LLMClient,
        config: LLMConfig,
        totalTimeout: Duration = .seconds(45),
        firstRequestTimeout: Duration = .seconds(30),
        repairTimeout: Duration = .seconds(10)
    ) {
        self.client = client
        self.config = config
        self.totalTimeout = totalTimeout
        self.firstRequestTimeout = firstRequestTimeout
        self.repairTimeout = repairTimeout
    }

    func process(
        _ request: VoicePolishRequest,
        startedAt suppliedStart: ContinuousClock.Instant? = nil
    ) async -> VoicePolishResult {
        let startedAt = suppliedStart ?? ContinuousClock.now
        let sourceFacts = ProtectedFactExtractor.extract(from: request.input.segments)
        let decision = VoicePolishComplexityRouter.decide(
            request: request,
            factCandidates: sourceFacts
        )
        let executedRoute: VoicePolishRoute = decision.route == .fast ? .fast : .structured
        let maximumAttempts = request.qualityMode == .fast
            ? 1
            : (executedRoute == .fast ? 1 : 2)

        DebugFileLogger.log(
            "voice polish start route=\(decision.route.rawValue) executed=\(executedRoute.rawValue) quality=\(request.qualityMode.rawValue) input=\(request.input.fallbackText.count)chars facts=\(sourceFacts.count)"
        )

        do {
            let payload = try VoicePolishPrompts.payload(
                for: request,
                sourceFacts: sourceFacts,
                deepDeferred: decision.route == .deep
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
                        reasoningPolicy: .disabled,
                        responseFormat: .text
                    )
                ),
                timeout: timeout
            )
            guard let output = VoicePolishOutputNormalizer.plainText(
                response.text,
                sourceText: request.input.fallbackText
            ) else {
                return fallback(
                    request: request,
                    detectedRoute: detectedRoute,
                    executedRoute: .fast,
                    attempts: attempts,
                    codes: [.abnormalLength]
                )
            }
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
                            reasoningPolicy: .disabled,
                            responseFormat: .jsonObject
                        )
                    ),
                    timeout: timeout
                ).text
                let repaired = try StructuredLLMDecoder.decode(
                    StructuredVoicePolishResponse.self,
                    from: repairedRaw
                )
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

        let validation = VoicePolishValidator.validateStructured(
            response: decoded,
            request: request,
            sourceFacts: sourceFacts
        )
        guard validation.hasHardFailure else {
            return success(
                text: decoded.finalText,
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
                        reasoningPolicy: .disabled,
                        responseFormat: .jsonObject
                    )
                ),
                timeout: timeout
            ).text
            let repaired = try StructuredLLMDecoder.decode(
                StructuredVoicePolishResponse.self,
                from: repairedRaw
            )
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
        try await AsyncTimeout.throwingValue(
            timeout,
            timeoutError: VoicePolishStageTimeoutError()
        ) {
            try await client.generate(request, config: config)
        }
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
        let fallbackText = request.input.fallbackText
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
